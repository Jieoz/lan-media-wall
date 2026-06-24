package com.jieoz.lanmediawall.player.net

import java.security.MessageDigest

/**
 * RFC 6455 opening-handshake codec for the p2p WS **server** (§14.3).
 *
 * In p2p mode the player runs a WebSocket server on 8770 that the controller
 * dials into. OkHttp only ships a WS *client*, so the server side is hand-
 * rolled — and the handshake is pure string/bytes work, hence its own
 * unit-testable object.
 *
 *   accept = base64( SHA1( Sec-WebSocket-Key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" ) )
 *
 * Pure logic, no Android dependencies.
 */
object WsHandshake {

    const val GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    data class Request(val headers: Map<String, String>) {
        val key: String? get() = headers["sec-websocket-key"]
        val isUpgrade: Boolean
            get() = headers["upgrade"]?.lowercase()?.contains("websocket") == true &&
                headers["connection"]?.lowercase()?.contains("upgrade") == true &&
                key != null
    }

    /**
     * Parse the raw HTTP request head (everything up to the blank line) into a
     * header map (lower-cased keys). Returns null if the request line is absent
     * or it isn't a GET. Tolerant of CRLF or LF line endings.
     */
    fun parseRequest(head: String): Request? {
        val lines = head.split("\r\n", "\n").filter { it.isNotEmpty() }
        if (lines.isEmpty()) return null
        val requestLine = lines[0].trim()
        if (!requestLine.uppercase().startsWith("GET ")) return null
        val headers = LinkedHashMap<String, String>()
        for (i in 1 until lines.size) {
            val line = lines[i]
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            val name = line.substring(0, colon).trim().lowercase()
            val value = line.substring(colon + 1).trim()
            headers[name] = value
        }
        return Request(headers)
    }

    /** Compute the `Sec-WebSocket-Accept` response token for a client key. */
    fun acceptFor(key: String): String {
        val sha1 = MessageDigest.getInstance("SHA-1")
        val digest = sha1.digest((key + GUID).toByteArray(Charsets.UTF_8))
        return Base64.encode(digest)
    }

    /** Build the full HTTP 101 response head (ends with the blank line). */
    fun responseFor(key: String): String {
        val accept = acceptFor(key)
        return buildString {
            append("HTTP/1.1 101 Switching Protocols\r\n")
            append("Upgrade: websocket\r\n")
            append("Connection: Upgrade\r\n")
            append("Sec-WebSocket-Accept: ").append(accept).append("\r\n")
            append("\r\n")
        }
    }

    /** Minimal RFC 4648 base64 encoder (no padding tricks) — avoids depending on
     *  android.util.Base64 / java.util.Base64 availability in unit tests. */
    object Base64 {
        private const val ALPHABET =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

        fun encode(data: ByteArray): String {
            val sb = StringBuilder((data.size + 2) / 3 * 4)
            var i = 0
            while (i < data.size) {
                val b0 = data[i].toInt() and 0xFF
                val b1 = if (i + 1 < data.size) data[i + 1].toInt() and 0xFF else 0
                val b2 = if (i + 2 < data.size) data[i + 2].toInt() and 0xFF else 0
                val triple = (b0 shl 16) or (b1 shl 8) or b2
                sb.append(ALPHABET[(triple ushr 18) and 0x3F])
                sb.append(ALPHABET[(triple ushr 12) and 0x3F])
                sb.append(if (i + 1 < data.size) ALPHABET[(triple ushr 6) and 0x3F] else '=')
                sb.append(if (i + 2 < data.size) ALPHABET[triple and 0x3F] else '=')
                i += 3
            }
            return sb.toString()
        }
    }
}
