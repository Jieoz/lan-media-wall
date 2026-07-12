package com.jieoz.lanmediawall.player.media

import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * §backend-ab diagnostics: per-backend A/B counters/timers, kept PURE (no Android
 * types) so the aggregation + reporting is unit-testable and identical for both
 * kernels. The Android glue feeds it real events; [summary] renders one greppable
 * line into the exported player.log / debug snapshot so old-vs-native can be
 * compared on the SAME QZX box from a pulled log, not guessed at.
 *
 * Only metrics BOTH kernels can honestly provide are first-class; a kernel that
 * cannot measure something (e.g. MediaPlayer has no dropped-frame callback) leaves
 * that counter at its sentinel and [summary] renders it as `n/a`, never a fake 0.
 *
 * Timers are stamped by the caller (elapsedRealtime) so this class stays clockless.
 */
class BackendMetrics {

    // --- prepare / first-frame latency (both kernels) ----------------------
    /** load→prepared/ready latency of the most recent load, ms. -1 = not yet. */
    @Volatile var lastPrepareMs: Long = -1
    /** load→first-frame-rendered latency of the most recent load, ms. -1 = not yet. */
    @Volatile var lastFirstFrameMs: Long = -1

    // --- lifecycle counts --------------------------------------------------
    private val loads = AtomicInteger(0)
    private val prepared = AtomicInteger(0)
    private val firstFrames = AtomicInteger(0)
    private val completions = AtomicInteger(0)
    private val errors = AtomicInteger(0)
    /** buffering/stall ENTER events after the first frame (a true mid-play stall,
     *  not the initial buffering). Both kernels can observe this. */
    private val stalls = AtomicInteger(0)

    // --- dropped frames (ExoPlayer only; MediaPlayer cannot report) --------
    /** cumulative dropped video frames, or -1 when the kernel can't measure it. */
    private val droppedFrames = AtomicLong(SENTINEL)

    // --- video dimensions of the current item (both kernels) ---------------
    @Volatile private var videoW: Int = 0
    @Volatile private var videoH: Int = 0

    @Volatile private var lastError: String? = null

    fun onLoad() { loads.incrementAndGet() }

    fun onPrepared(prepareMs: Long) {
        prepared.incrementAndGet()
        if (prepareMs >= 0) lastPrepareMs = prepareMs
    }

    fun onFirstFrame(firstFrameMs: Long) {
        firstFrames.incrementAndGet()
        if (firstFrameMs >= 0) lastFirstFrameMs = firstFrameMs
    }

    fun onCompletion() { completions.incrementAndGet() }

    fun onStall() { stalls.incrementAndGet() }

    fun onError(code: String) {
        errors.incrementAndGet()
        lastError = code
    }

    fun onVideoSize(w: Int, h: Int) {
        if (w > 0 && h > 0) { videoW = w; videoH = h }
    }

    /** Declare that this kernel CAN measure dropped frames, initializing the
     *  counter to 0 so it renders as a real number rather than `n/a`. */
    fun enableDroppedFrames() {
        droppedFrames.compareAndSet(SENTINEL, 0L)
    }

    /** Add newly dropped frames (ExoPlayer's onDroppedVideoFrames). No-op if the
     *  counter was never enabled. */
    fun addDroppedFrames(count: Int) {
        if (count <= 0) return
        // only accumulate once the kernel has opted in via enableDroppedFrames()
        droppedFrames.updateAndGet { cur -> if (cur == SENTINEL) SENTINEL else cur + count }
    }

    /** Reset per-item fields (dimensions, latency of the *current* item) while
     *  keeping cumulative session counters, so the summary reflects the item that
     *  is on screen now. Called on each new load. */
    fun onNewItem() {
        videoW = 0; videoH = 0
        lastPrepareMs = -1; lastFirstFrameMs = -1
    }

    private fun frameOrNa(): String {
        val v = droppedFrames.get()
        return if (v == SENTINEL) "n/a" else v.toString()
    }

    /** One greppable line for the exported log / debug snapshot. */
    fun summary(): String = buildString {
        append("loads="); append(loads.get())
        append(" prepared="); append(prepared.get())
        append(" first_frames="); append(firstFrames.get())
        append(" completions="); append(completions.get())
        append(" stalls="); append(stalls.get())
        append(" errors="); append(errors.get())
        append(" prepare_ms="); append(lastPrepareMs)
        append(" first_frame_ms="); append(lastFirstFrameMs)
        append(" dropped_frames="); append(frameOrNa())
        append(" video="); append(if (videoW > 0) "${videoW}x${videoH}" else "?")
        append(" last_error="); append(lastError ?: "none")
    }

    companion object {
        /** Sentinel for "this kernel cannot measure dropped frames". */
        const val SENTINEL = -1L
    }
}
