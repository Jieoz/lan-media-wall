package com.jieoz.lanmediawall.player.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Clock offset / play_at folding tests (protocol_spec §8), mirroring the
 * windows_player clock tests. The NTP formulas:
 *
 *     offset = ((t2 - t1) + (t3 - t4)) / 2
 *     rtt    = (t4 - t1) - (t3 - t2)
 *
 * and the min-rtt selection are the sync linchpin — a wrong offset means the
 * wall plays out of sync.
 */
class ClockTest {

    @Test
    fun offset_basic_symmetric() {
        // Broker is +1000ms ahead of player; symmetric 20ms each way.
        // player send t1=0; broker recv t2=1020 (master); broker send t3=1020;
        // player recv t4=40.  offset=((1020-0)+(1020-40))/2 = 1000. rtt=40.
        val c = ClockSync()
        c.addSample(0, 1020, 1020, 40)
        assertTrue(c.synced)
        assertEquals(1000L, c.offsetMs)
        assertEquals(40L, c.bestRttMs)
    }

    @Test
    fun picks_minimum_rtt_sample() {
        val c = ClockSync()
        // sample A: rtt 200, offset 1000
        c.addSample(0, 1100, 1100, 200)
        // sample B: rtt 20, offset 500  (much less jitter → trusted)
        c.addSample(1000, 1510, 1510, 1020)
        assertEquals(20L, c.bestRttMs)
        assertEquals(500L, c.offsetMs)
    }

    @Test
    fun rejects_negative_rtt_samples() {
        val c = ClockSync()
        // contrived negative rtt: (t4-t1) - (t3-t2) < 0
        c.addSample(1000, 0, 5000, 1010) // rtt = 10 - 5000 = -4990
        assertFalse(c.synced)
        assertEquals(0L, c.offsetMs)
    }

    @Test
    fun to_local_folds_master_to_local() {
        val c = ClockSync()
        c.addSample(0, 1020, 1020, 40) // offset 1000
        // local_target = play_at - offset
        assertEquals(4000L, c.toLocal(5000))
    }

    @Test
    fun reset_clears_samples() {
        val c = ClockSync()
        c.addSample(0, 1020, 1020, 40)
        assertTrue(c.synced)
        c.reset()
        assertFalse(c.synced)
        assertEquals(0L, c.offsetMs)
    }

    @Test
    fun window_evicts_oldest() {
        val c = ClockSync(window = 2)
        c.addSample(0, 1100, 1100, 200)  // rtt 200, offset 1000
        c.addSample(0, 1050, 1050, 100)  // rtt 100, offset 1000
        // third sample evicts the first; min rtt now among last two
        c.addSample(0, 1030, 1030, 60)   // rtt 60, offset 1000
        assertEquals(60L, c.bestRttMs)
    }
}
