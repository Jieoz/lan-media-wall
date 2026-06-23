package com.jieoz.lanmediawall.player.net

import java.math.BigDecimal
import java.math.BigInteger

/**
 * A minimal, dependency-free JSON value model + parser + **canonical** serializer.
 *
 * Why hand-rolled instead of org.json / kotlinx.serialization?
 * The HMAC signing string (protocol_spec §3) is computed over
 *
 *     json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
 *
 * on the Python side (broker + windows_player). The broker **re-signs every
 * message it forwards**, so to verify an inbound envelope we must reproduce
 * Python's canonical bytes *exactly*, and to sign an outbound one the broker
 * must reproduce ours when it re-parses + re-canonicalizes. That requires
 * byte-for-byte control over:
 *   - key ordering (lexicographic by UTF-16 code unit — matches Python's sort
 *     of `str` keys for the ASCII keys this protocol uses),
 *   - separators (no spaces: `,` and `:`),
 *   - string escaping (ensure_ascii=False → non-ASCII stays raw UTF-8; only
 *     ", \, and control chars < 0x20 are escaped),
 *   - number formatting (integers emit as plain digits; the protocol's signed
 *     payloads are all integer/string/bool/null — see [JsonNum]).
 * org.json can't guarantee this and isn't on the JVM unit-test classpath, so a
 * tiny purpose-built model keeps the alignment provable and unit-testable.
 */
sealed class Json {

    object Null : Json()

    data class Bool(val value: Boolean) : Json()

    /**
     * Number. Stored as the original lexical token when parsed so we never lose
     * or reformat precision. When built programmatically, integers keep their
     * canonical decimal form. Non-integral values are formatted to match
     * Python's `repr(float)` shortest round-trip — but note the protocol's
     * **signed** payloads contain only integers, so the float path is a
     * defensive fallback, not a hot path.
     */
    data class Num(val raw: String) : Json() {
        companion object {
            fun of(v: Long): Num = Num(v.toString())
            fun of(v: Int): Num = Num(v.toString())
            fun of(v: BigInteger): Num = Num(v.toString())
        }
    }

    data class Str(val value: String) : Json()

    data class Arr(val items: List<Json>) : Json()

    /** Object. Insertion order is irrelevant — canonical output sorts keys. */
    data class Obj(val entries: Map<String, Json>) : Json()

    companion object {
        fun parse(text: String): Json = JsonParser(text).parseValue()
    }
}
