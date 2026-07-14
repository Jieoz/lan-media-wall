package com.jieoz.lanmediawall.player.cache

import com.jieoz.lanmediawall.player.net.Json
import com.jieoz.lanmediawall.player.net.asBoolOrNull
import com.jieoz.lanmediawall.player.net.asString
import com.jieoz.lanmediawall.player.net.get

/**
 * §6.3 LoopMode — single-source three-mode loop + one legacy fold point.
 *
 * Wire contract: a `playlist` payload carries the canonical string field
 * `loop_mode` in {"none","all","one"}. Legacy peers (≤v1.14.13) only send the
 * boolean `loop`. [resolve] is the ONE fold point: `loop_mode` wins when present
 * & valid; otherwise it derives from legacy `loop` (true→ALL, false/absent→NONE).
 *
 * Behaviour (identical Windows/Android/Flutter):
 *  - NONE: playback stops/holds at completion; explicit prev/next clamps.
 *  - ALL : completion and prev/next wrap the whole list.
 *  - ONE : the current item repeats seamlessly on completion (OEM continuous /
 *          REPEAT_MODE_ONE — a single decoder, no seam); explicit prev/next
 *          still navigates with wrap.
 */
enum class LoopMode(val wire: String) {
    NONE("none"),
    ALL("all"),
    ONE("one"),
    ;

    /** Compat projection emitted alongside `loop_mode` so old players still wrap. */
    val legacyLoopBool: Boolean get() = this != NONE

    companion object {
        /** The single legacy fold point. Prefer canonical `loop_mode`; else derive
         *  from the legacy boolean `loop`. Unknown strings fall back to the legacy
         *  fold (forward-compat), never throw. */
        fun resolve(node: Json?): LoopMode {
            val raw = node?.get("loop_mode").asString()
            if (raw != null) {
                val v = raw.trim().lowercase()
                for (m in values()) if (m.wire == v) return m
            }
            val legacy = node?.get("loop").asBoolOrNull() ?: false
            return if (legacy) ALL else NONE
        }

        fun fromWire(s: String?): LoopMode {
            if (s != null) {
                val v = s.trim().lowercase()
                for (m in values()) if (m.wire == v) return m
            }
            return NONE
        }
    }
}
