package com.jieoz.lanmediawall.player.net

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * §17 derived per-endpoint keys: derivation, key_mode-selected sign/verify,
 * key_mode negotiation, and the §17.5 leak-isolation negative test.
 *
 * The signing-string layout, canonical JSON, ts window and msg_id dedup are
 * unchanged from §3 — these tests only exercise the **key choice** (global PSK
 * vs per-identity device_key) and the cross-end byte-for-byte invariants.
 *
 * The hex vectors are produced by the *actual* broker Python implementation
 * (broker/envelope.py, broker/tests/test_derived_keys.py) with the same PSK, so
 * a mismatch here means the Android player cannot interoperate under derived
 * keys.
 */
class DerivedKeyTest {

    // Same 64-hex PSK the broker derived-key tests use, so the vectors below are
    // directly comparable across ends.
    private val psk = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    // --- §17.2 derive_key: HMAC(PSK, identity), 32 raw bytes -----------------

    @Test
    fun deriveKey_is_hmac_psk_identity_32_bytes() {
        val dk = Envelope.deriveKey(psk, "player:win-lobby-01")
        assertEquals(32, dk.size)
        // Byte-exact against the Python reference (no hex round-trip, §17.5).
        assertEquals(
            "4f96c869136abe1bfc1ba7751d9e4e214a6ef95788bf0d1e2de1b3b82fb858b4",
            dk.toHex(),
        )
    }

    @Test
    fun deriveKey_broker_identity_vector() {
        assertEquals(
            "0ddc630374483887939f25af2282e96b027726aa06339ee5384d759f2607aca2",
            Envelope.deriveKey(psk, "broker").toHex(),
        )
    }

    @Test
    fun deriveKey_per_identity_differs() {
        assertFalse(Envelope.deriveKey(psk, "player:a").contentEquals(Envelope.deriveKey(psk, "player:b")))
    }

    @Test
    fun deriveKey_identity_is_byte_exact_no_normalization() {
        // §17.5: identity participates verbatim — no lowercasing / trimming.
        assertFalse(
            Envelope.deriveKey(psk, "player:Win-01")
                .contentEquals(Envelope.deriveKey(psk, "player:win-01")),
        )
        assertFalse(
            Envelope.deriveKey(psk, "broker ").contentEquals(Envelope.deriveKey(psk, "broker")),
        )
    }

    // --- KeyMode.parse: missing/unknown -> GLOBAL (§17.3) --------------------

    @Test
    fun keyMode_parse_defaults_to_global() {
        assertEquals(KeyMode.GLOBAL, KeyMode.parse(null))
        assertEquals(KeyMode.GLOBAL, KeyMode.parse(""))
        assertEquals(KeyMode.GLOBAL, KeyMode.parse("garbage"))
        assertEquals(KeyMode.DERIVED, KeyMode.parse("DERIVED"))
        assertEquals(KeyMode.GLOBAL, KeyMode.parse(" Global "))
    }

    // --- derived sign vectors (cross-end, byte-exact) -----------------------

    @Test
    fun derived_player_status_sig_matches_python() {
        val payload = jsonObj { put("state", "playing") }
        val sig = Envelope.sign(
            psk, 1, "status", "m1", 1750000000000L,
            "player:and-1", "broker", payload, KeyMode.DERIVED,
        )
        assertEquals("d492e025f62b3b48c1efc901533bf281f38b40b3615810ba63ef206696a1787f", sig)
    }

    @Test
    fun global_player_status_sig_matches_python_and_differs_from_derived() {
        val payload = jsonObj { put("state", "playing") }
        val global = Envelope.sign(
            psk, 1, "status", "m1", 1750000000000L,
            "player:and-1", "broker", payload, KeyMode.GLOBAL,
        )
        assertEquals("9d3b4511f0086eb15cdb1f08914be2715760c2b8fd7ce59030ab38cf1c4cc680", global)
        val derived = Envelope.sign(
            psk, 1, "status", "m1", 1750000000000L,
            "player:and-1", "broker", payload, KeyMode.DERIVED,
        )
        assertNotEquals(global, derived)
    }

    @Test
    fun derived_broker_downlink_sig_matches_python() {
        // §17.5: broker downlink frames are from="broker", keyed by HMAC(PSK,"broker").
        val payload = jsonObj { put("play_at", 123) }
        val sig = Envelope.sign(
            psk, 1, "play_at", "m4", 1750000003000L,
            "broker", "group:lobby", payload, KeyMode.DERIVED,
        )
        assertEquals("06ef903c59e91b42066c3927c829ece57ed5e2adf113fabf7da23bef452a0b81", sig)
    }

    @Test
    fun signWithKey_equals_derived_sign() {
        // A dk-only end signs with its stored device_key directly; that must be
        // byte-identical to deriving HMAC(PSK, from) on the spot.
        val from = "player:and-1"
        val payload = jsonObj { put("state", "playing") }
        val dk = Envelope.deriveKey(psk, from)
        val direct = Envelope.signWithKey(dk, 1, "status", "m1", 1750000000000L, from, "broker", payload)
        val derived = Envelope.sign(psk, 1, "status", "m1", 1750000000000L, from, "broker", payload, KeyMode.DERIVED)
        assertEquals(derived, direct)
    }

    // --- build → verify round-trips under each key_mode ---------------------

    @Test
    fun derived_build_verify_roundtrip() {
        val payload = jsonObj { put("online", true) }
        val env = Envelope.build(psk, "status", "player:and-1", "broker", payload, keyMode = KeyMode.DERIVED)
        val r = Envelope.verify(
            psk, Envelope.toWire(env), firstConnect = true,
            authMode = AuthMode.REQUIRED, keyMode = KeyMode.DERIVED,
        )
        assertTrue(r.ok)
        assertEquals(Envelope.Reason.OK, r.reason)
    }

    @Test
    fun cross_key_mode_verify_fails() {
        val payload = jsonObj { put("x", 1) }
        val derivedEnv = Envelope.build(psk, "status", "player:p", "broker", payload, keyMode = KeyMode.DERIVED)
        // Same bytes verify under derived, reject under global.
        assertTrue(verifyOk(derivedEnv, KeyMode.DERIVED))
        assertFalse(verifyOk(derivedEnv, KeyMode.GLOBAL))
        val globalEnv = Envelope.build(psk, "status", "player:p", "broker", payload, keyMode = KeyMode.GLOBAL)
        assertTrue(verifyOk(globalEnv, KeyMode.GLOBAL))
        assertFalse(verifyOk(globalEnv, KeyMode.DERIVED))
    }

    @Test
    fun buildWithDeviceKey_verifies_under_derived() {
        // dk-only outbound (player holds only its device_key) is verifiable by a
        // PSK-holding broker (or our verify) under derived.
        val from = "player:dk-only"
        val dk = Envelope.deriveKey(psk, from)
        val env = Envelope.buildWithDeviceKey(dk, AuthMode.REQUIRED, "status", from, "broker", jsonObj { put("x", 1) })
        assertTrue(verifyOk(env, KeyMode.DERIVED))
    }

    // --- §17.5 LEAK ISOLATION (contract-compliance evidence) ----------------

    @Test
    fun leak_isolation_signed_as_A_claiming_from_B_is_rejected() {
        // Sign with identity-A's device_key but stamp from=identity-B. The
        // verifier derives the key from the *claimed* from (B), so the recomputed
        // sig won't match — the frame MUST be dropped. A leaked player-A key
        // cannot forge player-B.
        val identA = "player:leaked-A"
        val identB = "player:victim-B"
        val keyA = Envelope.deriveKey(psk, identA)
        val payload = jsonObj { put("cmd", "stop") }
        // Forge: HMAC with A's key, but stamp from=B.
        val forgedSig = Envelope.signWithKey(keyA, 1, "stop", "x1", 1000L, identB, "group:lobby", payload)
        val forged = jsonObj {
            put("v", 1); put("type", "stop"); put("msg_id", "x1"); put("ts", 1000L)
            put("from", identB); put("to", "group:lobby"); put("sig", forgedSig)
            put("payload", payload)
        }
        val r = Envelope.verify(
            psk, Envelope.toWire(forged), now = 1000L, firstConnect = true,
            authMode = AuthMode.REQUIRED, keyMode = KeyMode.DERIVED,
        )
        assertFalse(r.ok)
        assertEquals(Envelope.Reason.SIG, r.reason)
    }

    @Test
    fun leak_isolation_forging_broker_from_player_key_rejected() {
        // A leaked player key must not be able to impersonate the broker.
        val playerKey = Envelope.deriveKey(psk, "player:leaked-A")
        val payload = jsonObj { put("play_at", 9) }
        val forgedSig = Envelope.signWithKey(playerKey, 1, "play_at", "m", 1L, "broker", "group:lobby", payload)
        val forged = jsonObj {
            put("v", 1); put("type", "play_at"); put("msg_id", "m"); put("ts", 1L)
            put("from", "broker"); put("to", "group:lobby"); put("sig", forgedSig)
            put("payload", payload)
        }
        val r = Envelope.verify(
            psk, Envelope.toWire(forged), now = 1L, firstConnect = true,
            authMode = AuthMode.REQUIRED, keyMode = KeyMode.DERIVED,
        )
        assertFalse(r.ok)
        assertEquals(Envelope.Reason.SIG, r.reason)
    }

    // --- dk-only verify resolver + fail-closed (§17.4, NOTES_TO_UPSTREAM §4) -

    @Test
    fun dkOnly_verifies_broker_downlink_with_broker_key_resolver() {
        // A dk-only player (no PSK) verifies a broker frame against a stored
        // broker device_key supplied via the resolver.
        val brokerKey = Envelope.deriveKey(psk, "broker")
        val payload = jsonObj { put("play_at", 123) }
        val env = Envelope.build(psk, "play_at", "broker", "group:lobby", payload, keyMode = KeyMode.DERIVED)
        val r = Envelope.verify(
            Settings_DEFAULT_PSK, Envelope.toWire(env), now = env.ts(), firstConnect = true,
            authMode = AuthMode.REQUIRED, keyMode = KeyMode.DERIVED,
            verifyKeyFor = { from -> if (from == "broker") brokerKey else null },
        )
        assertTrue(r.ok)
    }

    @Test
    fun dkOnly_fails_closed_when_no_key_for_identity() {
        // No PSK, no resolver key for from="broker" → unverifiable signed frame
        // is dropped (never accepted). This is the security-critical default.
        val payload = jsonObj { put("play_at", 123) }
        val env = Envelope.build(psk, "play_at", "broker", "group:lobby", payload, keyMode = KeyMode.DERIVED)
        val r = Envelope.verify(
            Settings_DEFAULT_PSK, Envelope.toWire(env), now = env.ts(), firstConnect = true,
            authMode = AuthMode.REQUIRED, keyMode = KeyMode.DERIVED,
            verifyKeyFor = { _ -> null },
        )
        assertFalse(r.ok)
        assertEquals(Envelope.Reason.SIG, r.reason)
    }

    // --- open mode: key_mode is moot ----------------------------------------

    @Test
    fun open_mode_ignores_key_mode() {
        val env = Envelope.buildWithMode(
            psk, AuthMode.OPEN, "stop", "player:p", "broker", jsonObj { put("x", 1) },
            keyMode = KeyMode.DERIVED,
        )
        // open never verifies regardless of key_mode (§17.3); sig is empty.
        assertEquals("", (env.entries["sig"] as Json.Str).value)
        assertTrue(verifyOk(env, KeyMode.DERIVED, AuthMode.OPEN))
        assertTrue(verifyOk(env, KeyMode.GLOBAL, AuthMode.OPEN))
    }

    @Test
    fun hexToBytes_roundtrips_device_key() {
        val dk = Envelope.deriveKey(psk, "player:and-1")
        val back = Envelope.hexToBytes(dk.toHex())
        assertArrayEquals(dk, back)
        assertNull(Envelope.hexToBytes("xyz"))
        assertNull(Envelope.hexToBytes("abc")) // odd length
    }

    // --- helpers ------------------------------------------------------------

    private val Settings_DEFAULT_PSK = "CHANGE_ME_32_BYTE_RANDOM_PRESHARED_KEY"

    private fun Json.Obj.ts(): Long = (entries["ts"] as Json.Num).raw.toLong()

    private fun verifyOk(
        env: Json.Obj,
        keyMode: KeyMode,
        authMode: AuthMode = AuthMode.REQUIRED,
    ): Boolean = Envelope.verify(
        psk, Envelope.toWire(env), now = env.ts(), firstConnect = true,
        authMode = authMode, keyMode = keyMode,
    ).ok

    private fun ByteArray.toHex(): String {
        val sb = StringBuilder(size * 2)
        for (b in this) {
            val v = b.toInt() and 0xFF
            sb.append("0123456789abcdef"[v ushr 4])
            sb.append("0123456789abcdef"[v and 0xF])
        }
        return sb.toString()
    }
}
