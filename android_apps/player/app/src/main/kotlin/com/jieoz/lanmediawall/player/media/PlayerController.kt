package com.jieoz.lanmediawall.player.media

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.TextureView
import androidx.media3.common.MediaItem as ExoMediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import java.io.ByteArrayOutputStream
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
@androidx.media3.common.util.UnstableApi
class PlayerController(context: Context) {

    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var player: ExoPlayer? = null
    @Volatile private var textureView: TextureView? = null
    @Volatile private var lastError: String? = null
    private val thumbSeq = AtomicInteger(0)

    /** Called when ExoPlayer reports an unrecoverable error (watchdog hook). */
    @Volatile var onPlayerError: ((String) -> Unit)? = null

    fun init() {
        runOnMain {
            if (player != null) return@runOnMain
            val p = ExoPlayer.Builder(appContext).build()
            p.repeatMode = Player.REPEAT_MODE_OFF
            p.playWhenReady = false
            p.addListener(object : Player.Listener {
                override fun onPlayerError(error: PlaybackException) {
                    lastError = error.errorCodeName
                    onPlayerError?.invoke(error.errorCodeName)
                }
            })
            player = p
            textureView?.let { p.setVideoTextureView(it) }
        }
    }

    fun attachSurface(view: TextureView) {
        runOnMain {
            textureView = view
            player?.setVideoTextureView(view)
        }
    }

    fun detachSurface() {
        runOnMain {
            player?.clearVideoTextureView(textureView)
            textureView = null
        }
    }

    /** Load a file/URL, seek, and stay paused — primes for a synced start. */
    fun loadPaused(uri: String, seekMs: Long = 0, loop: Boolean = false) {
        runOnMain {
            val p = player ?: return@runOnMain
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
            p.repeatMode = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
            p.setMediaItem(ExoMediaItem.fromUri(uri))
            p.prepare()
            if (seekMs > 0) p.seekTo(seekMs)
            p.playWhenReady = true
        }
    }

    fun play() = runOnMain { player?.playWhenReady = true }
    fun pause() = runOnMain { player?.playWhenReady = false }

    fun stop() = runOnMain {
        val p = player ?: return@runOnMain
        p.stop()
        p.clearMediaItems()
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
                    view.getBitmap(view.width, view.height)
                } catch (e: Exception) {
                    null
                }
            }
        } ?: return null

        val scaled = scaleToWidth(bmp, maxWidth)
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), out)
        if (scaled !== bmp) scaled.recycle()
        bmp.recycle()
        return thumbSeq.incrementAndGet() to out.toByteArray()
    }

    private fun scaleToWidth(src: Bitmap, maxWidth: Int): Bitmap {
        if (src.width <= maxWidth) return src
        val ratio = maxWidth.toFloat() / src.width
        val h = (src.height * ratio).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(src, maxWidth, h, true)
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
