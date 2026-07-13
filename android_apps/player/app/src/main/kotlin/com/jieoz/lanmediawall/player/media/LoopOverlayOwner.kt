package com.jieoz.lanmediawall.player.media

/** Pure identity gate preventing delayed callbacks from an old load touching current UI. */
class LoopOverlayOwner {
    data class Token(val generation: Long, val itemId: String)
    private var generation = 0L
    private var current: Token? = null

    fun arm(itemId: String?): Token? {
        generation++
        current = itemId?.let { Token(generation, it) }
        return current
    }
    fun disarm() { generation++; current = null }
    fun accepts(token: Token): Boolean = token == current
}