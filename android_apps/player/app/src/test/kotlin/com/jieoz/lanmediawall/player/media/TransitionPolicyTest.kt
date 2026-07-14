package com.jieoz.lanmediawall.player.media

import com.jieoz.lanmediawall.player.cache.LoopMode
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * §6.3/§loop black-frame policy contract. Pins the three-mode decisions:
 * ONE (and a degenerate single-item ALL) use OEM continuous looping (no seam);
 * multi-item ALL / NONE advance on end; and the single-VDEC API19 target swaps
 * immediately (honest brief black gap) rather than holding the last frame with
 * a second decoder that could regress the verified-smooth playback.
 */
class TransitionPolicyTest {

    // --- loop strategy (§6.3 three-mode) ---------------------------------

    @Test fun `ONE repeats current item via OEM continuous regardless of count`() {
        assertEquals(
            TransitionPolicy.LoopStrategy.OEM_CONTINUOUS,
            TransitionPolicy.loopStrategy(itemCount = 1, loopMode = LoopMode.ONE),
        )
        assertEquals(
            TransitionPolicy.LoopStrategy.OEM_CONTINUOUS,
            TransitionPolicy.loopStrategy(itemCount = 5, loopMode = LoopMode.ONE),
        )
    }

    @Test fun `single-item ALL still loops seamlessly via OEM continuous`() {
        // Preserves today's "loop a single MP4" seam-free behaviour.
        assertEquals(
            TransitionPolicy.LoopStrategy.OEM_CONTINUOUS,
            TransitionPolicy.loopStrategy(itemCount = 1, loopMode = LoopMode.ALL),
        )
    }

    @Test fun `multi-item ALL advances on end not REPEAT_ONE`() {
        // REPEAT_ONE on a multi-item playlist would freeze on the current item.
        assertEquals(
            TransitionPolicy.LoopStrategy.ADVANCE_ON_END,
            TransitionPolicy.loopStrategy(itemCount = 3, loopMode = LoopMode.ALL),
        )
    }

    @Test fun `NONE advances on end so playback can stop at completion`() {
        assertEquals(
            TransitionPolicy.LoopStrategy.ADVANCE_ON_END,
            TransitionPolicy.loopStrategy(itemCount = 1, loopMode = LoopMode.NONE),
        )
        assertEquals(
            TransitionPolicy.LoopStrategy.ADVANCE_ON_END,
            TransitionPolicy.loopStrategy(itemCount = 3, loopMode = LoopMode.NONE),
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
