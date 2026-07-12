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
    /** §6.4 root-performance: one cached thumbnail per item (keyed by itemId). */
    private val thumbnailCache = java.util.concurrent.ConcurrentHashMap<String, Pair<Int, ByteArray>>()

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
        }
    }

    /** Existing cached JPEG → existing ImageView while the single decoder rebuilds. */
    fun showTransitionFrame(jpeg: ByteArray?): Boolean {
        val bmp = jpeg?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
        if (bmp == null || imageView == null) return false
        runOnMain {
            if (transitionState.begin(true) == VideoTransitionStateMachine.Action.SHOW_CACHED_FRAME) {
                imageView?.let { iv ->
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
        hideImage()
        lastError = null
        videoBackend.loadPaused(uri, seekMs, loop)
    }

    /** Load and start playing immediately (used for non-synced / advance). */
    fun loadAndPlay(uri: String, seekMs: Long = 0, loop: Boolean = false, preserveOverlay: Boolean = false) {
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
        videoBackend.pause()
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

    fun stop() {
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

    /** Drop cached thumbnails for items no longer referenced (playlist change). */
    fun retainThumbnails(keepItemIds: Set<String>) {
        thumbnailCache.keys.retainAll(keepItemIds)
    }

    /**
     * Extract ONE frame from the local cached video and memoize it under [itemId].
     * Decoder-independent (MediaMetadataRetriever), so identical for both kernels.
     * The caller must only invoke it while the video is NOT actively playing.
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

    fun release() {
        videoBackend.release()
        runOnMain { imageView = null }
    }

    private fun log(msg: String) { logSink?.invoke(msg) }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block()
        else mainHandler.post(block)
    }
}
