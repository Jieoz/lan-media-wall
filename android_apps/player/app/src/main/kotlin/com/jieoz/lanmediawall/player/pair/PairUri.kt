package com.jieoz.lanmediawall.player.pair

import com.jieoz.lanmediawall.player.net.AuthMode
import java.net.URLDecoder

/**
 * Parser for the `lmw://pair?…` pairing URI — protocol_spec §15.1.
 *
 *     lmw://pair?host=<ip>&port=<8770>&group=<gid>&mode=<open|optional|required>
 *               &psk=<hex?>&wss=<0|1>&name=<可选预设名>
 *
 * The headline免手输 (no-typing) feature for the Android被控端 (§15): a scanned
 * QR encodes this URI; we parse it and auto-fill connection settings, so the
 * operator types NOTHING. Rules from §15:
 *   - `open` mode carries **no** `psk` (pure "scan to join"); `required` /
 *     `optional` carry the §3 32+ byte hex key — the QR is the入场券.
 *   - all values are standard URL-encoded (so Chinese preset names, `+`/`%20`
 *     spaces, `:`/`/` etc. survive),
 *   - **unknown query params are ignored** (forward-compatible, §15.1),
 *   - mode parsing reuses [AuthMode.parse] (unknown/missing → `open`, §15.3).
 *
 * Pure logic, no Android dependencies — fully unit-testable on the JVM.
 */
data class PairUri(
    val host: String,
    val port: Int,
    val group: String?,
    val mode: AuthMode,
    val psk: String?,
    val wss: Boolean,
    val name: String?,
) {
    companion object {
        const val SCHEME = "lmw"
        const val PAIR_HOST = "pair"
        const val DEFAULT_PORT = 8770

        /**
         * Parse a scanned/typed string into a [PairUri], or null if it is not a
         * well-formed `lmw://pair?…` URI with at least a `host`. Tolerant of
         * surrounding whitespace and case-insensitive scheme/authority.
         */
        fun parse(raw: String?): PairUri? {
            if (raw == null) return null
            val text = raw.trim()
            if (text.isEmpty()) return null

            // Split scheme://authority[?query]. We don't use java.net.URI because
            // custom schemes + raw Chinese in the query trip its strict parser;
            // a small hand-split is more forgiving and matches §15's intent.
            val schemeSep = text.indexOf("://")
            if (schemeSep < 0) return null
            val scheme = text.substring(0, schemeSep).lowercase()
            if (scheme != SCHEME) return null

            val rest = text.substring(schemeSep + 3)
            val qMark = rest.indexOf('?')
            val authority = (if (qMark >= 0) rest.substring(0, qMark) else rest)
                .trimEnd('/')
                .lowercase()
            if (authority != PAIR_HOST) return null
            val query = if (qMark >= 0) rest.substring(qMark + 1) else ""

            val params = parseQuery(query)

            val host = params["host"]?.takeIf { it.isNotBlank() } ?: return null
            val port = params["port"]?.let { parsePort(it) } ?: DEFAULT_PORT
            val mode = AuthMode.parse(params["mode"])
            // §15.1: open mode carries no psk. Even if one is mistakenly present,
            // ignore it under open so we never sign with a stray key.
            val psk = if (mode == AuthMode.OPEN) null
            else params["psk"]?.takeIf { it.isNotBlank() }
            val wss = parseBoolFlag(params["wss"])
            val group = params["group"]?.takeIf { it.isNotBlank() }
            val name = params["name"]?.takeIf { it.isNotBlank() }

            return PairUri(host, port, group, mode, psk, wss, name)
        }

        private fun parsePort(s: String): Int? =
            s.trim().toIntOrNull()?.takeIf { it in 1..65535 }

        /** `1`/`true`/`yes`/`on` (case-insensitive) → true; everything else false. */
        private fun parseBoolFlag(s: String?): Boolean = when (s?.trim()?.lowercase()) {
            "1", "true", "yes", "on" -> true
            else -> false
        }

        /**
         * Parse an `&`-separated `key=value` query into a map. Keys are lower-
         * cased; both keys and values are URL-decoded (UTF-8, `+`→space). A bare
         * `key` (no `=`) maps to "". Later duplicates win.
         */
        private fun parseQuery(query: String): Map<String, String> {
            if (query.isEmpty()) return emptyMap()
            val out = LinkedHashMap<String, String>()
            for (pair in query.split('&')) {
                if (pair.isEmpty()) continue
                val eq = pair.indexOf('=')
                val rawKey: String
                val rawVal: String
                if (eq < 0) {
                    rawKey = pair; rawVal = ""
                } else {
                    rawKey = pair.substring(0, eq); rawVal = pair.substring(eq + 1)
                }
                val key = urlDecode(rawKey).lowercase()
                if (key.isEmpty()) continue
                out[key] = urlDecode(rawVal)
            }
            return out
        }

        private fun urlDecode(s: String): String = try {
            URLDecoder.decode(s, "UTF-8")
        } catch (e: Exception) {
            s // malformed %-escape → keep raw rather than throwing
        }
    }
}
