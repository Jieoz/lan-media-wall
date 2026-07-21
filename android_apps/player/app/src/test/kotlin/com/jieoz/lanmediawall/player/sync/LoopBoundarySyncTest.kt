package com.jieoz.lanmediawall.player.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** RED-first contract for bounded single-video loop resynchronization.
 *
 * We keep the decoder's seamless OEM loop and only seek when the phase error at
 * a shared master-clock loop boundary exceeds the tolerance.
 */
class LoopBoundarySyncTest {

    @Test fun `next boundary accounts for a nonzero initial seek`() {
        assertEquals(68_000L, LoopBoundarySync.nextBoundaryMasterMs(
            playAtMasterMs = 10_000,
            baseSeekMs = 2_000,
            durationMs = 60_000,
            masterNowMs = 20_000,
        ))
        assertEquals(128_000L, LoopBoundarySync.nextBoundaryMasterMs(
            playAtMasterMs = 10_000,
            baseSeekMs = 2_000,
            durationMs = 60_000,
            masterNowMs = 68_000,
        ))
    }

    @Test fun `small circular phase error at loop boundary does not seek`() {
        val decision = LoopBoundarySync.decide(
            playAtMasterMs = 10_000,
            baseSeekMs = 0,
            masterNowMs = 70_030,
            durationMs = 60_000,
            actualPositionMs = 60_000 - 20,
            toleranceMs = 80,
        )
        assertEquals(30L, decision.expectedPositionMs)
        assertEquals(-50L, decision.driftMs)
        assertNull(decision.seekToMs)
    }

    @Test fun `lagging phase beyond tolerance seeks to master projection`() {
        val decision = LoopBoundarySync.decide(
            playAtMasterMs = 10_000,
            baseSeekMs = 0,
            masterNowMs = 70_050,
            durationMs = 60_000,
            actualPositionMs = 59_800,
            toleranceMs = 80,
        )
        assertEquals(50L, decision.expectedPositionMs)
        assertEquals(-250L, decision.driftMs)
        assertEquals(50L, decision.seekToMs)
    }

    @Test fun `leading phase beyond tolerance seeks to master projection`() {
        val decision = LoopBoundarySync.decide(
            playAtMasterMs = 10_000,
            baseSeekMs = 0,
            masterNowMs = 70_050,
            durationMs = 60_000,
            actualPositionMs = 260,
            toleranceMs = 80,
        )
        assertEquals(210L, decision.driftMs)
        assertEquals(50L, decision.seekToMs)
    }

    @Test fun `unknown duration disables boundary scheduling and correction`() {
        assertNull(LoopBoundarySync.nextBoundaryMasterMs(10, 0, 0, 20))
        assertNull(LoopBoundarySync.decide(10, 0, 20, 0, 5, 80).seekToMs)
    }
}
