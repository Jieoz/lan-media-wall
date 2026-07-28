package com.jieoz.lanmediawall.player

import java.util.Collections
import java.util.Random

enum class PlaybackMode(val wire: String) {
    VISUAL("visual"),
    MUSIC("music"),
    STANDBY("standby");

    companion object {
        fun parse(raw: String?): PlaybackMode? = values().firstOrNull { it.wire == raw }
    }
}

/** Pure runtime-mode state. STANDBY never replaces the last active mode. */
class PlaybackModeState(
    current: PlaybackMode = PlaybackMode.VISUAL,
    previousActive: PlaybackMode = PlaybackMode.VISUAL,
) {
    var current: PlaybackMode = current
        private set
    var previousActive: PlaybackMode = previousActive
        private set

    fun setMode(mode: PlaybackMode): PlaybackMode {
        current = mode
        if (mode != PlaybackMode.STANDBY) previousActive = mode
        return current
    }

    fun restore(): PlaybackMode {
        val target = previousActive.takeIf { it != PlaybackMode.STANDBY }
            ?: PlaybackMode.VISUAL
        return setMode(target)
    }
}

/**
 * Local shuffle-bag: each distinct item is emitted once per lap. A new lap is
 * reshuffled and cannot start with the item that ended the previous lap when
 * at least two choices exist.
 */
class ShuffleBag<T>(private val random: Random = Random()) {
    private var universe: List<T> = emptyList()
    private val remaining = ArrayList<T>()
    private var last: T? = null
    var cycle: Long = 0L
        private set

    fun next(items: List<T>): T? {
        val distinct = items.distinct()
        if (distinct.isEmpty()) {
            universe = emptyList()
            remaining.clear()
            return null
        }
        if (universe != distinct) {
            universe = distinct
            remaining.clear()
        }
        if (remaining.isEmpty()) refill()
        val value = remaining.removeAt(0)
        last = value
        return value
    }

    fun reset() {
        universe = emptyList()
        remaining.clear()
        last = null
        cycle = 0L
    }

    /** Keep the bag's lap bookkeeping honest when the queue advanced by other
     *  means (sequential order, or a `prev` that walked back into history):
     *  the item must not come round again inside the current lap. */
    fun consume(value: T) {
        remaining.remove(value)
        last = value
    }

    private fun refill() {
        cycle += 1L
        remaining.addAll(universe)
        Collections.shuffle(remaining, random)
        if (remaining.size > 1 && remaining.first() == last) {
            val swap = remaining.indexOfFirst { it != last }
            if (swap > 0) Collections.swap(remaining, 0, swap)
        }
    }
}

/**
 * §6.3c music ordering: the single authority for "which track plays next".
 *
 * Two orderings behind one interface, because a controller toggling shuffle
 * must not fork the playback path:
 *  - shuffle on  → [ShuffleBag] laps (every track once per lap, no lap-boundary repeat)
 *  - shuffle off → the controller's list order, wrapping at the end
 *
 * `prev` is a real back-button: it walks the bounded play HISTORY, so the user
 * hears the track they just heard. Falling back to "another random track" would
 * read as a broken button. History depth is bounded ([MAX_HISTORY]) so a box
 * left playing for weeks cannot grow it without limit; at the bottom of the
 * history `prev` holds the current track rather than inventing one.
 */
class MusicQueue(random: Random = Random()) {
    private val shuffleBag = ShuffleBag<String>(random)
    private val history = ArrayList<String>()
    var shuffle: Boolean = true
        private set
    var current: String? = null
        private set

    val cycle: Long get() = shuffleBag.cycle
    val historyDepth: Int get() = history.size

    /** @return true when the ordering actually changed (caller may log it). */
    fun setShuffle(enabled: Boolean): Boolean {
        if (shuffle == enabled) return false
        shuffle = enabled
        // Laps belong to the shuffled ordering only; a stale bag would make the
        // first lap after re-enabling shuffle skip tracks.
        shuffleBag.reset()
        return true
    }

    /** Drop queue position/laps/history. The shuffle SETTING is configuration,
     *  not queue position, so it deliberately survives a reset. */
    fun reset() {
        shuffleBag.reset()
        history.clear()
        current = null
    }

    /** Advance forward one track over [candidates] (already filtered to playable). */
    fun next(candidates: List<String>): String? {
        if (candidates.isEmpty()) {
            current = null
            return null
        }
        current?.let { pushHistory(it) }
        val picked = if (shuffle) shuffleBag.next(candidates) else sequential(+1, candidates)
        if (picked != null && !shuffle) shuffleBag.consume(picked)
        current = picked
        return picked
    }

    /**
     * Step back to the previously played track. With history it replays that
     * track; with an empty history it holds the current one (sequential mode
     * still walks the list backwards, which is what a list order implies).
     */
    fun prev(candidates: List<String>): String? {
        if (candidates.isEmpty()) {
            current = null
            return null
        }
        val fromHistory = popHistory(candidates)
        val picked = when {
            fromHistory != null -> fromHistory
            // Sequential order has a well-defined "one before this"; shuffle does
            // not, so with no history it holds the current track.
            !shuffle -> sequential(-1, candidates)
            else -> current?.takeIf { it in candidates } ?: candidates.first()
        }
        shuffleBag.consume(picked)
        current = picked
        return picked
    }

    /** Re-seat the queue on a known current track (restart / snapshot restore). */
    fun adopt(itemId: String?) {
        current = itemId
        itemId?.let { shuffleBag.consume(it) }
    }

    /**
     * §6.3c the track `next` would return, WITHOUT advancing — used to warm the
     * media cache so a track change isn't audible silence while bytes land.
     *
     * Returns null in shuffle mode on purpose: the pick comes out of the shuffle
     * bag and cannot be predicted without consuming it. Faking a guess here would
     * warm the wrong file, so the caller warms the (small) candidate set instead.
     */
    fun peekNext(candidates: List<String>): String? {
        if (candidates.isEmpty() || shuffle) return null
        return sequential(+1, candidates)
    }

    private fun sequential(delta: Int, candidates: List<String>): String {
        val at = candidates.indexOf(current)
        if (at < 0) return if (delta >= 0) candidates.first() else candidates.last()
        val size = candidates.size
        return candidates[((at + delta) % size + size) % size]
    }

    private fun pushHistory(itemId: String) {
        history.add(itemId)
        while (history.size > MAX_HISTORY) history.removeAt(0)
    }

    /** Discard history entries that the current list no longer contains. */
    private fun popHistory(candidates: List<String>): String? {
        while (history.isNotEmpty()) {
            val candidate = history.removeAt(history.size - 1)
            if (candidate in candidates) return candidate
        }
        return null
    }

    companion object {
        const val MAX_HISTORY = 32
    }
}
