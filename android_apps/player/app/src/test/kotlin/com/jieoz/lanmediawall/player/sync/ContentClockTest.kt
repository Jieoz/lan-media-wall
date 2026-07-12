package com.jieoz.lanmediawall.player.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * §8.2 deterministic content-time + late-start-compensation contract. These pin
 * the exact math that keeps a MediaPlayer synced start landing on the same frame
 * across boxes even when prepareAsync finishes after play_at.
 */
class ContentClockTest {

    // --- expectedOffsetMs -------------------------------------------------

    @Test fun `before play_at expected offset is the base seek`() {
        assertEquals(2_000L, ContentClock.expectedOffsetMs(
            playAtMs = 10_000, baseSeekMs = 2_000, nowContentDomainMs = 9_000,
            durationMs = 60_000, loop = false))
    }

    @Test fun `after play_at expected offset advances with elapsed`() {
        assertEquals(5_000L, ContentClock.expectedOffsetMs(
            playAtMs = 10_000, baseSeekMs = 2_000, nowContentDomainMs = 13_000,
            durationMs = 60_000, loop = false))
    }

    @Test fun `non-loop clamps at duration`() {
        assertEquals(60_000L, ContentClock.expectedOffsetMs(
            playAtMs = 0, baseSeekMs = 0, nowContentDomainMs = 120_000,
            durationMs = 60_000, loop = false))
    }

    @Test fun `loop wraps expected offset into range`() {
        // 70s of a 60s loop = 10s in.
        assertEquals(10_000L, ContentClock.expectedOffsetMs(
            playAtMs = 0, baseSeekMs = 0, nowContentDomainMs = 70_000,
            durationMs = 60_000, loop = true))
    }

    // --- lateStartSeekMs (the core sync fix) ------------------------------

    @Test fun `on-time start needs no correcting seek`() {
        // 20ms late < 40ms threshold → null (skip the seek).
        assertNull(ContentClock.lateStartSeekMs(
            playAtMs = 10_000, baseSeekMs = 0, actualStartMs = 10_020,
            durationMs = 60_000, loop = false))
    }

    @Test fun `late start compensates by the lateness`() {
        // prepareAsync finished 300ms after play_at → start 300ms in (base 0)
        // so this box matches peers that started on time.
        assertEquals(300L, ContentClock.lateStartSeekMs(
            playAtMs = 10_000, baseSeekMs = 0, actualStartMs = 10_300,
            durationMs = 60_000, loop = false))
    }

    @Test fun `late start adds lateness onto a base seek`() {
        assertEquals(5_300L, ContentClock.lateStartSeekMs(
            playAtMs = 10_000, baseSeekMs = 5_000, actualStartMs = 10_300,
            durationMs = 60_000, loop = false))
    }

    @Test fun `late start on a loop wraps the compensated seek`() {
        // base 59_800 + 400 late = 60_200 → wraps to 200 in a 60s loop.
        assertEquals(200L, ContentClock.lateStartSeekMs(
            playAtMs = 0, baseSeekMs = 59_800, actualStartMs = 400,
            durationMs = 60_000, loop = true))
    }

    // --- drift ------------------------------------------------------------

    @Test fun `drift is actual minus expected`() {
        assertEquals(120L, ContentClock.driftMs(expectedOffsetMs = 5_000, actualOffsetMs = 5_120))
        assertEquals(-80L, ContentClock.driftMs(expectedOffsetMs = 5_000, actualOffsetMs = 4_920))
    }

    @Test fun `small drift within tolerance needs no correction`() {
        assertFalse(ContentClock.needsCorrection(driftMs = 90, toleranceMs = 150,
            durationMs = 60_000, loop = false))
    }

    @Test fun `sustained drift beyond tolerance needs correction`() {
        assertTrue(ContentClock.needsCorrection(driftMs = 400, toleranceMs = 150,
            durationMs = 60_000, loop = false))
    }

    @Test fun `loop wrap does not create false huge drift`() {
        // actual just wrapped (offset ~50ms), expected ~59_950ms: raw diff is
        // -59_900 but on the 60s circle that's only 100ms of real drift.
        assertFalse(ContentClock.needsCorrection(driftMs = -59_900, toleranceMs = 150,
            durationMs = 60_000, loop = true))
    }
}
