package com.jieoz.lanmediawall.player.media

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.SurfaceView
import com.google.android.exoplayer2.MediaItem as ExoMediaItem
import com.google.android.exoplayer2.PlaybackException
import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.ExoPlayer
import com.google.android.exoplayer2.Format
import com.google.android.exoplayer2.DefaultRenderersFactory
import com.google.android.exoplayer2.analytics.AnalyticsListener
import com.google.android.exoplayer2.mediacodec.MediaCodecSelector
import com.google.android.exoplayer2.video.VideoSize

/**
 * §backend-ab: the Media3/ExoPlayer video kernel (the v1.14.0 hardware-only path),
 * now behind [VideoBackend]. Behaviour is byte-for-byte the same as the previous
 * inline ExoPlayer code in PlayerController — only the diagnostics were extended
 * to also feed the shared [BackendMetrics] so an A/B run can compare it against
 * the native MediaPlayer kernel on the same box.
 *
 * Threading: ExoPlayer must be touched only from its creating thread (main). The
 * facade marshals; every mutator here posts onto [mainHandler] defensively.
 */
class ExoVideoBackend(context: Context) : VideoBackend {

    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())

    override val backend = PlayerBackend.EXOPLAYER
    override val metrics = BackendMetrics()

    @Volatile private var player: ExoPlayer? = null
    @Volatile private var surfaceView: SurfaceView? = null
    @Volatile private var lastError: String? = null

    @Volatile override var lastVideoDecoderName: String? = null
        private set

    override var logSink: ((String) -> Unit)? = null
    override var onError: ((String) -> Unit)? = null
    override var onEnded: (() -> Unit)? = null

    private fun log(msg: String) { logSink?.invoke(msg) }

    /** load timestamp for prepare/first-frame latency (elapsedRealtime). */
    @Volatile private var loadStartedMs = 0L
    @Volatile private var firstFrameSeen = false

    private fun stateName(state: Int): String = when (state) {
        Player.STATE_IDLE -> "IDLE"
        Player.STATE_BUFFERING -> "BUFFERING"
        Player.STATE_READY -> "READY"
        Player.STATE_ENDED -> "ENDED"
        else -> "state$state"
    }

    /**
     * §hardware-decode: MediaCodecSelector dropping software VIDEO decoders
     * (OMX.google.* / c2.android.* / API-reported softwareOnly) via [VideoCodecPolicy].
     * Unchanged from v1.14.0. Audio untouched. Empty result → explicit decoder-init
     * failure (a real diagnostic) rather than silent software decode.
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

    override fun init() {
        runOnMain {
            if (player != null) return@runOnMain
            metrics.enableDroppedFrames() // ExoPlayer CAN report dropped frames
            val renderersFactory = DefaultRenderersFactory(appContext)
                .setMediaCodecSelector(hardwareOnlyVideoSelector)
            val p = ExoPlayer.Builder(appContext, renderersFactory).build()
            p.repeatMode = Player.REPEAT_MODE_OFF
            p.playWhenReady = false
            p.addListener(object : Player.Listener {
                override fun onPlayerError(error: PlaybackException) {
                    lastError = error.errorCodeName
                    val cause = error.cause?.let { "${it.javaClass.simpleName}:${it.message}" } ?: "none"
                    log("error code=${error.errorCodeName} codeInt=${error.errorCode} cause=$cause")
                    metrics.onError(error.errorCodeName)
                    onError?.invoke(error.errorCodeName)
                }

                override fun onPlaybackStateChanged(state: Int) {
                    log("state ${stateName(state)}")
                    if (state == Player.STATE_READY && loadStartedMs != 0L) {
                        metrics.onPrepared(SystemClock.elapsedRealtime() - loadStartedMs)
                    }
                    // a BUFFERING after the first frame is a mid-play stall (§ab).
                    if (state == Player.STATE_BUFFERING && firstFrameSeen) metrics.onStall()
                    if (state == Player.STATE_ENDED) {
                        metrics.onCompletion()
                        onEnded?.invoke()
                    }
                }

                override fun onRenderedFirstFrame() {
                    val now = SystemClock.elapsedRealtime()
                    if (loadStartedMs != 0L) metrics.onFirstFrame(now - loadStartedMs)
                    firstFrameSeen = true
                    log("first_frame rendered position_ms=${p.currentPosition}")
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
                    metrics.onVideoSize(videoSize.width, videoSize.height)
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
                    metrics.addDroppedFrames(droppedFrames)
                    log("dropped_frames count=$droppedFrames elapsed_ms=$elapsedMs position_ms=${p.currentPosition}")
                }

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
            log("init done backend=${backend.id} surface=SurfaceView")
        }
    }

    override fun attachSurface(view: SurfaceView) {
        runOnMain {
            surfaceView = view
            player?.setVideoSurfaceView(view)
        }
    }

    override fun detachSurface() {
        runOnMain {
            player?.clearVideoSurfaceView(surfaceView)
            surfaceView = null
        }
    }

    private fun beginLoad(uri: String, loop: Boolean, tag: String, seekMs: Long) {
        log("$tag uri=${describeUri(uri)} seekMs=$seekMs loop=$loop backend=${backend.id}")
        lastError = null
        loadStartedMs = SystemClock.elapsedRealtime()
        firstFrameSeen = false
        metrics.onLoad()
        metrics.onNewItem()
    }

    override fun loadPaused(uri: String, seekMs: Long, loop: Boolean) {
        runOnMain {
            val p = player ?: return@runOnMain
            beginLoad(uri, loop, "loadPaused", seekMs)
            p.repeatMode = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
            p.setMediaItem(ExoMediaItem.fromUri(uri))
            p.playWhenReady = false
            p.prepare()
            if (seekMs > 0) p.seekTo(seekMs)
        }
    }

    override fun loadAndPlay(uri: String, seekMs: Long, loop: Boolean) {
        runOnMain {
            val p = player ?: return@runOnMain
            beginLoad(uri, loop, "loadAndPlay", seekMs)
            p.repeatMode = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
            p.setMediaItem(ExoMediaItem.fromUri(uri))
            p.prepare()
            if (seekMs > 0) p.seekTo(seekMs)
            p.playWhenReady = true
        }
    }

    private fun describeUri(uri: String): String {
        return try {
            if (uri.startsWith("http://") || uri.startsWith("https://")) {
                "REMOTE_URL($uri)"
            } else {
                val f = java.io.File(uri.removePrefix("file://"))
                "local(${f.name},exists=${f.exists()},size=${if (f.exists()) f.length() else -1})"
            }
        } catch (e: Exception) {
            "uri($uri)"
        }
    }

    override fun play() = runOnMain { player?.playWhenReady = true }
    override fun pause() = runOnMain { player?.playWhenReady = false }

    override fun stop() = runOnMain {
        val p = player ?: return@runOnMain
        p.stop()
        p.clearMediaItems()
    }

    override fun seekTo(ms: Long) = runOnMain { player?.seekTo(ms) }

    override fun setVolume(volume0to1: Float) = runOnMain {
        player?.volume = volume0to1.coerceIn(0f, 1f)
    }

    override fun snapshot(): VideoSnapshot = blockingOnMain {
        val p = player
        if (p == null) {
            VideoSnapshot(0, 0, false, "idle", false, lastError)
        } else {
            val dur = p.duration
            VideoSnapshot(
                positionMs = p.currentPosition.coerceAtLeast(0),
                durationMs = if (dur > 0) dur else 0,
                isPlaying = p.isPlaying,
                state = stateName(p.playbackState).lowercase(),
                hasMedia = p.currentMediaItem != null,
                error = lastError,
            )
        }
    }

    override fun release() = runOnMain {
        player?.release()
        player = null
        surfaceView = null
    }

    // --- threading helpers -------------------------------------------
    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block()
        else mainHandler.post(block)
    }

    private fun <T> blockingOnMain(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = java.util.concurrent.CountDownLatch(1)
        var result: Any? = null
        mainHandler.post {
            try { result = block() } finally { latch.countDown() }
        }
        latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
        @Suppress("UNCHECKED_CAST")
        return result as T
    }
}
