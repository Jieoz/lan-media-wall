package com.jieoz.lanmediawall.player.media

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.view.TextureView
import android.widget.ImageView
import com.google.android.exoplayer2.MediaItem as ExoMediaItem
import com.google.android.exoplayer2.PlaybackException
import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.ExoPlayer
import com.google.android.exoplayer2.video.VideoSize
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

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
    @Volatile private var textureView: TextureView? = null
    @Volatile private var imageView: ImageView? = null
    @Volatile private var lastError: String? = null
    private val thumbSeq = AtomicInteger(0)

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

    fun init() {
        runOnMain {
            if (player != null) return@runOnMain
            val p = ExoPlayer.Builder(appContext).build()
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
                    log("first_frame rendered")
                }

                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    log("video_size ${videoSize.width}x${videoSize.height} " +
                        "par=${videoSize.pixelWidthHeightRatio}")
                }

                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    log("is_playing $isPlaying")
                }
            })
            player = p
            textureView?.let { p.setVideoTextureView(it) }
            log("init done")
        }
    }

    fun attachSurface(view: TextureView) {
        runOnMain {
            textureView = view
            player?.setVideoTextureView(view)
        }
    }

    /** Attach the ImageView used to draw `type=="image"` playlist items (§6.1). */
    fun attachImageView(view: ImageView) {
        runOnMain { imageView = view }
    }

    fun detachSurface() {
        runOnMain {
            player?.clearVideoTextureView(textureView)
            textureView = null
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

    /**
     * Capture the current video frame as a ≤[maxWidth]px-wide JPEG (§6.4).
     * Reads pixels off the attached TextureView (works for video surfaces).
     * Returns (seq, jpegBytes) or null if no frame is available.
     */
    fun captureThumbnail(maxWidth: Int = 320, quality: Int = 70): Pair<Int, ByteArray>? {
        val view = textureView ?: return null
        val bmp = blockingOnMain {
            if (view.width <= 0 || view.height <= 0 || !view.isAvailable) {
                null
            } else {
                try {
                    val target = ThumbnailPolicy.captureSize(view.width, view.height, maxWidth)
                        ?: return@blockingOnMain null
                    // TextureView has a sized getBitmap overload on API 14+. Capture
                    // directly into the thumbnail-sized allocation: never allocate a
                    // 1920x1080 Java Bitmap merely to scale it down afterwards.
                    view.getBitmap(target.width, target.height)
                } catch (e: Exception) {
                    null
                }
            }
        } ?: return null

        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), out)
        bmp.recycle()
        return thumbSeq.incrementAndGet() to out.toByteArray()
    }


    fun release() = runOnMain {
        player?.release()
        player = null
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
