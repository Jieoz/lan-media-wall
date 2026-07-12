package com.jieoz.lanmediawall.player.sync

/**
 * §8.2 content-time math — PURE, unit-tested, no Android / no I/O.
 *
 * [ClockSync] answers "what local wall-clock instant equals a broker master
 * instant?". This answers the NEXT question the synced start needs: "given a
 * play_at and a base seek, what CONTENT position should the video be at right
 * now?" — and, when the real start slips late (MediaPlayer.prepareAsync can
 * finish after play_at), "what should we seek to so this box lands at the same
 * frame as every other box instead of trailing by the prepare latency?"
 *
 * All times here are in ONE consistent domain (caller folds master→local first);
 * durations are ms. Loop wrap is modeled explicitly so a looping clip's expected
 * offset stays bounded to [0, duration).
 */
object ContentClock {

    /** Below this, a late start is treated as on-time (seek jitter isn't worth a
     *  correcting seek that itself costs a frame). Public so the backend + tests
     *  agree on the exact boundary. */
    const val LATE_START_THRESHOLD_MS = 40L

    /**
     * Content offset (ms into the clip) the item should be showing at
     * [nowContentDomainMs], for a synced start scheduled at [playAtMs] with a base
     * seek of [baseSeekMs]. All three args share ONE clock domain.
     *
     * Before play_at → clamps to [baseSeekMs] (we haven't started; the primed
     * frame is the seek point). After play_at → baseSeek + elapsed, wrapped into
     * [0,duration) when [loop] and [durationMs] is known (>0).
     */
    fun expectedOffsetMs(
        playAtMs: Long,
        baseSeekMs: Long,
        nowContentDomainMs: Long,
        durationMs: Long,
        loop: Boolean,
    ): Long {
        val base = baseSeekMs.coerceAtLeast(0)
        val elapsed = nowContentDomainMs - playAtMs
        if (elapsed <= 0) return base
        val raw = base + elapsed
        return wrap(raw, durationMs, loop)
    }

    /**
     * The position to seek to when the real start happens [actualStartMs] instead
     * of the scheduled [playAtMs] (both same domain). If we're late by more than
     * [LATE_START_THRESHOLD_MS], compensate by that lateness so we join the wall
     * at the correct frame; otherwise just use the base seek. Wrapped for loops.
     *
     * Returns null when no correcting seek is warranted (on-time within the
     * threshold) so the caller can skip a needless seek.
     */
    fun lateStartSeekMs(
        playAtMs: Long,
        baseSeekMs: Long,
        actualStartMs: Long,
        durationMs: Long,
        loop: Boolean,
    ): Long? {
        val base = baseSeekMs.coerceAtLeast(0)
        val lateMs = actualStartMs - playAtMs
        if (lateMs <= LATE_START_THRESHOLD_MS) return null
        return wrap(base + lateMs, durationMs, loop)
    }

    /** Signed drift (ms): how far [actualOffsetMs] is AHEAD of [expectedOffsetMs].
     *  Positive = playing ahead of the wall; negative = trailing. */
    fun driftMs(expectedOffsetMs: Long, actualOffsetMs: Long): Long =
        actualOffsetMs - expectedOffsetMs

    /**
     * Whether an observed [driftMs] warrants a correcting seek, given a tolerance.
     * A correcting seek costs a visible frame on the OEM path, so callers use a
     * deliberately generous tolerance and only correct sustained drift — never
     * micro-jitter. Loop wrap can make a raw difference look huge (e.g. −duration+ε
     * ≈ +ε), so the magnitude is measured on the circle when [loop]+[durationMs].
     */
    fun needsCorrection(driftMs: Long, toleranceMs: Long, durationMs: Long, loop: Boolean): Boolean {
        val mag = if (loop && durationMs > 0) {
            val m = ((driftMs % durationMs) + durationMs) % durationMs
            minOf(m, durationMs - m)
        } else {
            kotlin.math.abs(driftMs)
        }
        return mag > toleranceMs
    }

    /** Wrap a raw content position into [0,duration) for loops; clamp to
     *  [0,duration] for non-loops (or pass through when duration unknown). */
    private fun wrap(rawMs: Long, durationMs: Long, loop: Boolean): Long {
        if (durationMs <= 0) return rawMs.coerceAtLeast(0)
        return if (loop) ((rawMs % durationMs) + durationMs) % durationMs
        else rawMs.coerceIn(0, durationMs)
    }
}
