package com.jieoz.lanmediawall.player.sync

/**
 * Pure multi-item carousel timeline on the broker master clock.
 *
 * Single-item OEM loops keep [LoopBoundarySync]. Multi-item ALL used to step on
 * local EOF (`advance`), so any early/late box drifted permanently. Here every
 * box computes the same next play_at from the shared epoch + duration, then
 * waits on the master clock before loading the next item.
 */
object CarouselSyncPolicy {
    fun shouldOwnAutoAdvance(
        itemCount: Int,
        loopModeAll: Boolean,
        playlistSync: Boolean,
        singleItemOemLoop: Boolean,
    ): Boolean {
        if (!playlistSync) return false
        if (singleItemOemLoop) return false
        if (!loopModeAll) return false
        return itemCount > 1
    }

    fun nextPlayAtMasterMs(
        currentPlayAtMasterMs: Long,
        currentDurationMs: Long,
        masterNowMs: Long = currentPlayAtMasterMs,
        unknownDurationBufferMs: Long = 200L,
    ): Long {
        if (currentDurationMs > 0L) return currentPlayAtMasterMs + currentDurationMs
        // Duration unknown: do not invent a long stall; step shortly after now.
        return masterNowMs + unknownDurationBufferMs.coerceAtLeast(0L)
    }

    /**
     * @return next index, or null when the carousel should stop (NONE at end).
     */
    fun nextIndex(
        currentIndex: Int,
        itemCount: Int,
        loopModeAll: Boolean,
        explicit: Boolean,
    ): Int? {
        if (itemCount <= 0) return null
        var next = currentIndex + 1
        if (next < itemCount) return next
        if (loopModeAll || explicit) return 0
        return null
    }
}
