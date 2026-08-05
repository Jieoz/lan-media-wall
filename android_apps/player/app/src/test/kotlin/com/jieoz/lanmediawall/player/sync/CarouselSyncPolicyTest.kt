package com.jieoz.lanmediawall.player.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Multi-item ALL carousels used to advance on local EOF, so eleven boxes
 * drifted apart within one lap. The shared timeline is pure master-clock math:
 * next item starts at play_at + duration of the current item.
 */
class CarouselSyncPolicyTest {
    @Test
    fun `next play_at is current play_at plus duration`() {
        assertEquals(
            12_000L,
            CarouselSyncPolicy.nextPlayAtMasterMs(
                currentPlayAtMasterMs = 10_000L,
                currentDurationMs = 2_000L,
            ),
        )
    }

    @Test
    fun `unknown duration falls back to master now plus small buffer`() {
        assertEquals(
            10_200L,
            CarouselSyncPolicy.nextPlayAtMasterMs(
                currentPlayAtMasterMs = 10_000L,
                currentDurationMs = 0L,
                masterNowMs = 10_150L,
                unknownDurationBufferMs = 50L,
            ),
        )
    }

    @Test
    fun `ALL wraps at end`() {
        assertEquals(
            0,
            CarouselSyncPolicy.nextIndex(
                currentIndex = 3,
                itemCount = 4,
                loopModeAll = true,
                explicit = false,
            ),
        )
    }

    @Test
    fun `NONE clamps at end`() {
        assertNull(
            CarouselSyncPolicy.nextIndex(
                currentIndex = 3,
                itemCount = 4,
                loopModeAll = false,
                explicit = false,
            ),
        )
    }

    @Test
    fun `sync carousel only when multi-item ALL and playlist sync`() {
        assertEquals(
            true,
            CarouselSyncPolicy.shouldOwnAutoAdvance(
                itemCount = 4,
                loopModeAll = true,
                playlistSync = true,
                singleItemOemLoop = false,
            ),
        )
        assertEquals(
            false,
            CarouselSyncPolicy.shouldOwnAutoAdvance(
                itemCount = 1,
                loopModeAll = true,
                playlistSync = true,
                singleItemOemLoop = true,
            ),
        )
        assertEquals(
            false,
            CarouselSyncPolicy.shouldOwnAutoAdvance(
                itemCount = 4,
                loopModeAll = true,
                playlistSync = false,
                singleItemOemLoop = false,
            ),
        )
    }
}
