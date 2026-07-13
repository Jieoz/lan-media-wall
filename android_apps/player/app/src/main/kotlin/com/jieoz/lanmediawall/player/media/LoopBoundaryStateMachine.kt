package com.jieoz.lanmediawall.player.media

/** Pure API19 single-decoder loop-boundary overlay policy. */
class LoopBoundaryStateMachine(
    private val nearEndMs: Long = 350,
    private val wrapHeadMs: Long = 500,
    private val progressMs: Long = 250,
) {
    enum class Action { NONE, SHOW_OVERLAY, HIDE_OVERLAY }
    private var visible = false
    private var armed = true
    private var lastPosition = -1L
    private var wrappedAt = -1L

    fun sample(positionMs: Long, durationMs: Long, playing: Boolean, hasCachedFrame: Boolean): Action {
        if (!playing || durationMs <= 0 || positionMs < 0) {
            lastPosition = positionMs
            return Action.NONE
        }
        val nearEnd = positionMs <= durationMs && durationMs - positionMs <= nearEndMs
        if (nearEnd && armed && hasCachedFrame) {
            visible = true
            armed = false
            lastPosition = positionMs
            return Action.SHOW_OVERLAY
        }
        if (visible && lastPosition >= durationMs - nearEndMs && positionMs <= wrapHeadMs) {
            wrappedAt = positionMs
        }
        if (visible && wrappedAt >= 0 && positionMs >= wrappedAt + progressMs) {
            visible = false
            armed = true
            wrappedAt = -1
            lastPosition = positionMs
            return Action.HIDE_OVERLAY
        }
        lastPosition = positionMs
        return Action.NONE
    }

    fun onSeek(): Action = reset()

    fun reset(): Action {
        val action = if (visible) Action.HIDE_OVERLAY else Action.NONE
        visible = false
        armed = true
        wrappedAt = -1
        lastPosition = -1
        return action
    }
}
