package com.jieoz.lanmediawall.player.media

/** Pure lifecycle for the still-frame overlay used while one decoder is rebuilt. */
class VideoTransitionStateMachine {
    enum class Action { NONE, SHOW_CACHED_FRAME, HIDE_OVERLAY }
    private var overlayVisible = false

    fun begin(hasCachedFrame: Boolean): Action {
        overlayVisible = hasCachedFrame
        return if (overlayVisible) Action.SHOW_CACHED_FRAME else Action.NONE
    }

    fun firstFrameRendered(): Action = finish()
    fun failed(): Action = finish()

    private fun finish(): Action {
        if (!overlayVisible) return Action.NONE
        overlayVisible = false
        return Action.HIDE_OVERLAY
    }
}
