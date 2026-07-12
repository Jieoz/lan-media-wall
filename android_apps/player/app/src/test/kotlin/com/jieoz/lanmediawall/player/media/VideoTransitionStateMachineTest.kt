package com.jieoz.lanmediawall.player.media

import org.junit.Assert.assertEquals
import org.junit.Test

class VideoTransitionStateMachineTest {
    @Test fun `cached old frame remains until new first frame`() {
        val sm = VideoTransitionStateMachine()
        assertEquals(VideoTransitionStateMachine.Action.SHOW_CACHED_FRAME, sm.begin(hasCachedFrame = true))
        assertEquals(VideoTransitionStateMachine.Action.HIDE_OVERLAY, sm.firstFrameRendered())
    }

    @Test fun `load failure always removes overlay`() {
        val sm = VideoTransitionStateMachine()
        sm.begin(hasCachedFrame = true)
        assertEquals(VideoTransitionStateMachine.Action.HIDE_OVERLAY, sm.failed())
    }

    @Test fun `transition without cached frame never invents an overlay`() {
        val sm = VideoTransitionStateMachine()
        assertEquals(VideoTransitionStateMachine.Action.NONE, sm.begin(hasCachedFrame = false))
        assertEquals(VideoTransitionStateMachine.Action.NONE, sm.firstFrameRendered())
    }
}
