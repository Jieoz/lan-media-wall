package com.jieoz.lanmediawall.player.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure policy for the playlist→prepare race: controller often fires both in
 * the same tick, so prepare can land before the player has adopted push_id.
 * Dropping that prepare silently is the mid-group-push failure mode.
 */
class PendingPreparePolicyTest {
    @Test
    fun `matching push_id is adoptable immediately`() {
        val decision = PendingPreparePolicy.decide(
            playlistId = "pl-1",
            pushId = "push-1",
            resolvedPushId = "push-1",
            playlistFound = true,
        )
        assertEquals(PendingPreparePolicy.Decision.ADOPT_NOW, decision)
    }

    @Test
    fun `missing playlist parks prepare`() {
        val decision = PendingPreparePolicy.decide(
            playlistId = "pl-1",
            pushId = "push-1",
            resolvedPushId = null,
            playlistFound = false,
        )
        assertEquals(PendingPreparePolicy.Decision.PARK, decision)
    }

    @Test
    fun `playlist present but push_id not yet adopted parks prepare`() {
        val decision = PendingPreparePolicy.decide(
            playlistId = "pl-1",
            pushId = "push-new",
            resolvedPushId = "push-old",
            playlistFound = true,
        )
        assertEquals(PendingPreparePolicy.Decision.PARK, decision)
    }

    @Test
    fun `empty push_id is rejected not parked`() {
        val decision = PendingPreparePolicy.decide(
            playlistId = "pl-1",
            pushId = "",
            resolvedPushId = "push-1",
            playlistFound = true,
        )
        assertEquals(PendingPreparePolicy.Decision.REJECT, decision)
    }

    @Test
    fun `parked prepare adopts when later playlist carries matching push_id`() {
        val parked = PendingPreparePolicy.Parked(
            playlistId = "pl-1",
            pushId = "push-1",
            prepareId = "prep-9",
            groupId = "888",
            startIndex = 0,
            seekMs = 0,
            prefetchBarrier = true,
            barrierTimeoutMs = 120_000L,
            rawPayloadToken = 1,
        )
        assertTrue(PendingPreparePolicy.matches(parked, playlistId = "pl-1", pushId = "push-1"))
        assertFalse(PendingPreparePolicy.matches(parked, playlistId = "pl-1", pushId = "other"))
        assertFalse(PendingPreparePolicy.matches(parked, playlistId = "pl-2", pushId = "push-1"))
    }

    @Test
    fun `newer park replaces older for same playlist identity`() {
        val older = PendingPreparePolicy.Parked(
            playlistId = "pl-1", pushId = "push-1", prepareId = "prep-1",
            groupId = "g", startIndex = 0, seekMs = 0,
            prefetchBarrier = false, barrierTimeoutMs = 0L, rawPayloadToken = 1,
        )
        val newer = PendingPreparePolicy.Parked(
            playlistId = "pl-1", pushId = "push-2", prepareId = "prep-2",
            groupId = "g", startIndex = 1, seekMs = 0,
            prefetchBarrier = true, barrierTimeoutMs = 120_000L, rawPayloadToken = 2,
        )
        val kept = PendingPreparePolicy.replace(older, newer)
        assertEquals("prep-2", kept.prepareId)
        assertEquals("push-2", kept.pushId)
    }

    @Test
    fun `clear drops parked entry`() {
        assertNull(
            PendingPreparePolicy.clearIf(
                PendingPreparePolicy.Parked(
                    playlistId = "pl-1", pushId = "p", prepareId = "x",
                    groupId = "g", startIndex = 0, seekMs = 0,
                    prefetchBarrier = false, barrierTimeoutMs = 0L, rawPayloadToken = 0,
                ),
                reasonPlaylistReplace = true,
            ),
        )
    }
}
