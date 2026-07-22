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
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Playback facade — the Android analogue of windows_player's mpv controller. Owns
 * ONE swappable [VideoBackend] (ExoPlayer or native MediaPlayer — §backend-ab) and
 * exposes the operations the protocol drives: load/play(at)/pause/seek/volume/mute
 * + a current-frame snapshot for thumbnails (§6.4).
 *
 * The video KERNEL is chosen once at construction ([backend]); everything the
 * service calls is kernel-agnostic. Image display (§6.1) and thumbnail extraction
 * (§6.4) stay here because they use BitmapFactory / MediaMetadataRetriever, which
 * are decoder-independent — so switching kernels never touches them.
 *
 * Threading: the backend marshals video ops to the main thread; image ops here
 * marshal via [mainHandler]; thumbnail extraction runs on Dispatchers.IO.
 */
class PlayerController(
    context: Context,
    private val videoBackend: VideoBackend,
) {

    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var imageView: ImageView? = null
    @Volatile private var lastError: String? = null
    private val thumbSeq = AtomicInteger(0)
    private val thumbnailFlight = ThumbnailSingleFlight()
    private val transitionState = VideoTransitionStateMachine()
    @Volatile private var loopOverlayJpeg: ByteArray? = null
    @Volatile private var loopOverlayItemId: String? = null
    private val loopOverlayOwner = LoopOverlayOwner()
    @Volatile private var loopOverlayToken: LoopOverlayOwner.Token? = null
    /** §6.4 root-performance: one cached thumbnail per item (keyed by itemId). */
    private val thumbnailCache = java.util.concurrent.ConcurrentHashMap<String, Pair<Int, ByteArray>>()
    /**
     * Near-fullscreen JPEG used as a freeze overlay while the single VDEC rebuilds
     * on item-to-item advance (API19 has no PixelCopy). Separate from the small
     * controller thumb so a 320px preview never becomes the wall mask.
     */
    private val freezeFrameCache = java.util.concurrent.ConcurrentHashMap<String, ByteArray>()

    /** Which video kernel is active (for diagnostics/status). */
    val backend: PlayerBackend get() = videoBackend.backend

    /** §backend-ab: the active kernel's A/B metrics. */
    val metrics: BackendMetrics get() = videoBackend.metrics

    /** §hardware-decode: last video decoder the kernel reported, or null (native
     *  MediaPlayer never exposes it). */
    val lastVideoDecoderName: String? get() = videoBackend.lastVideoDecoderName

    /** Called when the kernel reports an unrecoverable error (watchdog hook). */
    var onPlayerError: ((String) -> Unit)?
        get() = videoBackend.onError
        set(value) {
            videoBackend.onError = { error ->
                finishTransition(failed = true)
                value?.invoke(error)
            }
        }

    /** Called once when a non-looping video reaches its end (§6.3 carousel). */
    var onVideoEnded: (() -> Unit)?
        get() = videoBackend.onEnded
        set(value) { videoBackend.onEnded = value }

    /**
     * Diagnostic sink → PlayerService.logEvent, so decode-path events land in the
     * EXPORTED player.log rather than the truncated logcat. Setting it wires the
     * kernel's sink too (prefixing so both kernels' lines are greppable).
     */
    var logSink: ((String) -> Unit)? = null
        set(value) {
            field = value
            videoBackend.logSink = value
        }

    fun init() = videoBackend.init()

    fun attachSurface(view: SurfaceView) = videoBackend.attachSurface(view)

    /** Attach the ImageView used to draw `type=="image"` playlist items (§6.1). */
    fun attachImageView(view: ImageView) {
        runOnMain {
            imageView = view
            videoBackend.onFirstFrame = {
                finishTransition(failed = false)
            }
            videoBackend.onLoopBoundary = boundary@{ action ->
                val token = loopOverlayToken
                if (token == null || !loopOverlayOwner.accepts(token)) return@boundary
                when (action) {
                    LoopBoundaryStateMachine.Action.SHOW_OVERLAY -> showTransitionFrame(loopOverlayJpeg)
                    LoopBoundaryStateMachine.Action.HIDE_OVERLAY -> hideImage()
                    LoopBoundaryStateMachine.Action.NONE -> Unit
                }
            }
        }
    }

    /** Existing cached JPEG → existing ImageView while the single decoder rebuilds. */
    fun showTransitionFrame(jpeg: ByteArray?): Boolean {
        val bmp = jpeg?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
        if (bmp == null || imageView == null) return false
        runOnMain {
            if (transitionState.begin(true) == VideoTransitionStateMachine.Action.SHOW_CACHED_FRAME) {
                imageView?.let { iv ->
                    // Cover the full SurfaceView — fitCenter leaves black bars around a
                    // small freeze/thumbnail and reads as a black flash on kitkat boxes.
                    iv.scaleType = ImageView.ScaleType.CENTER_CROP
                    iv.setImageBitmap(bmp)
                    iv.visibility = ImageView.VISIBLE
                }
            }
        }
        return true
    }

    private fun finishTransition(failed: Boolean) {
        runOnMain {
            val action = if (failed) transitionState.failed() else transitionState.firstFrameRendered()
            if (action == VideoTransitionStateMachine.Action.HIDE_OVERLAY) hideImage()
        }
    }

    fun detachSurface() {
        videoBackend.detachSurface()
        runOnMain { imageView = null }
    }

    /** Load a file/URL, seek, and stay paused — primes for a synced start. */
    fun loadPaused(uri: String, seekMs: Long = 0, loop: Boolean = false) {
        if (!loop) disarmLoopOverlay()
        hideImage()
        lastError = null
        videoBackend.loadPaused(uri, seekMs, loop)
    }

    /** Load and start playing immediately (used for non-synced / advance). */
    fun loadAndPlay(uri: String, seekMs: Long = 0, loop: Boolean = false, preserveOverlay: Boolean = false) {
        if (!loop) disarmLoopOverlay()
        if (!preserveOverlay) hideImage()
        lastError = null
        videoBackend.loadAndPlay(uri, seekMs, loop)
    }

    fun play() = videoBackend.play()
    fun pause() = videoBackend.pause()

    /** §8.2: arm late-start compensation for the next synced [play] (see VideoBackend). */
    fun armSyncStart(localTargetWallMs: Long, baseSeekMs: Long, loop: Boolean) =
        videoBackend.armSyncStart(localTargetWallMs, baseSeekMs, loop)

    /**
     * §6.1 image item: decode a local file and show it on the ImageView above the
     * video surface, pausing + hiding the video so a still actually appears (the
     * video kernels can't render one). No-op if the ImageView isn't attached yet.
     *
     * When [itemId] is set, also stash a freeze JPEG so a later video advance can
     * cover the surface without first dropping to black.
     */
    fun showImage(path: String, itemId: String? = null) = runOnMain {
        disarmLoopOverlay()
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
        videoBackend.pause()
        iv.scaleType = ImageView.ScaleType.FIT_CENTER
        iv.setImageBitmap(bmp)
        iv.visibility = ImageView.VISIBLE
        if (itemId != null) {
            // Best-effort freeze for the next video transition (centerCrop covers wall).
            try {
                val out = ByteArrayOutputStream(64 * 1024)
                if (bmp.compress(Bitmap.CompressFormat.JPEG, 85, out)) {
                    freezeFrameCache[itemId] = out.toByteArray()
                }
            } catch (_: Exception) {
            }
        }
    }

    /** Hide the image layer (called when switching back to video). */
    fun hideImage() = runOnMain {
        imageView?.let {
            it.visibility = ImageView.GONE
            it.setImageDrawable(null)
            // Images use fitCenter; transition freezes use centerCrop — restore default.
            it.scaleType = ImageView.ScaleType.FIT_CENTER
        }
    }

    fun stop() {
        disarmLoopOverlay()
        videoBackend.stop()
        hideImage()
    }

    fun seekTo(ms: Long) = videoBackend.seekTo(ms)

    /** ExoPlayer/MediaPlayer volume is 0.0–1.0; protocol volume is 0–100. */
    fun setVolume(volume0to100: Int) =
        videoBackend.setVolume(volume0to100.coerceIn(0, 100) / 100f)

    fun setMuted(muted: Boolean) =
        videoBackend.setVolume(if (muted) 0f else currentVolumePercent / 100f)

    @Volatile var currentVolumePercent: Int = 80

    /** Snapshot of position/duration/paused/volume — for §5 status. Kept the same
     *  shape the service already reads (positionMs/durationMs/error). */
    data class Snapshot(
        val positionMs: Long,
        val durationMs: Long,
        val isPlaying: Boolean,
        val state: String,
        val hasMedia: Boolean,
        val error: String?,
    )

    fun snapshot(): Snapshot {
        val s = videoBackend.snapshot()
        return Snapshot(
            positionMs = s.positionMs,
            durationMs = s.durationMs,
            isPlaying = s.isPlaying,
            state = s.state,
            hasMedia = s.hasMedia,
            error = s.error ?: lastError,
        )
    }

    /** §backend-ab: one greppable diagnostics line — active kernel + its metrics.
     *  Fed into PlayerService's debug snapshot / status so old-vs-native is
     *  comparable from a pulled log on the real box. */
    fun backendDiagnostics(): String =
        "backend=${backend.id} decoder=${lastVideoDecoderName ?: "n/a"}; ${metrics.summary()}"

    /** §6.4: the thumbnail already captured for [itemId], or null if none yet. */
    fun cachedThumbnail(itemId: String): Pair<Int, ByteArray>? = thumbnailCache[itemId]

    /**
     * Best freeze JPEG for an item-to-item transition: prefer the near-fullscreen
     * freeze cache, fall back to the controller thumb (still better than black).
     */
    fun cachedFreezeFrame(itemId: String): ByteArray? =
        freezeFrameCache[itemId] ?: thumbnailCache[itemId]?.second

    /** Select an already-captured frame for the current single-item loop source. */
    fun armLoopOverlay(itemId: String?) {
        loopOverlayToken = loopOverlayOwner.arm(itemId)
        loopOverlayItemId = itemId
        loopOverlayJpeg = itemId?.let { cachedFreezeFrame(it) }
        videoBackend.hasLoopBoundaryFrame = loopOverlayJpeg != null
    }

    private fun disarmLoopOverlay() {
        loopOverlayOwner.disarm()
        loopOverlayToken = null
        loopOverlayItemId = null
        loopOverlayJpeg = null
        videoBackend.hasLoopBoundaryFrame = false
        hideImage()
    }

    /** Drop cached thumbnails for items no longer referenced (playlist change). */
    fun retainThumbnails(keepItemIds: Set<String>) {
        thumbnailCache.keys.retainAll(keepItemIds)
        freezeFrameCache.keys.retainAll(keepItemIds)
    }

    /**
     * Extract ONE frame from the local cached video and memoize it under [itemId].
     * Decoder-independent (MediaMetadataRetriever), so identical for both kernels.
     * Also stores a higher-res freeze JPEG for item-to-item transition masks.
     * The caller must only invoke it while the video is NOT actively playing.
     */
    suspend fun captureThumbnail(
        itemId: String,
        mediaType: String,
        sourcePath: String,
        positionMs: Long,
        maxWidth: Int = ThumbnailPolicy.CONTROLLER_THUMB_MAX_WIDTH,
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
            val frame = if (mediaType == "image") {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(file.absolutePath, bounds)
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                    null
                } else {
                    var sample = 1
                    while (maxOf(bounds.outWidth, bounds.outHeight) / sample >
                            ThumbnailPolicy.TRANSITION_FREEZE_MAX_WIDTH * 2) {
                        sample *= 2
                    }
                    val decoded = BitmapFactory.decodeFile(
                        file.absolutePath,
                        BitmapFactory.Options().apply {
                            inSampleSize = sample
                            inPreferredConfig = Bitmap.Config.ARGB_8888
                        },
                    )
                    val bounded = decoded?.let { source ->
                        val largest = maxOf(source.width, source.height)
                        val limit = ThumbnailPolicy.TRANSITION_FREEZE_MAX_WIDTH
                        if (largest > limit) {
                            val targetWidth =
                                (source.width.toLong() * limit / largest).toInt()
                                    .coerceAtLeast(1)
                            val targetHeight =
                                (source.height.toLong() * limit / largest).toInt()
                                    .coerceAtLeast(1)
                            Bitmap.createScaledBitmap(
                                source, targetWidth, targetHeight, true,
                            ).also { source.recycle() }
                        } else {
                            source
                        }
                    }
                    bounded
                }
            } else {
                val retriever = MediaMetadataRetriever()
                try {
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
                }
            } ?: return@withContext null
            val extractMs = SystemClock.elapsedRealtime() - extractStarted
            // One decode → freeze (near-fullscreen) + controller thumb (small).
            val freezeTarget = ThumbnailPolicy.captureSize(
                frame.width, frame.height, ThumbnailPolicy.TRANSITION_FREEZE_MAX_WIDTH,
            )
            if (freezeTarget != null && freezeFrameCache[itemId] == null) {
                val freezeBmp = if (frame.width == freezeTarget.width && frame.height == freezeTarget.height) {
                    frame
                } else {
                    Bitmap.createScaledBitmap(frame, freezeTarget.width, freezeTarget.height, true)
                }
                val freezeOut = ByteArrayOutputStream(96 * 1024)
                if (freezeBmp.compress(Bitmap.CompressFormat.JPEG, 82, freezeOut)) {
                    freezeFrameCache[itemId] = freezeOut.toByteArray()
                }
                if (freezeBmp !== frame) freezeBmp.recycle()
            }
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
                "freeze_bytes=${freezeFrameCache[itemId]?.size ?: 0} " +
                "heap_used=${runtime.totalMemory() - runtime.freeMemory()} heap_max=${runtime.maxMemory()}")
            bmp.recycle()
            val captured = thumbSeq.incrementAndGet() to jpeg
            thumbnailCache[itemId] = captured
            if (loopOverlayItemId == itemId) {
                loopOverlayJpeg = cachedFreezeFrame(itemId) ?: jpeg
                videoBackend.hasLoopBoundaryFrame = true
            }
            captured
        } finally {
            lease.close()
        }
    }

    fun release() {
        disarmLoopOverlay()
        videoBackend.release()
        runOnMain { imageView = null }
    }

    private fun log(msg: String) { logSink?.invoke(msg) }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block()
        else mainHandler.post(block)
    }
}
