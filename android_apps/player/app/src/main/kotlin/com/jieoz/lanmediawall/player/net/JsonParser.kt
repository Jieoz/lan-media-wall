package com.jieoz.lanmediawall.player.net

/**
 * Recursive-descent JSON parser producing the [Json] model. Tolerant of the
 * full JSON grammar (RFC 8259) for inbound messages; preserves number tokens
 * verbatim so canonical re-serialization is lossless for integers.
 *
 * Not a hot path beyond per-message parsing; clarity over micro-optimization.
 */
internal class JsonParser(private val s: String) {
    private var i = 0

    fun parseValue(): Json {
        skipWs()
        val v = parseValueInner()
        skipWs()
        if (i != s.length) fail("trailing data")
        return v
    }

    private fun parseValueInner(): Json {
        skipWs()
        if (i >= s.length) fail("unexpected end")
        return when (s[i]) {
            '{' -> parseObject()
            '[' -> parseArray()
            '"' -> Json.Str(parseString())
            't', 'f' -> parseBool()
            'n' -> parseNull()
            else -> parseNumber()
        }
    }

    private fun parseObject(): Json.Obj {
        expect('{')
        val map = LinkedHashMap<String, Json>()
        skipWs()
        if (peek() == '}') { i++; return Json.Obj(map) }
        while (true) {
            skipWs()
            if (peek() != '"') fail("expected object key")
            val key = parseString()
            skipWs()
            expect(':')
            val value = parseValueInner()
            map[key] = value
            skipWs()
            when (peek()) {
                ',' -> { i++; continue }
                '}' -> { i++; break }
                else -> fail("expected ',' or '}'")
            }
        }
        return Json.Obj(map)
    }

    private fun parseArray(): Json.Arr {
        expect('[')
        val list = ArrayList<Json>()
        skipWs()
        if (peek() == ']') { i++; return Json.Arr(list) }
        while (true) {
            list.add(parseValueInner())
            skipWs()
            when (peek()) {
                ',' -> { i++; continue }
                ']' -> { i++; break }
                else -> fail("expected ',' or ']'")
            }
        }
        return Json.Arr(list)
    }

    private fun parseString(): String {
        expect('"')
        val sb = StringBuilder()
        while (true) {
            if (i >= s.length) fail("unterminated string")
            val c = s[i++]
            when (c) {
                '"' -> return sb.toString()
                '\\' -> {
                    if (i >= s.length) fail("bad escape")
                    when (val e = s[i++]) {
                        '"' -> sb.append('"')
                        '\\' -> sb.append('\\')
                        '/' -> sb.append('/')
                        'b' -> sb.append('\b')
                        'f' -> sb.append('\u000C')
                        'n' -> sb.append('\n')
                        'r' -> sb.append('\r')
                        't' -> sb.append('\t')
                        'u' -> {
                            if (i + 4 > s.length) fail("bad \\u escape")
                            val hex = s.substring(i, i + 4)
                            i += 4
                            sb.append(hex.toInt(16).toChar())
                        }
                        else -> fail("bad escape: \\$e")
                    }
                }
                else -> sb.append(c)
            }
        }
    }

    private fun parseNumber(): Json.Num {
        val start = i
        if (peek() == '-') i++
        while (i < s.length && (s[i].isDigit() || s[i] in ".eE+-")) i++
        val token = s.substring(start, i)
        if (token.isEmpty() || token == "-") fail("invalid number")
        return Json.Num(token)
    }

    private fun parseBool(): Json.Bool {
        return when {
            s.startsWith("true", i) -> { i += 4; Json.Bool(true) }
            s.startsWith("false", i) -> { i += 5; Json.Bool(false) }
            else -> fail("invalid literal")
        }
    }

    private fun parseNull(): Json {
        if (s.startsWith("null", i)) { i += 4; return Json.Null }
        fail("invalid literal")
    }

    private fun peek(): Char = if (i < s.length) s[i] else ' '
    private fun expect(c: Char) { if (peek() != c) fail("expected '$c'"); i++ }
    private fun skipWs() { while (i < s.length && s[i] in " \t\n\r") i++ }
    private fun fail(msg: String): Nothing =
        throw IllegalArgumentException("JSON parse error at $i: $msg")
}
