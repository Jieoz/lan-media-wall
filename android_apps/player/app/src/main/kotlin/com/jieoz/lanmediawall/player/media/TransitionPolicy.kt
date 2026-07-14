package com.jieoz.lanmediawall.player.media

import com.jieoz.lanmediawall.player.cache.LoopMode

/**
 * §6.3/§loop black-frame policy — PURE, unit-tested, no Android / no I/O.
 *
 * Two DIFFERENT "black frame" problems, two different answers:
 *
 *  1. SINGLE-ITEM LOOP (one MP4, loop=true). The old code drove the loop by
 *     letting the clip complete and re-preparing — a full decoder teardown +
 *     fresh prepare per lap, which flashes black at the seam. The fix is OEM
 *     continuous looping: `MediaPlayer.setLooping(true)` restarts INSIDE the
 *     decoder with no teardown and no onCompletion, so there is no seam at all.
 *     [loopStrategy] pins that: a single-item loop is [LoopStrategy.OEM_CONTINUOUS].
 *
 *  2. PLAYLIST TRANSITION (item A → item B). Here we must release A's decoder
 *     and prepare B's. Ideally we'd HOLD A's last frame on the surface until B's
 *     first frame renders. But on the confirmed target (QZX_C1 / HiSilicon /
 *     YunOS 4.4.2, API 19) the SoC has ONE video decoder (single VDEC) and one
 *     SurfaceView output: you cannot keep A's decoder resident while B's decodes
 *     to the same surface — the second setDisplay steals the surface and a second
 *     concurrent decode can black-screen/overload the box (the same constraint
 *     that governs the §6.4 thumbnail rule). So on such a box the ONLY safe,
 *     non-regressing choice is [TransitionStrategy.IMMEDIATE_SWAP] and a brief
 *     black gap (≈ prepare+first-frame, ~300ms on this hardware) is an HONEST,
 *     documented platform limit — not something to paper over with a second
 *     decoder that risks the verified-smooth playback.
 *
 *     On a box that can run two decoders concurrently (multi-VDEC, typically
 *     newer/API≥21), [TransitionStrategy.HOLD_LAST_FRAME] is safe: defer the old
 *     player's release until the new player's first frame renders.
 */
object TransitionPolicy {

    enum class LoopStrategy {
        /** `setLooping(true)` — restart inside the decoder, no seam. Single-item loop. */
        OEM_CONTINUOUS,
        /** Reach end-of-stream and advance (multi-item loop can't use REPEAT_ONE). */
        ADVANCE_ON_END,
    }

    enum class TransitionStrategy {
        /** Release old, prepare new — brief black gap. Required on single-VDEC boxes. */
        IMMEDIATE_SWAP,
        /** Keep old last frame until new first frame renders. Needs a 2nd concurrent
         *  decoder → only on multi-VDEC hardware. */
        HOLD_LAST_FRAME,
    }

    /**
     * §6.3 three-mode loop → kernel strategy.
     *
     * @param itemCount items in the active playlist
     * @param loopMode  the resolved loop mode
     *
     * - ONE  → [LoopStrategy.OEM_CONTINUOUS]: the current item repeats seamlessly
     *          inside the single decoder (setLooping / REPEAT_MODE_ONE), with NO
     *          teardown and NO second decoder, REGARDLESS of item count. An
     *          explicit prev/next is a normal advance handled by the caller.
     * - ALL / NONE → [LoopStrategy.ADVANCE_ON_END]: reach end-of-stream and let
     *          the caller advance (ALL wraps, NONE stops). A multi-item REPEAT_ONE
     *          would freeze on the current item, which is exactly ONE's intent but
     *          wrong for ALL/NONE.
     *
     * Backward-compat: a legacy single-item loop=true folds to ALL here, and a
     * 1-item ALL still loops seamlessly because it is promoted below.
     */
    fun loopStrategy(itemCount: Int, loopMode: LoopMode): LoopStrategy = when (loopMode) {
        LoopMode.ONE -> LoopStrategy.OEM_CONTINUOUS
        // A single-item ALL is behaviourally identical to ONE — keep the seamless
        // OEM path so today's "loop a single MP4" stays seam-free.
        LoopMode.ALL -> if (itemCount <= 1) LoopStrategy.OEM_CONTINUOUS
                        else LoopStrategy.ADVANCE_ON_END
        LoopMode.NONE -> LoopStrategy.ADVANCE_ON_END
    }

    /**
     * @param androidSdk           Build.VERSION.SDK_INT
     * @param concurrentDecoders   how many hardware video decoders can run at once
     *                             (1 on the QZX_C1 single-VDEC box)
     * Hold-last-frame needs a second concurrent decoder AND is only worth the risk
     * on API≥21; the API≤19 single-VDEC target must swap immediately (accept the
     * brief, documented black gap) to protect confirmed-smooth playback.
     */
    fun transitionStrategy(androidSdk: Int, concurrentDecoders: Int): TransitionStrategy =
        if (androidSdk >= 21 && concurrentDecoders >= 2) TransitionStrategy.HOLD_LAST_FRAME
        else TransitionStrategy.IMMEDIATE_SWAP
}
