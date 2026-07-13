package com.jieoz.lanmediawall.player.media

import org.junit.Assert.assertEquals
import org.junit.Test

class LoopBoundaryStateMachineTest {
    @Test fun nearEosShowsOnlyOnce() {
        val sm = LoopBoundaryStateMachine()
        assertEquals(LoopBoundaryStateMachine.Action.SHOW_OVERLAY, sm.sample(9_700, 10_000, true, true))
        assertEquals(LoopBoundaryStateMachine.Action.NONE, sm.sample(9_850, 10_000, true, true))
    }

    @Test fun normalProgressDoesNotTrigger() {
        val sm = LoopBoundaryStateMachine()
        assertEquals(LoopBoundaryStateMachine.Action.NONE, sm.sample(1_000, 10_000, true, true))
        assertEquals(LoopBoundaryStateMachine.Action.NONE, sm.sample(2_000, 10_000, true, true))
    }

    @Test fun wrapThenSustainedProgressHides() {
        val sm = LoopBoundaryStateMachine()
        sm.sample(9_800, 10_000, true, true)
        assertEquals(LoopBoundaryStateMachine.Action.NONE, sm.sample(80, 10_000, true, true))
        assertEquals(LoopBoundaryStateMachine.Action.HIDE_OVERLAY, sm.sample(450, 10_000, true, true))
    }

    @Test fun seekAndPauseDoNotLookLikeLoop() {
        val sm = LoopBoundaryStateMachine()
        sm.sample(9_800, 10_000, true, true)
        assertEquals(LoopBoundaryStateMachine.Action.HIDE_OVERLAY, sm.onSeek())
        assertEquals(LoopBoundaryStateMachine.Action.NONE, sm.sample(100, 10_000, true, true))
        assertEquals(LoopBoundaryStateMachine.Action.NONE, sm.sample(9_800, 10_000, false, true))
    }

    @Test fun unknownDurationAndJitterAreSafe() {
        val sm = LoopBoundaryStateMachine()
        assertEquals(LoopBoundaryStateMachine.Action.NONE, sm.sample(500, 0, true, true))
        sm.sample(9_800, 10_000, true, true)
        assertEquals(LoopBoundaryStateMachine.Action.NONE, sm.sample(9_760, 10_000, true, true))
    }

    @Test fun rearmsForAnotherLoop() {
        val sm = LoopBoundaryStateMachine()
        sm.sample(9_800, 10_000, true, true); sm.sample(50, 10_000, true, true); sm.sample(500, 10_000, true, true)
        assertEquals(LoopBoundaryStateMachine.Action.SHOW_OVERLAY, sm.sample(9_800, 10_000, true, true))
    }

    @Test fun resetClearsVisibleOverlay() {
        val sm = LoopBoundaryStateMachine()
        sm.sample(9_800, 10_000, true, true)
        assertEquals(LoopBoundaryStateMachine.Action.HIDE_OVERLAY, sm.reset())
        assertEquals(LoopBoundaryStateMachine.Action.NONE, sm.reset())
    }
}
