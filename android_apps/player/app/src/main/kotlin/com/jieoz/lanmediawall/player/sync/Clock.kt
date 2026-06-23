package com.jieoz.lanmediawall.player.sync

import java.util.ArrayDeque

/**
 * Clock synchronization — protocol_spec §8, mirroring windows_player/clock.py.
 *
 * SNTP-style handshake over the existing WS connection. The player sends
 * time_sync{t1}; broker replies time_sync_ack{t1,t2,t3}; the player records t4.
 *
 *     offset = ((t2 - t1) + (t3 - t4)) / 2
 *     rtt    = (t4 - t1) - (t3 - t2)
 *
 * We keep a sliding window of recent samples and trust the offset of the
 * **smallest-rtt** sample (least network jitter). That offset feeds
 * status.clock_offset_ms.
 *
 * Start-of-play folding (§8.2): a sync command carries play_at in the broker's
 * master clock. The local target instant is:
 *
 *     local_target_ms = play_at - offset
 *
 * (offset = local - master, so subtracting folds a master instant to local.)
 *
 * Pure logic, no I/O — fully unit-tested. Thread-safety: callers synchronize on
 * the instance (the WS loop adds samples; the status loop / play scheduler read
 * offset). Methods are individually synchronized to keep the window consistent.
 */
class ClockSync(private val window: Int = 8) {

    data class Sample(val t1: Long, val t2: Long, val t3: Long, val t4: Long) {
        val offset: Double get() = ((t2 - t1) + (t3 - t4)) / 2.0
        val rtt: Long get() = (t4 - t1) - (t3 - t2)
    }

    private val samples = ArrayDeque<Sample>()
    private var best: Sample? = null

    /** Record a completed round trip. Returns the sample (even if rejected). */
    @Synchronized
    fun addSample(t1: Long, t2: Long, t3: Long, t4: Long): Sample {
        val s = Sample(t1, t2, t3, t4)
        // Guard against absurd samples (negative rtt from clock weirdness) so
        // they can't poison the min-rtt pick.
        if (s.rtt >= 0) {
            if (samples.size >= window) samples.removeFirst()
            samples.addLast(s)
            recomputeBest()
        }
        return s
    }

    private fun recomputeBest() {
        best = samples.minByOrNull { it.rtt }
    }

    @get:Synchronized
    val synced: Boolean get() = best != null

    /** Best (min-rtt) offset, rounded to ms. 0 until the first sample lands. */
    @get:Synchronized
    val offsetMs: Long
        get() = best?.let { Math.round(it.offset) } ?: 0L

    @get:Synchronized
    val bestRttMs: Long? get() = best?.rtt

    /** Fold a broker-master-clock instant to this player's local clock (§8.2). */
    @Synchronized
    fun toLocal(masterMs: Long): Long = masterMs - offsetMs

    /** Estimate current broker master-clock time from local now. */
    @Synchronized
    fun masterNow(): Long = System.currentTimeMillis() + offsetMs

    /** Drop all samples — called on reconnect (§1 requires re-handshake). */
    @Synchronized
    fun reset() {
        samples.clear()
        best = null
    }
}
