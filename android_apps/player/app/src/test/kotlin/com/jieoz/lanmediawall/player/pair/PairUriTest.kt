package com.jieoz.lanmediawall.player.pair

import com.jieoz.lanmediawall.player.net.AuthMode
import com.jieoz.lanmediawall.player.net.KeyMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * §15.1 + §17.4 pairing-URI parsing: the no-typing entry ticket. Covers the
 * v1.3 split between `global` (carries `psk`) and `derived` (carries the end's
 * own `dk` + `id`, never the PSK), plus `open` (no key) and forward-compat `bk`.
 */
class PairUriTest {

    @Test
    fun global_mode_carries_psk_no_derived_fields() {
        val uri = "lmw://pair?host=192.168.1.10&port=8770&group=lobby" +
            "&mode=required&key_mode=global&psk=deadbeef&wss=0"
        val p = PairUri.parse(uri)!!
        assertEquals("192.168.1.10", p.host)
        assertEquals(8770, p.port)
        assertEquals("lobby", p.group)
        assertEquals(AuthMode.REQUIRED, p.mode)
        assertEquals(KeyMode.GLOBAL, p.keyMode)
        assertEquals("deadbeef", p.psk)
        assertNull(p.deviceKeyHex)
        assertNull(p.identity)
        assertNull(p.brokerKeyHex)
    }

    @Test
    fun missing_key_mode_defaults_to_global() {
        val p = PairUri.parse("lmw://pair?host=h&mode=required&psk=abcd")!!
        assertEquals(KeyMode.GLOBAL, p.keyMode)
        assertEquals("abcd", p.psk)
    }

    @Test
    fun derived_mode_carries_dk_and_id_never_psk() {
        val uri = "lmw://pair?host=10.0.0.5&mode=required&key_mode=derived" +
            "&dk=4f96c869136abe1b&id=player%3Awin-lobby-01"
        val p = PairUri.parse(uri)!!
        assertEquals(KeyMode.DERIVED, p.keyMode)
        assertEquals("4f96c869136abe1b", p.deviceKeyHex)
        // id is URL-encoded (player:win-lobby-01) and round-trips verbatim.
        assertEquals("player:win-lobby-01", p.identity)
        assertNull("derived URI must not surface a PSK", p.psk)
    }

    @Test
    fun derived_with_stray_psk_still_drops_psk_when_dk_present() {
        // §17.4: an end in derived mode must never retain the PSK.
        val uri = "lmw://pair?host=h&mode=required&key_mode=derived" +
            "&dk=abcd&id=player%3Ap&psk=shouldbeignored"
        val p = PairUri.parse(uri)!!
        assertEquals("abcd", p.deviceKeyHex)
        assertNull(p.psk)
    }

    @Test
    fun derived_optional_broker_key_bk_parsed() {
        val uri = "lmw://pair?host=h&mode=required&key_mode=derived" +
            "&dk=aa&id=player%3Ap&bk=0ddc6303"
        val p = PairUri.parse(uri)!!
        assertEquals("0ddc6303", p.brokerKeyHex)
    }

    @Test
    fun open_mode_carries_no_key_material() {
        val uri = "lmw://pair?host=h&mode=open&key_mode=derived&psk=x&dk=y&id=player%3Ap"
        val p = PairUri.parse(uri)!!
        assertEquals(AuthMode.OPEN, p.mode)
        assertNull(p.psk)
        assertNull(p.deviceKeyHex)
        assertNull(p.identity)
    }

    @Test
    fun unknown_params_ignored_and_chinese_name_decoded() {
        val uri = "lmw://pair?host=h&mode=required&key_mode=derived&dk=aa&id=player%3Ap" +
            "&name=%E5%A4%A7%E5%8E%85%E5%B7%A6%E5%B1%8F&future=whatever"
        val p = PairUri.parse(uri)!!
        assertEquals("大厅左屏", p.name)
        assertEquals("aa", p.deviceKeyHex)
    }

    @Test
    fun non_pair_uri_rejected() {
        assertNull(PairUri.parse("https://example.com"))
        assertNull(PairUri.parse("lmw://other?host=h"))
        assertNull(PairUri.parse("lmw://pair?port=8770")) // no host
        assertNull(PairUri.parse(null))
    }
}
