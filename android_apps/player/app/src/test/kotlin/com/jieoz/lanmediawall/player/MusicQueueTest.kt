package com.jieoz.lanmediawall.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

/**
 * §6.3c music transport contract.
 *
 * These deliberately mirror `windows_player/tests/test_music_transport.py`
 * case-for-case: the two players share one wire contract, so "prev" and the
 * shuffle setting must mean exactly the same thing on both. If you change a
 * case here, change it there.
 */
class MusicQueueTest {

    @Test fun `sequential mode follows the controller list order and wraps`() {
        val q = MusicQueue()
        q.setShuffle(false)
        val ids = listOf("a", "b", "c")
        assertEquals(listOf("a", "b", "c", "a"), List(4) { q.next(ids) })
    }

    @Test fun `sequential prev walks back through the list`() {
        val q = MusicQueue()
        q.setShuffle(false)
        val ids = listOf("a", "b", "c")
        q.next(ids); q.next(ids); q.next(ids)   // a, b, c
        assertEquals("b", q.prev(ids))
        assertEquals("a", q.prev(ids))
    }

    @Test fun `prev replays actual history not another random track`() {
        val q = MusicQueue(Random(7))
        val ids = listOf("a", "b", "c", "d", "e")
        val heard = List(4) { q.next(ids)!! }
        assertEquals(heard[2], q.prev(ids))
        assertEquals(heard[1], q.prev(ids))
        assertEquals(heard[0], q.prev(ids))
    }

    @Test fun `shuffle lap plays every track once before repeating`() {
        val q = MusicQueue(Random(3))
        val ids = listOf("a", "b", "c", "d")
        val lap = List(4) { q.next(ids)!! }
        assertEquals(ids.toSet(), lap.toSet())
        assertEquals(4, lap.distinct().size)
    }

    @Test fun `history is bounded so long running boxes do not grow forever`() {
        val q = MusicQueue(Random(11))
        val ids = (0 until 50).map { "t$it" }
        repeat(500) { q.next(ids) }
        assertTrue(q.historyDepth <= MusicQueue.MAX_HISTORY)
    }

    @Test fun `prev at the bottom of history holds instead of jumping`() {
        val q = MusicQueue(Random(5))
        val ids = listOf("a", "b", "c")
        val first = q.next(ids)!!
        assertEquals(first, q.prev(ids))
        assertEquals(first, q.current)
    }

    @Test fun `prev skips history entries no longer in the list`() {
        val q = MusicQueue()
        q.setShuffle(false)
        val full = listOf("a", "b", "c")
        q.next(full); q.next(full); q.next(full)   // a, b, c
        // "b" was removed from the list by the controller.
        assertEquals("a", q.prev(listOf("a", "c")))
    }

    @Test fun `toggling shuffle keeps the setting across a queue reset`() {
        val q = MusicQueue()
        q.setShuffle(false)
        q.next(listOf("a", "b"))
        q.reset()
        assertFalse(q.shuffle)
        assertNull(q.current)
    }

    @Test fun `set shuffle reports only real changes`() {
        val q = MusicQueue()
        assertFalse(q.setShuffle(true))    // already shuffling
        assertTrue(q.setShuffle(false))
        assertFalse(q.setShuffle(false))
    }

    @Test fun `empty playlist clears the pointer instead of throwing`() {
        val q = MusicQueue()
        assertNull(q.next(emptyList()))
        assertNull(q.prev(emptyList()))
        assertNull(q.current)
    }

    @Test fun `single item playlist is continuous in both directions`() {
        val q = MusicQueue(Random(2))
        val one = listOf("only")
        assertTrue(List(4) { q.next(one) }.all { it == "only" })
        assertEquals("only", q.prev(one))
    }

    @Test fun `peek next names the upcoming track in list order for prefetch`() {
        val q = MusicQueue()
        q.setShuffle(false)
        val ids = listOf("a", "b", "c")
        q.next(ids)                        // a
        assertEquals("b", q.peekNext(ids))
        // Peeking must not advance: the same peek still answers "b".
        assertEquals("b", q.peekNext(ids))
        assertEquals("a", q.current)
    }

    @Test fun `peek next declines to guess in shuffle mode`() {
        val q = MusicQueue(Random(4))
        val ids = listOf("a", "b", "c")
        q.next(ids)
        // A guess would warm the wrong file; the caller warms the whole set.
        assertNull(q.peekNext(ids))
    }

    @Test fun `adopt reseats the queue after a restart without replaying it`() {
        val q = MusicQueue(Random(9))
        val ids = listOf("a", "b", "c")
        q.adopt("b")
        assertEquals("b", q.current)
        // The adopted track is consumed from the current lap, so the next pick
        // moves on rather than repeating what is already playing.
        assertTrue(q.next(ids) != "b")
    }
}
