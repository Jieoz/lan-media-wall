package com.jieoz.lanmediawall.player.pair

import com.jieoz.lanmediawall.player.net.AuthMode
import com.jieoz.lanmediawall.player.net.KeyMode
import java.net.URLDecoder

/**
 * Parser for the `lmw://pair?…` pairing URI — protocol_spec §15.1 + §17.4.
 *
 *     lmw://pair?host=<ip>&port=<8770>&group=<gid>&mode=<open|optional|required>
 *               &key_mode=<global|derived>&psk=<hex?>&dk=<hex?>&id=<identity?>
 *               &bk=<hex?>&wss=<0|1>&name=<可选预设名>
 *
 * The headline免手输 (no-typing) feature for the Android被控端 (§15): a scanned
 * QR encodes this URI; we parse it and auto-fill connection settings, so the
 * operator types NOTHING. Rules from §15 + §17.4:
 *   - `open` mode carries **no** key material (pure "scan to join").
 *   - `key_mode=global` (or absent → global, §17.3) carries the §3 32+ byte hex
 *     PSK in `psk` — the v1.2 入场券.
 *   - `key_mode=derived` (§17.4) carries this end's own `dk` (device_key hex,
 *     = `HMAC(PSK, id)`) + `id` (its identity), and **never** the PSK. The end
 *     stores only its device_key. An optional `bk` (broker device_key hex) lets
 *     the end verify broker downlink without the PSK (forward-compat — see
 *     NOTES_TO_UPSTREAM §4; absent in today's broker QR).
 *   - all values are standard URL-encoded (so Chinese preset names, `+`/`%20`
 *     spaces, `:`/`/` etc. survive),
 *   - **unknown query params are ignored** (forward-compatible, §15.1),
 *   - mode parsing reuses [AuthMode.parse] (unknown/missing → `open`, §15.3),
 *   - key_mode parsing reuses [KeyMode.parse] (unknown/missing → `global`, §17.3).
 *
 * Pure logic, no Android dependencies — fully unit-testable on the JVM.
 */
data class PairUri(
    val host: String,
    val port: Int,
    val group: String?,
    val mode: AuthMode,
    val keyMode: KeyMode,
    /** Global-mode shared PSK (hex); null in open/derived. */
    val psk: String?,
    /** Derived-mode: this end's own device_key (hex); null otherwise. */
    val deviceKeyHex: String?,
    /** Derived-mode: this end's identity (its `from`); null otherwise. */
    val identity: String?,
    /** Derived-mode (optional, forward-compat): broker's device_key (hex). */
    val brokerKeyHex: String?,
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
            val keyMode = KeyMode.parse(params["key_mode"])
            val wss = parseBoolFlag(params["wss"])
            val group = params["group"]?.takeIf { it.isNotBlank() }
            val name = params["name"]?.takeIf { it.isNotBlank() }

            // §15.1/§17.4 key material. open carries none (ignore any stray key
            // so we never sign with it). Otherwise derived → dk+id (+optional
            // bk); global → psk. We honour key_mode but tolerate a mismatch:
            // if derived fields are absent we fall back to psk (and vice-versa)
            // so an old/new QR pairing still works.
            var psk: String? = null
            var dk: String? = null
            var id: String? = null
            var bk: String? = null
            if (mode != AuthMode.OPEN) {
                dk = params["dk"]?.takeIf { it.isNotBlank() }
                id = params["id"]?.takeIf { it.isNotBlank() }
                bk = params["bk"]?.takeIf { it.isNotBlank() }
                psk = params["psk"]?.takeIf { it.isNotBlank() }
                if (keyMode == KeyMode.DERIVED) {
                    // derived: keep the PSK only if the QR (oddly) also carried
                    // it AND we lack a usable dk — otherwise never hold the PSK.
                    if (dk != null && id != null) psk = null
                }
            }

            return PairUri(host, port, group, mode, keyMode, psk, dk, id, bk, wss, name)
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
