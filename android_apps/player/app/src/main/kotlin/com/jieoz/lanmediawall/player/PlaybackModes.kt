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
