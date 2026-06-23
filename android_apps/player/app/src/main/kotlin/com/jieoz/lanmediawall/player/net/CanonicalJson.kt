package com.jieoz.lanmediawall.player.net

import java.math.BigDecimal
import java.math.BigInteger

/**
 * Canonical JSON serializer matching Python's
 *
 *     json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
 *
 * byte-for-byte for the value space this protocol uses (objects, arrays,
 * strings, integers, booleans, null). This is the single source of truth for
 * the §3 signing string, so it must mirror CPython's encoder precisely:
 *
 *   - object keys sorted ascending by Unicode code unit (Python sorts `str`
 *     keys with `<`, which for the BMP ASCII keys here equals UTF-16 order);
 *   - separators ',' and ':' with NO surrounding spaces;
 *   - strings: escape only `"`, `\`, and control chars < 0x20. Control chars
 *     use the short forms \b \t \n \f \r where defined, else \u00XX (lower-hex).
 *     Everything >= 0x20 (incl. all non-ASCII) is emitted as raw UTF-8 — this
 *     is the ensure_ascii=False contract, vital for Chinese device names;
 *   - integers: bare digits; non-integral numbers: Python float repr (fallback
 *     only — signed protocol payloads carry integers).
 */
object CanonicalJson {

    fun encode(value: Json): String {
        val sb = StringBuilder(128)
        write(value, sb)
        return sb.toString()
    }

    private fun write(value: Json, sb: StringBuilder) {
        when (value) {
            is Json.Null -> sb.append("null")
            is Json.Bool -> sb.append(if (value.value) "true" else "false")
            is Json.Num -> sb.append(normalizeNumber(value.raw))
            is Json.Str -> writeString(value.value, sb)
            is Json.Arr -> writeArray(value, sb)
            is Json.Obj -> writeObject(value, sb)
        }
    }

    private fun writeArray(arr: Json.Arr, sb: StringBuilder) {
        sb.append('[')
        for ((idx, item) in arr.items.withIndex()) {
            if (idx > 0) sb.append(',')
            write(item, sb)
        }
        sb.append(']')
    }

    private fun writeObject(obj: Json.Obj, sb: StringBuilder) {
        sb.append('{')
        // sort_keys=True — ascending by string comparison (UTF-16 code unit)
        val keys = obj.entries.keys.sortedWith(naturalOrder())
        for ((idx, key) in keys.withIndex()) {
            if (idx > 0) sb.append(',')
            writeString(key, sb)
            sb.append(':')
            write(obj.entries.getValue(key), sb)
        }
        sb.append('}')
    }

    /**
     * String escaping identical to CPython's `c_encode_basestring`
     * (ensure_ascii=False path): only ", \, and C0 controls are escaped.
     */
    private fun writeString(s: String, sb: StringBuilder) {
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                else -> {
                    if (c < ' ') {
                        sb.append("\\u")
                        sb.append(HEX[(c.code shr 12) and 0xF])
                        sb.append(HEX[(c.code shr 8) and 0xF])
                        sb.append(HEX[(c.code shr 4) and 0xF])
                        sb.append(HEX[c.code and 0xF])
                    } else {
                        sb.append(c)
                    }
                }
            }
        }
        sb.append('"')
    }

    /**
     * Normalize a parsed number token to Python's `json.dumps` output.
     * Integers (no '.', 'e', 'E') are emitted via BigInteger to drop any
     * superfluous leading characters and match Python's `int` repr. Non-integral
     * values fall back to a shortest-round-trip double repr that matches
     * CPython's `float.__repr__` for the common cases.
     */
    private fun normalizeNumber(raw: String): String {
        val isIntegral = raw.indexOf('.') < 0 &&
            raw.indexOf('e') < 0 && raw.indexOf('E') < 0
        if (isIntegral) {
            return BigInteger(raw).toString()
        }
        return pythonFloatRepr(raw)
    }

    /**
     * Best-effort match to CPython `repr(float(x))`. Used only on the defensive
     * float path (the protocol's *signed* payloads are integer-only), so this
     * does not need to be exhaustive — it produces the standard forms
     * (e.g. "1.5", "1000.0", "1e+20") Python yields for typical values.
     */
    private fun pythonFloatRepr(raw: String): String {
        val d = raw.toDouble()
        if (d == Math.floor(d) && !d.isInfinite() &&
            Math.abs(d) < 1e16
        ) {
            // integral-valued float → Python prints "N.0"
            return BigDecimal(d).toBigInteger().toString() + ".0"
        }
        val repr = d.toString() // Kotlin/Java shortest repr, close to Python's
        return repr
    }

    private val HEX = "0123456789abcdef".toCharArray()
}
