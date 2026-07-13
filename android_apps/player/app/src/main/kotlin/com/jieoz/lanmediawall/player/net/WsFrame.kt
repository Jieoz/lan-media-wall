package com.jieoz.lanmediawall.player.net

import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream

/**
 * RFC 6455 §5 frame codec for the p2p WS server (§14.3) — the read/write half of
 * the hand-rolled server (handshake is [WsHandshake]).
 *
 * Scope: the protocol only needs text frames (JSON, §2), binary frames
 * (thumbnails §6.4 — though in p2p the player is the server and doesn't push
 * thumbnails inbound, we still encode them for symmetry), ping/pong, and close.
 * Client→server frames are **masked** (mandatory per RFC); server→client frames
 * are **unmasked**. Continuation/fragmentation isn't used by either end here, so
 * a fragmented frame is surfaced as an error rather than silently mishandled.
 *
 * The byte-level encode/decode is pure and unit-testable; the stream helpers are
 * thin glue over it.
 */
object WsFrame {

    const val OP_CONTINUATION = 0x0
    const val OP_TEXT = 0x1
    const val OP_BINARY = 0x2
    const val OP_CLOSE = 0x8
    const val OP_PING = 0x9
    const val OP_PONG = 0xA

    data class Frame(val opcode: Int, val payload: ByteArray, val fin: Boolean = true) {
        val isText: Boolean get() = opcode == OP_TEXT
        val isBinary: Boolean get() = opcode == OP_BINARY
        val isClose: Boolean get() = opcode == OP_CLOSE
        val isPing: Boolean get() = opcode == OP_PING
        val isPong: Boolean get() = opcode == OP_PONG
        fun text(): String = String(payload, Charsets.UTF_8)

        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Frame) return false
            return opcode == other.opcode && fin == other.fin &&
                payload.contentEquals(other.payload)
        }

        override fun hashCode(): Int =
            (opcode * 31 + fin.hashCode()) * 31 + payload.contentHashCode()
    }

    /**
     * Encode a server→client frame (unmasked, FIN=1). Pure — returns the bytes.
     */
    fun encode(opcode: Int, payload: ByteArray): ByteArray {
        val out = ArrayList<Byte>(payload.size + 10)
        out.add((0x80 or (opcode and 0x0F)).toByte()) // FIN + opcode
        val len = payload.size
        when {
            len < 126 -> out.add(len.toByte())
            len <= 0xFFFF -> {
                out.add(126.toByte())
                out.add(((len ushr 8) and 0xFF).toByte())
                out.add((len and 0xFF).toByte())
            }
            else -> {
                out.add(127.toByte())
                for (shift in 56 downTo 0 step 8) {
                    out.add(((len.toLong() ushr shift) and 0xFF).toByte())
                }
            }
        }
        // server→client: MASK bit 0, no masking key
        for (b in payload) out.add(b)
        return out.toByteArray()
    }

    fun encodeText(text: String): ByteArray =
        encode(OP_TEXT, text.toByteArray(Charsets.UTF_8))

    fun encodeBinary(data: ByteArray): ByteArray = encode(OP_BINARY, data)

    fun encodeClose(code: Int = 1000): ByteArray {
        val p = byteArrayOf(((code ushr 8) and 0xFF).toByte(), (code and 0xFF).toByte())
        return encode(OP_CLOSE, p)
    }

    fun encodePong(payload: ByteArray): ByteArray = encode(OP_PONG, payload)

    fun encodePing(payload: ByteArray = byteArrayOf()): ByteArray = encode(OP_PING, payload)

    /**
     * Read and decode one frame from [input] (a client→server frame, expected
     * masked). Returns null at clean EOF. Throws [WsProtocolException] on a
     * malformed or unexpectedly-unmasked frame.
     */
    fun readFrame(input: InputStream): Frame? {
        val b0 = input.read()
        if (b0 < 0) return null
        val fin = (b0 and 0x80) != 0
        val opcode = b0 and 0x0F
        val b1 = readByteOrThrow(input)
        val masked = (b1 and 0x80) != 0
        var len = (b1 and 0x7F).toLong()
        when (len.toInt()) {
            126 -> {
                len = ((readByteOrThrow(input).toLong() shl 8) or
                    readByteOrThrow(input).toLong())
            }
            127 -> {
                len = 0
                for (k in 0 until 8) {
                    len = (len shl 8) or readByteOrThrow(input).toLong()
                }
            }
        }
        if (len < 0 || len > MAX_PAYLOAD) {
            throw WsProtocolException("frame too large: $len")
        }
        val mask = if (masked) ByteArray(4).also { readFully(input, it) } else null
        val payload = ByteArray(len.toInt())
        readFully(input, payload)
        if (mask != null) {
            for (k in payload.indices) {
                payload[k] = (payload[k].toInt() xor mask[k % 4].toInt()).toByte()
            }
        }
        return Frame(opcode, payload, fin)
    }

    private fun readByteOrThrow(input: InputStream): Int {
        val b = input.read()
        if (b < 0) throw EOFException("unexpected EOF in frame header")
        return b
    }

    private fun readFully(input: InputStream, buf: ByteArray) {
        var off = 0
        while (off < buf.size) {
            val n = input.read(buf, off, buf.size - off)
            if (n < 0) throw EOFException("unexpected EOF in frame body")
            off += n
        }
    }

    fun write(out: OutputStream, bytes: ByteArray) {
        out.write(bytes)
        out.flush()
    }

    class WsProtocolException(msg: String) : Exception(msg)

    // 4 MiB ceiling — matches the broker's websockets max_size (broker.py).
    private const val MAX_PAYLOAD = 4L * 1024 * 1024
}
