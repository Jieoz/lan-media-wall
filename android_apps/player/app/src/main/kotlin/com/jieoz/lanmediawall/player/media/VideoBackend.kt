package com.jieoz.lanmediawall.player.media

import android.view.SurfaceView

/**
 * §backend-ab: the video-playback contract shared by the ExoPlayer kernel
 * ([ExoVideoBackend]) and the native `android.media.MediaPlayer` kernel
 * ([MediaPlayerVideoBackend]). [PlayerController] owns exactly one of these and
 * delegates every video operation to it, so the whole service/protocol layer is
 * kernel-agnostic and A/B selection is a single swap at construction.
 *
 * Image display + thumbnail extraction are NOT here: they use BitmapFactory /
 * MediaMetadataRetriever which are decoder-independent, so the facade keeps them.
 *
 * Threading contract: every method is called on the app MAIN thread (the facade
 * marshals). Implementations must not block. Callbacks fire on the main thread.
 */
interface VideoBackend {

    /** Which kernel this is — for logs/diagnostics. */
    val backend: PlayerBackend

    /** Selected video decoder name if the kernel can report it, else null.
     *  ExoPlayer reports it; MediaPlayer does not expose it (stays null). */
    val lastVideoDecoderName: String?

    /** Per-backend A/B metrics accumulator (never null). */
    val metrics: BackendMetrics

    /** Terse diagnostic sink → exported player.log. Set before [init]. */
    var logSink: ((String) -> Unit)?

    /** Fired when the kernel reports an unrecoverable playback error (watchdog
     *  hook). The string is a greppable, kernel-specific error code. */
    var onError: ((String) -> Unit)?

    /** Fired once when a NON-looping video reaches end-of-stream, so the service
     *  advances the playlist (§6.3). Looping playback never fires this. */
    var onEnded: (() -> Unit)?

    /** Build the kernel (idempotent). */
    fun init()

    /** Attach/replace the output SurfaceView. May be called before or after [init]. */
    fun attachSurface(view: SurfaceView)

    /** Detach the output surface (Activity teardown). */
    fun detachSurface()

    /** Load a source, seek to [seekMs], and stay PAUSED — primes for a synced start. */
    fun loadPaused(uri: String, seekMs: Long, loop: Boolean)

    /** Load a source and start playing immediately (non-synced / advance). */
    fun loadAndPlay(uri: String, seekMs: Long, loop: Boolean)

    fun play()
    fun pause()
    fun stop()
    fun seekTo(ms: Long)

    /** Set output volume, 0.0–1.0 (facade already folded percent/mute). */
    fun setVolume(volume0to1: Float)

    /** Current playback snapshot for §5 status. */
    fun snapshot(): VideoSnapshot

    /** Release all native resources. */
    fun release()
}

/**
 * Kernel-agnostic playback snapshot. Only [positionMs]/[durationMs]/[error] are
 * consumed by the service today; the rest aid diagnostics. `state` is a short
 * kernel-agnostic label (idle/buffering/ready/ended/error), NOT an ExoPlayer int.
 */
data class VideoSnapshot(
    val positionMs: Long,
    val durationMs: Long,
    val isPlaying: Boolean,
    val state: String,
    val hasMedia: Boolean,
    val error: String?,
)
