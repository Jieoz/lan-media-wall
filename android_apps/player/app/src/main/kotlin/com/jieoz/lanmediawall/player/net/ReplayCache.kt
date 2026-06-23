package com.jieoz.lanmediawall.player.net

/**
 * LRU + TTL cache of seen `msg_id`s for §3 replay dedup. Mirrors the Python
 * `ReplayCache`: an msg_id is remembered for [ttlMs] (default 5 min); a repeat
 * within that window is a duplicate and the message is dropped.
 *
 * Single-threaded by contract — called only from the WS receive loop. The
 * insertion-ordered map gives us cheap oldest-first eviction.
 */
class ReplayCache(
    private val ttlMs: Long = Envelope.DEDUP_TTL_MS,
    private val maxEntries: Int = 50_000,
) {
    // msg_id -> expiry epoch ms. LinkedHashMap preserves insertion order.
    private val seen = LinkedHashMap<String, Long>()

    private fun evict(now: Long) {
        val it = seen.entries.iterator()
        while (it.hasNext()) {
            val (_, exp) = it.next()
            if (exp <= now) it.remove() else break
        }
        while (seen.size > maxEntries) {
            val first = seen.keys.iterator()
            if (!first.hasNext()) break
            seen.remove(first.next())
        }
    }

    /**
     * Returns true if [msgId] was already seen (and unexpired). Records it as
     * seen (side effect) when new — matching the Python semantics.
     */
    fun seen(msgId: String, now: Long = Envelope.nowMs()): Boolean {
        evict(now)
        val exp = seen[msgId]
        if (exp != null && exp > now) return true
        // re-insert at tail (most-recently-seen)
        seen.remove(msgId)
        seen[msgId] = now + ttlMs
        return false
    }

    fun clear() = seen.clear()
}
