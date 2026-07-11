package com.jieoz.lanmediawall.player.media

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.SurfaceView
import android.widget.ImageView
import com.google.android.exoplayer2.MediaItem as ExoMediaItem
import com.google.android.exoplayer2.PlaybackException
import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.ExoPlayer
import com.google.android.exoplayer2.Format
import com.google.android.exoplayer2.DefaultRenderersFactory
import com.google.android.exoplayer2.analytics.AnalyticsListener
import com.google.android.exoplayer2.mediacodec.MediaCodecSelector
import com.google.android.exoplayer2.video.VideoSize
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Media3 (ExoPlayer) wrapper — the Android analogue of windows_player's mpv
 * controller. Owns one ExoPlayer instance and exposes the operations the
 * protocol drives: load/play(at)/pause/seek/volume/mute + a current-frame
 * snapshot for thumbnails (§6.4).
 *
 * Threading: ExoPlayer must be touched only from the thread that created it
 * (the app main thread). Every public mutator posts onto [mainHandler], so the
 * service/WS threads can call freely. Read-only snapshots also marshal to main
 * and block briefly for the value.
 */
class PlayerController(context: Context) {

    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var player: ExoPlayer? = null
    @Volatile private var surfaceView: SurfaceView? = null
    @Volatile private var imageView: ImageView? = null
    @Volatile private var lastError: String? = null
    /** §hardware-decode: last video decoder ExoPlayer initialized, for diagnostics
     *  export. Null until the first onVideoDecoderInitialized. */
    @Volatile var lastVideoDecoderName: String? = null
        private set
    private val thumbSeq = AtomicInteger(0)
    private val thumbnailFlight = ThumbnailSingleFlight()
    @Volatile private var lastFirstFrameAtMs = 0L
    /** §6.4 root-performance: one cached thumbnail per item, so active video
     *  playback never re-extracts a live frame (see [ThumbnailPolicy.decide]).
     *  Keyed by itemId; holds the (seq, jpeg) captured once while not playing. */
    private val thumbnailCache = java.util.concurrent.ConcurrentHashMap<String, Pair<Int, ByteArray>>()

    /** Called when ExoPlayer reports an unrecoverable error (watchdog hook). */
    @Volatile var onPlayerError: ((String) -> Unit)? = null

    /** Called once when a non-looping video reaches its end (STATE_ENDED), so
     *  the service can auto-advance the playlist (§6.3 carousel). */
    @Volatile var onVideoEnded: (() -> Unit)? = null

    /**
     * Diagnostic sink → PlayerService.logEvent, so decode-path events land in the
     * **exported** player.log rather than logcat (which is heavily truncated on
     * the 4.4/HiSilicon boxes — the blind spot that made the last black-screen
     * regression impossible to diagnose from the pulled log). Every message is
     * prefixed `exo ` by the service side; keep payloads terse and machine-greppable.
     */
    @Volatile var logSink: ((String) -> Unit)? = null
    private fun log(msg: String) { logSink?.invoke(msg) }

    private fun stateName(state: Int): String = when (state) {
        Player.STATE_IDLE -> "IDLE"
        Player.STATE_BUFFERING -> "BUFFERING"
        Player.STATE_READY -> "READY"
        Player.STATE_ENDED -> "ENDED"
        else -> "state$state"
    }

    /**
     * §hardware-decode: a MediaCodecSelector that drops software VIDEO decoders
     * (OMX.google.* / c2.android.* / API-reported softwareOnly) via
     * [VideoCodecPolicy], so ExoPlayer can only pick a HiSilicon hardware decoder
     * on the target. Audio is untouched. If filtering leaves NO video decoder we
     * return the empty list and log it: ExoPlayer then raises a decoder-init error
     * that surfaces as a real diagnostic, rather than silently decoding in
     * software (the black-screen / overload trap on these boxes).
     */
    private val hardwareOnlyVideoSelector = MediaCodecSelector { mimeType, requiresSecureDecoder, requiresTunnelingDecoder ->
        val all = MediaCodecSelector.DEFAULT.getDecoderInfos(
            mimeType, requiresSecureDecoder, requiresTunnelingDecoder,
        )
        if (!mimeType.startsWith("video/")) return@MediaCodecSelector all
        val kept = all.filter { info ->
            val flag = try { info.softwareOnly } catch (_: Throwable) { false }
            VideoCodecPolicy.isHardware(info.name, flag)
        }
        val dropped = all.size - kept.size
        log("codec_select mime=$mimeType total=${all.size} hardware=${kept.size} dropped_software=$dropped " +
            "picked=${kept.firstOrNull()?.name ?: "NONE"}")
        if (kept.isEmpty() && all.isNotEmpty()) {
            log("codec_select_fail mime=$mimeType reason=no_hardware_decoder available=${all.joinToString(",") { it.name }}")
        }
        kept
    }

    fun init() {
        runOnMain {
            if (player != null) return@runOnMain
            val renderersFactory = DefaultRenderersFactory(appContext)
                .setMediaCodecSelector(hardwareOnlyVideoSelector)
            val p = ExoPlayer.Builder(appContext, renderersFactory).build()
            p.repeatMode = Player.REPEAT_MODE_OFF
            p.playWhenReady = false
            p.addListener(object : Player.Listener {
                override fun onPlayerError(error: PlaybackException) {
                    lastError = error.errorCodeName
                    // errorCodeName is the greppable enum; cause pins the decoder
                    // failure (e.g. OMX_ErrorStreamCorrupt vs format-unsupported).
                    val cause = error.cause?.let { "${it.javaClass.simpleName}:${it.message}" } ?: "none"
                    log("error code=${error.errorCodeName} codeInt=${error.errorCode} cause=$cause")
                    onPlayerError?.invoke(error.errorCodeName)
                }

                override fun onPlaybackStateChanged(state: Int) {
                    log("state ${stateName(state)}")
                    // §6.3: a finished non-looping video hands control back so the
                    // service advances. REPEAT_MODE_ONE loops never reach ENDED.
                    if (state == Player.STATE_ENDED) onVideoEnded?.invoke()
                }

                override fun onRenderedFirstFrame() {
                    // The single most decisive signal: pixels actually reached the
                    // surface. Its ABSENCE (state=READY but no first-frame) is the
                    // fingerprint of a decoded-but-black stream.
                    val now = SystemClock.elapsedRealtime()
                    val previous = lastFirstFrameAtMs
                    lastFirstFrameAtMs = now
                    log("first_frame rendered position_ms=${p.currentPosition} " +
                        "delta_ms=${if (previous == 0L) -1 else now - previous}")
                }

                override fun onMediaItemTransition(mediaItem: ExoMediaItem?, reason: Int) {
                    log("media_transition reason=$reason position_ms=${p.currentPosition}")
                }

                override fun onPositionDiscontinuity(
                    oldPosition: Player.PositionInfo,
                    newPosition: Player.PositionInfo,
                    reason: Int,
                ) {
                    log("position_discontinuity reason=$reason old_ms=${oldPosition.positionMs} " +
                        "new_ms=${newPosition.positionMs}")
                }

                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    log("video_size ${videoSize.width}x${videoSize.height} " +
                        "par=${videoSize.pixelWidthHeightRatio}")
                }

                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    log("is_playing $isPlaying")
                }
            })
            p.addAnalyticsListener(object : AnalyticsListener {
                override fun onDroppedVideoFrames(
                    eventTime: AnalyticsListener.EventTime,
                    droppedFrames: Int,
                    elapsedMs: Long,
                ) {
                    log("dropped_frames count=$droppedFrames elapsed_ms=$elapsedMs position_ms=${p.currentPosition}")
                }

                // §hardware-decode diagnostics: the decisive evidence the exported
                // player.log was missing — which decoder was actually chosen, its
                // hardware/software classification, and how long init took. If a
                // software decoder ever appears here it is a policy breach.
                override fun onVideoDecoderInitialized(
                    eventTime: AnalyticsListener.EventTime,
                    decoderName: String,
                    initializedTimestampMs: Long,
                    initializationDurationMs: Long,
                ) {
                    lastVideoDecoderName = decoderName
                    val cls = VideoCodecPolicy.classify(decoderName, null)
                    log("video_decoder_init name=$decoderName class=$cls init_ms=$initializationDurationMs")
                }

                override fun onVideoInputFormatChanged(
                    eventTime: AnalyticsListener.EventTime,
                    format: Format,
                    decoderReuseEvaluation: com.google.android.exoplayer2.decoder.DecoderReuseEvaluation?,
                ) {
                    log("video_input_format mime=${format.sampleMimeType} codecs=${format.codecs ?: "?"} " +
                        "size=${format.width}x${format.height} fps=${format.frameRate} " +
                        "bitrate=${format.bitrate}")
                }
            })
            player = p
            surfaceView?.let { p.setVideoSurfaceView(it) }
            log("init done surface=SurfaceView")
        }
    }

    fun attachSurface(view: SurfaceView) {
        runOnMain {
            surfaceView = view
            player?.setVideoSurfaceView(view)
        }
    }

    /** Attach the ImageView used to draw `type=="image"` playlist items (§6.1). */
    fun attachImageView(view: ImageView) {
        runOnMain { imageView = view }
    }

    fun detachSurface() {
        runOnMain {
            player?.clearVideoSurfaceView(surfaceView)
            surfaceView = null
            imageView = null
        }
    }

    /** Load a file/URL, seek, and stay paused — primes for a synced start. */
    fun loadPaused(uri: String, seekMs: Long = 0, loop: Boolean = false) {
        runOnMain {
            val p = player ?: return@runOnMain
            log("loadPaused uri=${describeUri(uri)} seekMs=$seekMs loop=$loop")
            hideImage()
            lastError = null
            p.repeatMode = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
            p.setMediaItem(ExoMediaItem.fromUri(uri))
            p.playWhenReady = false
            p.prepare()
            if (seekMs > 0) p.seekTo(seekMs)
        }
    }

    /** Load and start playing immediately (used for non-synced / advance). */
    fun loadAndPlay(uri: String, seekMs: Long = 0, loop: Boolean = false) {
        runOnMain {
            val p = player ?: return@runOnMain
            log("loadAndPlay uri=${describeUri(uri)} seekMs=$seekMs loop=$loop")
            hideImage()
            lastError = null
            p.repeatMode = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
            p.setMediaItem(ExoMediaItem.fromUri(uri))
            p.prepare()
            if (seekMs > 0) p.seekTo(seekMs)
            p.playWhenReady = true
        }
    }

    /**
     * Terse, greppable description of the source being primed: whether it is a
     * local cached file (and its on-disk size) or a remote URL. A remote URL
     * here is itself a red flag — §11 black-screen root cause was falling back
     * to a dead `item.url` when the cache path was wrongly discarded.
     */
    private fun describeUri(uri: String): String {
        return try {
            if (uri.startsWith("http://") || uri.startsWith("https://")) {
                "REMOTE_URL($uri)"
            } else {
                val f = File(uri.removePrefix("file://"))
                "local(${f.name},exists=${f.exists()},size=${if (f.exists()) f.length() else -1})"
            }
        } catch (e: Exception) {
            "uri($uri)"
        }
    }

    fun play() = runOnMain { player?.playWhenReady = true }
    fun pause() = runOnMain { player?.playWhenReady = false }

    /**
     * §6.1 image item: decode a local file (or file:// path) and show it on the
     * ImageView above the video surface, pausing + hiding the video so a still
     * actually appears (ExoPlayer can't render one). No-op if the ImageView
     * isn't attached yet (no kiosk Activity foregrounded).
     */
    fun showImage(path: String) = runOnMain {
        val iv = imageView ?: return@runOnMain
        val file = File(path.removePrefix("file://"))
        val bmp = try {
            BitmapFactory.decodeFile(file.absolutePath)
        } catch (e: Exception) {
            lastError = "image-decode:${e.javaClass.simpleName}"
            null
        }
        if (bmp == null) {
            onPlayerError?.invoke("image-decode-failed")
            return@runOnMain
        }
        player?.playWhenReady = false
        iv.setImageBitmap(bmp)
        iv.visibility = ImageView.VISIBLE
    }

    /** Hide the image layer (called when switching back to video). */
    fun hideImage() = runOnMain {
        imageView?.let {
            it.visibility = ImageView.GONE
            it.setImageDrawable(null)
        }
    }

    fun stop() = runOnMain {
        val p = player ?: return@runOnMain
        p.stop()
        p.clearMediaItems()
        hideImage()
    }

    fun seekTo(ms: Long) = runOnMain { player?.seekTo(ms) }

    /** ExoPlayer volume is 0.0–1.0; protocol volume is 0–100. */
    fun setVolume(volume0to100: Int) = runOnMain {
        player?.volume = (volume0to100.coerceIn(0, 100)) / 100f
    }

    fun setMuted(muted: Boolean) = runOnMain {
        player?.volume = if (muted) 0f else (currentVolumePercent / 100f)
    }

    @Volatile var currentVolumePercent: Int = 80

    /** Snapshot of position/duration/paused/volume — for §5 status. */
    data class Snapshot(
        val positionMs: Long,
        val durationMs: Long,
        val isPlaying: Boolean,
        val playbackState: Int,
        val hasMedia: Boolean,
        val error: String?,
    )

    fun snapshot(): Snapshot = blockingOnMain {
        val p = player
        if (p == null) {
            Snapshot(0, 0, false, Player.STATE_IDLE, false, lastError)
        } else {
            val dur = p.duration
            Snapshot(
                positionMs = p.currentPosition.coerceAtLeast(0),
                durationMs = if (dur > 0) dur else 0,
                isPlaying = p.isPlaying,
                playbackState = p.playbackState,
                hasMedia = p.currentMediaItem != null,
                error = lastError,
            )
        }
    }

    /** §6.4: the thumbnail already captured for [itemId], or null if none yet.
     *  Reused during active playback so we never open a second decoder. */
    fun cachedThumbnail(itemId: String): Pair<Int, ByteArray>? = thumbnailCache[itemId]

    /** Drop cached thumbnails for items no longer referenced (playlist change). */
    fun retainThumbnails(keepItemIds: Set<String>) {
        thumbnailCache.keys.retainAll(keepItemIds)
    }

    /**
     * Extract ONE frame from the local cached video and memoize it under [itemId].
     * This is the only path that opens a MediaMetadataRetriever, and the caller
     * ([PlayerService.thumbnailLoop] via [ThumbnailPolicy.decide]) must only invoke
     * it while the video is NOT actively playing — so it never races ExoPlayer's
     * live HiSilicon decoder. All work stays on Dispatchers.IO; the single-flight
     * guard prevents overlap; the result is cached so playback reuses it.
     */
    suspend fun captureThumbnail(
        itemId: String,
        sourcePath: String,
        positionMs: Long,
        maxWidth: Int = 320,
        quality: Int = 70,
    ): Pair<Int, ByteArray>? = withContext(Dispatchers.IO) {
        thumbnailCache[itemId]?.let { return@withContext it }
        val lease = thumbnailFlight.tryAcquire() ?: run {
            log("thumb_skip reason=busy")
            return@withContext null
        }
        try {
            val file = File(sourcePath.removePrefix("file://"))
            if (!file.isFile) return@withContext null
            val extractStarted = SystemClock.elapsedRealtime()
            val retriever = MediaMetadataRetriever()
            val frame = try {
                retriever.setDataSource(file.absolutePath)
                retriever.getFrameAtTime(
                    positionMs.coerceAtLeast(0L) * 1000L,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                )
            } catch (e: Exception) {
                log("thumb_error stage=extract type=${e.javaClass.simpleName}")
                null
            } finally {
                try { retriever.release() } catch (_: Exception) { }
            } ?: return@withContext null
            val extractMs = SystemClock.elapsedRealtime() - extractStarted
            val target = ThumbnailPolicy.captureSize(frame.width, frame.height, maxWidth)
            if (target == null) {
                frame.recycle()
                return@withContext null
            }
            val bmp = if (frame.width == target.width && frame.height == target.height) {
                frame
            } else {
                Bitmap.createScaledBitmap(frame, target.width, target.height, true).also { frame.recycle() }
            }
            val encodeStarted = SystemClock.elapsedRealtime()
            val out = ByteArrayOutputStream(32 * 1024)
            if (!bmp.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), out)) {
                bmp.recycle()
                return@withContext null
            }
            val jpeg = out.toByteArray()
            val encodeMs = SystemClock.elapsedRealtime() - encodeStarted
            val runtime = Runtime.getRuntime()
            log("thumb_capture item=$itemId source=file extract_ms=$extractMs encode_ms=$encodeMs " +
                "bitmap=${bmp.width}x${bmp.height} jpeg_bytes=${jpeg.size} " +
                "heap_used=${runtime.totalMemory() - runtime.freeMemory()} heap_max=${runtime.maxMemory()}")
            bmp.recycle()
            val captured = thumbSeq.incrementAndGet() to jpeg
            thumbnailCache[itemId] = captured
            captured
        } finally {
            lease.close()
        }
    }


    fun release() = runOnMain {
        player?.release()
        player = null
        surfaceView = null
        imageView = null
    }

    // --- threading helpers -------------------------------------------
    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block()
        else mainHandler.post(block)
    }

    private fun <T> blockingOnMain(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = java.util.concurrent.CountDownLatch(1)
        @Suppress("UNCHECKED_CAST")
        var result: Any? = null
        mainHandler.post {
            try { result = block() } finally { latch.countDown() }
        }
        latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
        @Suppress("UNCHECKED_CAST")
        return result as T
    }
}
