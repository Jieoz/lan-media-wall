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

    /** The placeholder PSK shipped by default (see Settings.DEFAULT_PSK). Treated
     *  as "no real key" by [hasUsableKey] so `optional` mode degrades to `sig=""`
     *  rather than emitting a signature derived from a well-known string. */
    const val PLACEHOLDER_PSK = "CHANGE_ME_32_BYTE_RANDOM_PRESHARED_KEY"


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

    /**
     * §17.2 key derivation: `device_key = HMAC_SHA256(PSK, identity).digest()`.
     *
     * Returns the **32 raw bytes** of the HMAC digest — used directly as the key
     * of the next HMAC layer (do NOT hex-encode it first, §17.5). `identity` is
     * the envelope `from` string **verbatim** — no normalization/lowercasing/
     * trimming (§17.5). Mirrors broker/envelope.py::derive_key byte-for-byte.
     */
    fun deriveKey(psk: String, identity: String): ByteArray =
        hmacSha256(psk.toByteArray(Charsets.UTF_8), identity.toByteArray(Charsets.UTF_8))

    /**
     * Resolve the raw HMAC **key bytes** for the active [keyMode] (§17.2/§17.3):
     *   - [KeyMode.DERIVED] → `device_key` derived from [identity];
     *   - [KeyMode.GLOBAL]  → the PSK's UTF-8 bytes (v1.2 behaviour).
     * [identity] is the sender's own `from` when signing, or the frame's `from`
     * when verifying.
     */
    fun signingKey(psk: String, keyMode: KeyMode, identity: String): ByteArray =
        when (keyMode) {
            KeyMode.DERIVED -> deriveKey(psk, identity)
            KeyMode.GLOBAL -> psk.toByteArray(Charsets.UTF_8)
        }

    /**
     * Sign the §3 signing string. [keyMode] picks the HMAC key per §17:
     *   - GLOBAL (default): the raw PSK — byte-identical to v1.2.
     *   - DERIVED: the sender's own device_key (`HMAC(PSK, from)`), so the
     *     identity in `from` is bound into the key.
     */
    fun sign(
        psk: String, v: Int, type: String, msgId: String, ts: Long,
        from: String, to: String, payload: Json,
        keyMode: KeyMode = KeyMode.GLOBAL,
    ): String {
        val msg = signingString(v, type, msgId, ts, from, to, payload)
        return hmacSha256Hex(signingKey(psk, keyMode, from), msg)
    }

    /**
     * Sign with an **explicit raw key** — for a dk-only end (§17.4) that holds
     * its own `device_key` and never the PSK. The caller passes its stored
     * device_key bytes; in derived mode this is byte-identical to
     * `sign(psk, …, keyMode = DERIVED)` because `device_key == HMAC(PSK, from)`.
     */
    fun signWithKey(
        key: ByteArray, v: Int, type: String, msgId: String, ts: Long,
        from: String, to: String, payload: Json,
    ): String = hmacSha256Hex(key, signingString(v, type, msgId, ts, from, to, payload))

    fun hmacSha256Hex(psk: String, message: String): String =
        hmacSha256Hex(psk.toByteArray(Charsets.UTF_8), message)

    /** HMAC-SHA256 over [message] keyed by raw [key] bytes, hex-encoded. */
    fun hmacSha256Hex(key: ByteArray, message: String): String {
        val digest = hmacSha256(key, message.toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) {
            val v = b.toInt() and 0xFF
            sb.append(HEX[v ushr 4])
            sb.append(HEX[v and 0xF])
        }
        return sb.toString()
    }

    /** Raw HMAC-SHA256 digest (32 bytes) keyed by [key] over [data]. */
    fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    /** Construct a fully-signed outbound envelope as a [Json.Obj]. */
    fun build(
        psk: String, type: String, from: String, to: String, payload: Json,
        msgId: String = UUID.randomUUID().toString(),
        ts: Long = nowMs(),
        keyMode: KeyMode = KeyMode.GLOBAL,
    ): Json.Obj {
        val v = PROTOCOL_VERSION
        val sig = sign(psk, v, type, msgId, ts, from, to, payload, keyMode)
        return assemble(v, type, msgId, ts, from, to, sig, payload)
    }

    /** Serialize an envelope to wire text. Non-canonical separators are fine on
     *  the wire — the receiver re-canonicalizes the payload for verification. */
    fun toWire(env: Json.Obj): String = CanonicalJson.encode(env)

    /**
     * Auth-mode-aware build (§13). The `sig` field is **always present** so the
     * §2 envelope shape never changes; only its value depends on the mode:
     *   - [AuthMode.OPEN]      → `sig=""` (no key needed, zero-config);
     *   - [AuthMode.OPTIONAL]  → sign iff [psk] is a real key, else `sig=""`;
     *   - [AuthMode.REQUIRED]  → always sign.
     *
     * [hasUsableKey] decides "is there a real PSK" — an empty or the shipped
     * placeholder key counts as absent so an unconfigured device under
     * `optional` sends `sig=""` rather than a signature nobody can verify.
     */
    fun buildWithMode(
        psk: String, authMode: AuthMode, type: String, from: String, to: String,
        payload: Json,
        msgId: String = UUID.randomUUID().toString(),
        ts: Long = nowMs(),
        keyMode: KeyMode = KeyMode.GLOBAL,
    ): Json.Obj {
        val v = PROTOCOL_VERSION
        val sig = when (authMode) {
            AuthMode.OPEN -> ""
            AuthMode.OPTIONAL -> if (hasUsableKey(psk)) sign(psk, v, type, msgId, ts, from, to, payload, keyMode) else ""
            AuthMode.REQUIRED -> sign(psk, v, type, msgId, ts, from, to, payload, keyMode)
        }
        return assemble(v, type, msgId, ts, from, to, sig, payload)
    }

    /**
     * Build an envelope signed with an **explicit device_key** — the dk-only end
     * path (§17.4). The end holds its own `device_key` (from the §15 QR's `dk`)
     * and never the PSK, so it cannot run [buildWithMode]'s PSK derivation; it
     * signs directly. `open` still emits `sig=""`; `optional`/`required` sign
     * with [deviceKey] (which the caller derived once at pairing time as
     * `HMAC(PSK, from)`).
     */
    fun buildWithDeviceKey(
        deviceKey: ByteArray, authMode: AuthMode, type: String, from: String, to: String,
        payload: Json,
        msgId: String = UUID.randomUUID().toString(),
        ts: Long = nowMs(),
    ): Json.Obj {
        val v = PROTOCOL_VERSION
        val sig = when (authMode) {
            AuthMode.OPEN -> ""
            AuthMode.OPTIONAL, AuthMode.REQUIRED ->
                signWithKey(deviceKey, v, type, msgId, ts, from, to, payload)
        }
        return assemble(v, type, msgId, ts, from, to, sig, payload)
    }

    private fun assemble(
        v: Int, type: String, msgId: String, ts: Long,
        from: String, to: String, sig: String, payload: Json,
    ): Json.Obj = jsonObj {
        put("v", v)
        put("type", type)
        put("msg_id", msgId)
        put("ts", ts)
        put("from", from)
        put("to", to)
        put("sig", sig)
        put("payload", payload)
    }

    /** True when [psk] is a real preshared key (non-blank and not the shipped
     *  placeholder). Used by [buildWithMode] / verify gating under `optional`. */
    fun hasUsableKey(psk: String): Boolean =
        psk.isNotBlank() && psk != PLACEHOLDER_PSK


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
        /**
         * True only when this frame's signature was actually recomputed and
         * matched (i.e. `mustVerify` was true and the HMAC check passed).
         * `open` mode and empty-sig `optional` frames are accepted but arrive
         * with `authed=false`. Security-sensitive handlers (e.g. §22
         * `update_app`, which can root-install an APK) MUST require
         * `authed==true` so an unauthenticated box can never be remotely
         * reflashed over the LAN.
         */
        val authed: Boolean = false,
    )

    enum class Reason { OK, SHAPE, SIG, STALE, DUP }

    data class VerifyResult(val ok: Boolean, val reason: Reason, val parsed: Parsed?)

    /**
     * Validate an inbound envelope per §3, gated by [authMode] per §13 and keyed
     * per [keyMode] (§17):
     *   1. shape check (all fields present, payload is object),
     *   2. signature check — **mode-dependent**:
     *        - [AuthMode.REQUIRED]: recompute + constant-time compare (drop on fail),
     *        - [AuthMode.OPTIONAL]: verify only when `sig` is non-empty,
     *        - [AuthMode.OPEN]: skip (accept any/empty `sig`),
     *   3. freshness window (120s on first connect, else 30s) — **always**,
     *   4. replay dedup via [replay] (5-minute LRU) — **always**.
     *
     * §17 key selection for the recompute:
     *   - [KeyMode.GLOBAL]:  HMAC key = the PSK bytes (v1.2);
     *   - [KeyMode.DERIVED]: HMAC key = `HMAC(PSK, from)` of the frame's **own**
     *     `from`, so a frame signed with identity-A's key but stamped `from=B`
     *     recomputes against B's key and is rejected — the §17.5 leak-isolation
     *     contract. broker holds the PSK and derives per-`from` statelessly.
     *
     * [verifyKeyFor] is the **dk-only** fallback (§17.4): an end that holds only
     * its own `device_key` (never the PSK) cannot derive other identities' keys.
     * When set and the PSK is not usable, it supplies the raw verify key for a
     * given `from` (e.g. a stored broker key for `from="broker"`), or null to
     * **fail closed** — an unverifiable signed frame is dropped, never accepted.
     *
     * Default [authMode] is [AuthMode.REQUIRED] / [keyMode] is [KeyMode.GLOBAL]
     * so this stays a strict v1.2 verifier for callers that don't opt in.
     */
    fun verify(
        psk: String,
        raw: String,
        replay: ReplayCache? = null,
        firstConnect: Boolean = false,
        now: Long = nowMs(),
        authMode: AuthMode = AuthMode.REQUIRED,
        keyMode: KeyMode = KeyMode.GLOBAL,
        verifyKeyFor: ((from: String) -> ByteArray?)? = null,
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

        // §13 signature gating by auth mode. `open` skips entirely; `optional`
        // verifies only a non-empty sig; `required` always verifies.
        val mustVerify = when (authMode) {
            AuthMode.OPEN -> false
            AuthMode.OPTIONAL -> sig.isNotEmpty()
            AuthMode.REQUIRED -> true
        }
        if (mustVerify) {
            // §17 key resolution. Prefer the PSK path (broker-style: can derive
            // any `from`); fall back to the dk-only resolver; else fail closed.
            val key: ByteArray? = when (keyMode) {
                KeyMode.GLOBAL -> psk.toByteArray(Charsets.UTF_8)
                KeyMode.DERIVED ->
                    if (hasUsableKey(psk)) deriveKey(psk, from)
                    else verifyKeyFor?.invoke(from)
            }
            if (key == null) return VerifyResult(false, Reason.SIG, null)
            val expected = hmacSha256Hex(key, signingString(v, type, msgId, ts, from, to, payloadObj))
            if (!constantTimeEquals(expected, sig)) {
                return VerifyResult(false, Reason.SIG, null)
            }
        }
        // `authed` is true iff we actually recomputed + matched the HMAC above.
        // open / empty-sig-optional frames pass verification but are NOT authed.
        val authed = mustVerify

        val window = if (firstConnect) FIRST_CONNECT_WINDOW_MS else FRESH_WINDOW_MS
        if (Math.abs(now - ts) > window) {
            return VerifyResult(false, Reason.STALE, null)
        }

        if (replay != null && replay.seen(msgId, now)) {
            return VerifyResult(false, Reason.DUP, null)
        }

        val parsed = Parsed(v, type, msgId, ts, from, to, sig, payloadObj, payloadObj, authed)
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

    /**
     * Decode a hex string to raw bytes, or null if it isn't valid even-length
     * hex. Used to turn a pairing QR's `dk`/`bk` (device_key hex, §17.4) back
     * into the raw HMAC key bytes.
     */
    fun hexToBytes(hex: String): ByteArray? {
        val s = hex.trim()
        if (s.isEmpty() || s.length % 2 != 0) return null
        val out = ByteArray(s.length / 2)
        var i = 0
        while (i < s.length) {
            val hi = Character.digit(s[i], 16)
            val lo = Character.digit(s[i + 1], 16)
            if (hi < 0 || lo < 0) return null
            out[i / 2] = ((hi shl 4) or lo).toByte()
            i += 2
        }
        return out
    }

    private val HEX = "0123456789abcdef".toCharArray()
}
