package com.jieoz.lanmediawall.player.net

import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Message envelope + HMAC signing/verification — protocol_spec §2, §3.
 *
 * Mirrors windows_player/envelope.py and broker/envelope.py exactly:
 *
 *   signing_string = "{v}|{type}|{msg_id}|{ts}|{from}|{to}|{canonical_json(payload)}"
 *   sig            = HMAC_SHA256(PSK_utf8, signing_string_utf8).hexdigest()
 *
 * canonical_json is [CanonicalJson.encode] (sort_keys + compact + ensure_ascii=False).
 * Pure logic, no Android dependencies — fully unit-testable on the JVM.
 */
object Envelope {
    const val PROTOCOL_VERSION = 1

    // §3 thresholds (mirror envelope.py)
    const val FRESH_WINDOW_MS = 30_000L
    const val FIRST_CONNECT_WINDOW_MS = 120_000L
    const val DEDUP_TTL_MS = 5L * 60 * 1000

    /** Local wall-clock epoch milliseconds (the spec's `ts`). */
    fun nowMs(): Long = System.currentTimeMillis()

    fun signingString(
        v: Int, type: String, msgId: String, ts: Long,
        from: String, to: String, payload: Json,
    ): String = "$v|$type|$msgId|$ts|$from|$to|${CanonicalJson.encode(payload)}"

    fun sign(
        psk: String, v: Int, type: String, msgId: String, ts: Long,
        from: String, to: String, payload: Json,
    ): String {
        val msg = signingString(v, type, msgId, ts, from, to, payload)
        return hmacSha256Hex(psk, msg)
    }

    fun hmacSha256Hex(psk: String, message: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(psk.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        val digest = mac.doFinal(message.toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) {
            val v = b.toInt() and 0xFF
            sb.append(HEX[v ushr 4])
            sb.append(HEX[v and 0xF])
        }
        return sb.toString()
    }

    /** Construct a fully-signed outbound envelope as a [Json.Obj]. */
    fun build(
        psk: String, type: String, from: String, to: String, payload: Json,
        msgId: String = UUID.randomUUID().toString(),
        ts: Long = nowMs(),
    ): Json.Obj {
        val v = PROTOCOL_VERSION
        val sig = sign(psk, v, type, msgId, ts, from, to, payload)
        return jsonObj {
            put("v", v)
            put("type", type)
            put("msg_id", msgId)
            put("ts", ts)
            put("from", from)
            put("to", to)
            put("sig", sig)
            put("payload", payload)
        }
    }

    /** Serialize an envelope to wire text. Non-canonical separators are fine on
     *  the wire — the receiver re-canonicalizes the payload for verification. */
    fun toWire(env: Json.Obj): String = CanonicalJson.encode(env)

    data class Parsed(
        val v: Int,
        val type: String,
        val msgId: String,
        val ts: Long,
        val from: String,
        val to: String,
        val sig: String,
        val payload: Json,
        val payloadObj: Json.Obj,
    )

    enum class Reason { OK, SHAPE, SIG, STALE, DUP }

    data class VerifyResult(val ok: Boolean, val reason: Reason, val parsed: Parsed?)

    /**
     * Validate an inbound envelope per §3:
     *   1. shape check (all fields present, payload is object),
     *   2. recompute sig and constant-time compare,
     *   3. freshness window (120s on first connect, else 30s),
     *   4. replay dedup via [replay] (5-minute LRU).
     */
    fun verify(
        psk: String,
        raw: String,
        replay: ReplayCache? = null,
        firstConnect: Boolean = false,
        now: Long = nowMs(),
    ): VerifyResult {
        val root = try {
            Json.parse(raw)
        } catch (e: Exception) {
            return VerifyResult(false, Reason.SHAPE, null)
        }
        val obj = root as? Json.Obj ?: return VerifyResult(false, Reason.SHAPE, null)
        val e = obj.entries
        val required = listOf("v", "type", "msg_id", "ts", "from", "to", "sig", "payload")
        if (required.any { it !in e }) return VerifyResult(false, Reason.SHAPE, null)
        val payload = e["payload"]
        val payloadObj = payload as? Json.Obj
            ?: return VerifyResult(false, Reason.SHAPE, null)

        val v = (e["v"]).asIntOrNull() ?: return VerifyResult(false, Reason.SHAPE, null)
        val type = (e["type"]).asString() ?: return VerifyResult(false, Reason.SHAPE, null)
        val msgId = (e["msg_id"]).asString() ?: return VerifyResult(false, Reason.SHAPE, null)
        val ts = (e["ts"]).asLongOrNull() ?: return VerifyResult(false, Reason.SHAPE, null)
        val from = (e["from"]).asString() ?: return VerifyResult(false, Reason.SHAPE, null)
        val to = (e["to"]).asString() ?: return VerifyResult(false, Reason.SHAPE, null)
        val sig = (e["sig"]).asString() ?: return VerifyResult(false, Reason.SHAPE, null)

        val expected = sign(psk, v, type, msgId, ts, from, to, payloadObj)
        if (!constantTimeEquals(expected, sig)) {
            return VerifyResult(false, Reason.SIG, null)
        }

        val window = if (firstConnect) FIRST_CONNECT_WINDOW_MS else FRESH_WINDOW_MS
        if (Math.abs(now - ts) > window) {
            return VerifyResult(false, Reason.STALE, null)
        }

        if (replay != null && replay.seen(msgId, now)) {
            return VerifyResult(false, Reason.DUP, null)
        }

        val parsed = Parsed(v, type, msgId, ts, from, to, sig, payloadObj, payloadObj)
        return VerifyResult(true, Reason.OK, parsed)
    }

    private fun constantTimeEquals(a: String, b: String): Boolean {
        val ab = a.toByteArray(Charsets.UTF_8)
        val bb = b.toByteArray(Charsets.UTF_8)
        if (ab.size != bb.size) return false
        var r = 0
        for (i in ab.indices) r = r or (ab[i].toInt() xor bb[i].toInt())
        return r == 0
    }

    private val HEX = "0123456789abcdef".toCharArray()
}
