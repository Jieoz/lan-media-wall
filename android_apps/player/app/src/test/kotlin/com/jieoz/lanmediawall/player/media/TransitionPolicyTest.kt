package com.jieoz.lanmediawall.player.media

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * §6.3/§loop black-frame policy contract. Pins the two decisions: single-item
 * loops use OEM continuous looping (no seam), and the single-VDEC API19 target
 * swaps immediately (honest brief black gap) rather than holding the last frame
 * with a second decoder that could regress the verified-smooth playback.
 */
class TransitionPolicyTest {

    // --- loop strategy ----------------------------------------------------

    @Test fun `single-item looping playlist uses OEM continuous looping`() {
        assertEquals(
            TransitionPolicy.LoopStrategy.OEM_CONTINUOUS,
            TransitionPolicy.loopStrategy(itemCount = 1, loop = true),
        )
    }

    @Test fun `multi-item loop advances on end not REPEAT_ONE`() {
        // REPEAT_ONE on a multi-item playlist would freeze on item 0.
        assertEquals(
            TransitionPolicy.LoopStrategy.ADVANCE_ON_END,
            TransitionPolicy.loopStrategy(itemCount = 3, loop = true),
        )
    }

    @Test fun `single item without loop still advances on end`() {
        assertEquals(
            TransitionPolicy.LoopStrategy.ADVANCE_ON_END,
            TransitionPolicy.loopStrategy(itemCount = 1, loop = false),
        )
    }

    // --- transition strategy ---------------------------------------------

    @Test fun `api19 single-VDEC target swaps immediately`() {
        // The confirmed QZX_C1 box: one decoder, API 19 → must not hold a 2nd.
        assertEquals(
            TransitionPolicy.TransitionStrategy.IMMEDIATE_SWAP,
            TransitionPolicy.transitionStrategy(androidSdk = 19, concurrentDecoders = 1),
        )
    }

    @Test fun `multi-VDEC modern box may hold last frame`() {
        assertEquals(
            TransitionPolicy.TransitionStrategy.HOLD_LAST_FRAME,
            TransitionPolicy.transitionStrategy(androidSdk = 24, concurrentDecoders = 2),
        )
    }

    @Test fun `modern but single-decoder box still swaps immediately`() {
        // The decoder count is the hard constraint, not just the API level.
        assertEquals(
            TransitionPolicy.TransitionStrategy.IMMEDIATE_SWAP,
            TransitionPolicy.transitionStrategy(androidSdk = 24, concurrentDecoders = 1),
        )
    }

    @Test fun `two decoders but old API still swaps immediately`() {
        assertEquals(
            TransitionPolicy.TransitionStrategy.IMMEDIATE_SWAP,
            TransitionPolicy.transitionStrategy(androidSdk = 19, concurrentDecoders = 2),
        )
    }
}
