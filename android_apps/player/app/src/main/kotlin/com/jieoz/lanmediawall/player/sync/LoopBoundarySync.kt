package com.jieoz.lanmediawall.player.sync

import kotlin.math.abs

/**
 * Pure loop-boundary math for the low-risk synchronization policy used on the
 * Android 4.4 fleet.
 *
 * The video backend keeps its seamless OEM loop. At each shared master-clock
 * boundary the service samples the decoder phase and calls [decide]. A seek is
 * requested only when the shortest circular phase error exceeds [toleranceMs],
 * avoiding an unconditional seek/black flash on every lap.
 */
object LoopBoundarySync {
    data class Decision(
        val expectedPositionMs: Long,
        /** Actual minus expected on the shortest path around the loop. */
        val driftMs: Long,
        /** Null means keep the decoder's seamless loop untouched. */
        val seekToMs: Long?,
    )

    /**
     * Return the first loop boundary strictly after [masterNowMs]. A non-zero
     * initial seek shortens only the first lap; subsequent laps are full length.
     */
    fun nextBoundaryMasterMs(
        playAtMasterMs: Long,
        baseSeekMs: Long,
        durationMs: Long,
        masterNowMs: Long,
    ): Long? {
        if (durationMs <= 0L) return null
        val normalizedSeek = Math.floorMod(baseSeekMs, durationMs)
        val firstBoundary = playAtMasterMs + (durationMs - normalizedSeek)
        if (masterNowMs < firstBoundary) return firstBoundary
        val completedAfterFirst = (masterNowMs - firstBoundary) / durationMs
        return firstBoundary + (completedAfterFirst + 1L) * durationMs
    }

    fun decide(
        playAtMasterMs: Long,
        baseSeekMs: Long,
        masterNowMs: Long,
        durationMs: Long,
        actualPositionMs: Long,
        toleranceMs: Long,
    ): Decision {
        if (durationMs <= 0L) {
            return Decision(expectedPositionMs = 0L, driftMs = 0L, seekToMs = null)
        }
        val expected = ContentClock.expectedOffsetMs(
            playAtMs = playAtMasterMs,
            baseSeekMs = baseSeekMs,
            nowContentDomainMs = masterNowMs,
            durationMs = durationMs,
            loop = true,
        )
        val drift = shortestCircularDriftMs(expected, actualPositionMs, durationMs)
        val seek = if (abs(drift) > toleranceMs.coerceAtLeast(0L)) expected else null
        return Decision(expectedPositionMs = expected, driftMs = drift, seekToMs = seek)
    }

    internal fun shortestCircularDriftMs(
        expectedPositionMs: Long,
        actualPositionMs: Long,
        durationMs: Long,
    ): Long {
        if (durationMs <= 0L) return actualPositionMs - expectedPositionMs
        val expected = Math.floorMod(expectedPositionMs, durationMs)
        val actual = Math.floorMod(actualPositionMs, durationMs)
        val raw = actual - expected
        val half = durationMs / 2L
        return when {
            raw > half -> raw - durationMs
            raw < -half -> raw + durationMs
            else -> raw
        }
    }
}
