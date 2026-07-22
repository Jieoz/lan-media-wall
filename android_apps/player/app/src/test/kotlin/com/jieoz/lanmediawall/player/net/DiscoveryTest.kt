package com.jieoz.lanmediawall.player.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DiscoveryTest {
    @Test
    fun broker_client_optional_without_key_emits_unsigned_announce_without_throwing() {
        val responder = Discovery(
            psk = "",
            deviceId = "and-test",
            deviceName = "test",
            ip = "10.0.0.2",
            brokerHint = "10.0.0.1:8770",
            authMode = AuthMode.OPTIONAL,
            keyMode = KeyMode.GLOBAL,
        )

        val result = Envelope.verify(
            "",
            String(responder.makeAnnounce()!!, Charsets.UTF_8),
            firstConnect = true,
            authMode = AuthMode.OPTIONAL,
            keyMode = KeyMode.GLOBAL,
        )

        assertTrue(result.ok)
        assertEquals("announce", result.parsed!!.type)
        assertEquals("", result.parsed!!.sig)
    }

    @Test
    fun broker_client_optional_with_key_still_signs_announce() {
        val responder = Discovery(
            psk = "0123456789abcdef0123456789abcdef",
            deviceId = "and-test",
            deviceName = "test",
            ip = "10.0.0.2",
            brokerHint = "10.0.0.1:8770",
            authMode = AuthMode.OPTIONAL,
            keyMode = KeyMode.GLOBAL,
        )

        val result = Envelope.verify(
            "0123456789abcdef0123456789abcdef",
            String(responder.makeAnnounce()!!, Charsets.UTF_8),
            firstConnect = true,
            authMode = AuthMode.OPTIONAL,
            keyMode = KeyMode.GLOBAL,
        )

        assertTrue(result.ok)
        assertTrue(result.parsed!!.sig.isNotEmpty())
    }

    @Test
    fun broker_client_open_without_key_emits_unsigned_announce_without_throwing() {
        val responder = Discovery(
            psk = "",
            deviceId = "and-test",
            deviceName = "test",
            ip = "10.0.0.2",
            brokerHint = "10.0.0.1:8770",
            authMode = AuthMode.OPEN,
            keyMode = KeyMode.DERIVED,
        )

        val result = Envelope.verify(
            "",
            String(responder.makeAnnounce()!!, Charsets.UTF_8),
            firstConnect = true,
            authMode = AuthMode.OPEN,
            keyMode = KeyMode.DERIVED,
        )

        assertTrue(result.ok)
        assertEquals("", result.parsed!!.sig)
    }

    @Test
    fun broker_client_required_derived_device_key_signs_announce() {
        val deviceKey = ByteArray(32) { (it + 1).toByte() }
        val responder = Discovery(
            psk = "",
            deviceId = "and-test",
            deviceName = "test",
            ip = "10.0.0.2",
            brokerHint = "10.0.0.1:8770",
            authMode = AuthMode.REQUIRED,
            keyMode = KeyMode.DERIVED,
            deviceKey = deviceKey,
        )

        val result = Envelope.verify(
            "",
            String(responder.makeAnnounce()!!, Charsets.UTF_8),
            firstConnect = true,
            authMode = AuthMode.REQUIRED,
            keyMode = KeyMode.DERIVED,
            verifyKeyFor = { from -> if (from == "player:and-test") deviceKey else null },
        )

        assertTrue(result.ok)
        assertTrue(result.parsed!!.authed)
    }

    @Test
    fun required_global_without_psk_fails_closed_without_hmac_exception() {
        val responder = Discovery(
            psk = "",
            deviceId = "and-test",
            deviceName = "test",
            ip = "10.0.0.2",
            brokerHint = "10.0.0.1:8770",
            authMode = AuthMode.REQUIRED,
            keyMode = KeyMode.GLOBAL,
        )

        assertEquals(null, responder.makeAnnounce())
    }

    @Test
    fun required_global_with_psk_still_signs_announce() {
        val psk = "0123456789abcdef0123456789abcdef"
        val responder = Discovery(
            psk = psk,
            deviceId = "and-test",
            deviceName = "test",
            ip = "10.0.0.2",
            brokerHint = "10.0.0.1:8770",
            authMode = AuthMode.REQUIRED,
            keyMode = KeyMode.GLOBAL,
        )

        val result = Envelope.verify(
            psk,
            String(responder.makeAnnounce()!!, Charsets.UTF_8),
            firstConnect = true,
            authMode = AuthMode.REQUIRED,
            keyMode = KeyMode.GLOBAL,
        )

        assertTrue(result.ok)
        assertTrue(result.parsed!!.authed)
    }

    @Test
    fun required_without_any_key_fails_closed_without_hmac_exception() {
        val responder = Discovery(
            psk = "",
            deviceId = "and-test",
            deviceName = "test",
            ip = "10.0.0.2",
            brokerHint = "10.0.0.1:8770",
            authMode = AuthMode.REQUIRED,
            keyMode = KeyMode.DERIVED,
            deviceKey = null,
        )

        assertEquals(null, responder.makeAnnounce())
    }
}
