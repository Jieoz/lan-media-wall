package com.jieoz.lanmediawall.player.update

import com.jieoz.lanmediawall.player.net.AuthMode
import com.jieoz.lanmediawall.player.net.Envelope
import com.jieoz.lanmediawall.player.net.jsonObj
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * §23 remote self-update security tests. These lock down the FOUR guardrails
 * so a regression can never quietly open a "root-install any APK over the LAN"
 * hole:
 *   1. authorized frame only (Envelope.authed or accepted local P2P link)
 *   2. strictly-newer versionCode (no downgrade / replay)
 *   3. url + shape-checked sha256 present
 *   4. install command shape (same-signer is platform-enforced at boot scan)
 */
class UpdateGuardTest {

    private val goodSha = "a".repeat(64)
    private val url = "http://broker:8773/media/$goodSha.apk"

    // --- guardrail 1: authorized only ------------------------------------

    @Test
    fun rejects_unauthorized_frame() {
        val d = UpdateGuard.decide(
            authed = false,
            currentVersionCode = 10,
            targetVersionCode = 11,
            url = url,
            sha256 = goodSha,
        )
        assertTrue(d is UpdateGuard.Decision.Reject)
        assertEquals("unauthorized", (d as UpdateGuard.Decision.Reject).reason)
    }

    @Test
    fun accepts_authenticated_and_newer() {
        val d = UpdateGuard.decide(
            authed = true,
            currentVersionCode = 10,
            targetVersionCode = 11,
            url = url,
            sha256 = goodSha,
        )
        assertTrue(d is UpdateGuard.Decision.Proceed)
    }

    @Test
    fun accepts_local_p2p_direct_update_without_hmac() {
        val d = UpdateGuard.decide(
            authed = false,
            p2pLocal = true,
            currentVersionCode = 10,
            targetVersionCode = 11,
            url = url,
            sha256 = goodSha,
        )
        assertTrue(d is UpdateGuard.Decision.Proceed)
    }

    // --- guardrail 2: monotonic versionCode -----------------------------

    @Test
    fun rejects_same_version() {
        val d = UpdateGuard.decide(
            authed = true,
            currentVersionCode = 11,
            targetVersionCode = 11,
            url = url,
            sha256 = goodSha,
        )
        assertTrue(d is UpdateGuard.Decision.Reject)
        assertTrue((d as UpdateGuard.Decision.Reject).reason.startsWith("not-newer"))
    }

    @Test
    fun rejects_downgrade() {
        val d = UpdateGuard.decide(
            authed = true,
            currentVersionCode = 12,
            targetVersionCode = 11,
            url = url,
            sha256 = goodSha,
        )
        assertTrue(d is UpdateGuard.Decision.Reject)
        assertTrue((d as UpdateGuard.Decision.Reject).reason.startsWith("not-newer"))
    }

    @Test
    fun rejects_missing_version_code() {
        val d = UpdateGuard.decide(
            authed = true,
            currentVersionCode = 10,
            targetVersionCode = null,
            url = url,
            sha256 = goodSha,
        )
        assertEquals("missing-version-code", (d as UpdateGuard.Decision.Reject).reason)
    }

    // --- guardrail 3: url + sha256 shape --------------------------------

    @Test
    fun rejects_missing_url() {
        val d = UpdateGuard.decide(
            authed = true,
            currentVersionCode = 10,
            targetVersionCode = 11,
            url = null,
            sha256 = goodSha,
        )
        assertEquals("missing-url", (d as UpdateGuard.Decision.Reject).reason)
    }

    @Test
    fun rejects_blank_url() {
        val d = UpdateGuard.decide(
            authed = true,
            currentVersionCode = 10,
            targetVersionCode = 11,
            url = "   ",
            sha256 = goodSha,
        )
        assertEquals("missing-url", (d as UpdateGuard.Decision.Reject).reason)
    }

    @Test
    fun rejects_bad_sha256_length() {
        val d = UpdateGuard.decide(
            authed = true,
            currentVersionCode = 10,
            targetVersionCode = 11,
            url = url,
            sha256 = "abc123",
        )
        assertEquals("bad-sha256", (d as UpdateGuard.Decision.Reject).reason)
    }

    @Test
    fun rejects_non_hex_sha256() {
        val d = UpdateGuard.decide(
            authed = true,
            currentVersionCode = 10,
            targetVersionCode = 11,
            url = url,
            sha256 = "z".repeat(64),
        )
        assertEquals("bad-sha256", (d as UpdateGuard.Decision.Reject).reason)
    }

    @Test
    fun accepts_uppercase_hex_sha256() {
        val d = UpdateGuard.decide(
            authed = true,
            currentVersionCode = 10,
            targetVersionCode = 11,
            url = url,
            sha256 = "A".repeat(64),
        )
        assertTrue(d is UpdateGuard.Decision.Proceed)
    }

    // --- guardrail 4: daemon install request shape ----------------------
    // (The full wire protocol + probe parsing is covered by
    //  RootDaemonProtocolTest; here we only assert the install target the app
    //  will ever ask the daemon to install is the single canonical cache path.)

    @Test
    fun canonical_install_path_is_the_only_install_target() {
        assertEquals(
            "/data/data/com.jieoz.lanmediawall.player/cache/update/" +
                "com.jieoz.lanmediawall.player-update.apk",
            RootDaemonProtocol.CANONICAL_APK_PATH,
        )
        assertEquals(
            "INSTALL ${RootDaemonProtocol.CANONICAL_APK_PATH}",
            RootDaemonProtocol.installRequest(RootDaemonProtocol.CANONICAL_APK_PATH),
        )
    }

    // --- Envelope.authed semantics (guardrail 1 substrate) --------------

    @Test
    fun authed_false_in_open_mode() {
        // open mode accepts any frame but never marks it authed.
        val env = Envelope.build("psk", "update_app", "controller:c", "player:p",
            jsonObj { put("version_code", 11) })
        val raw = Envelope.toWire(env)
        val r = Envelope.verify("psk", raw, authMode = AuthMode.OPEN)
        assertTrue(r.ok)
        assertFalse("open-mode frame must not be authed", r.parsed!!.authed)
    }

    @Test
    fun authed_true_when_required_and_signature_valid() {
        val env = Envelope.build("realkey", "update_app", "controller:c", "player:p",
            jsonObj { put("version_code", 11) })
        val raw = Envelope.toWire(env)
        val r = Envelope.verify("realkey", raw, authMode = AuthMode.REQUIRED)
        assertTrue(r.ok)
        assertTrue("verified required frame must be authed", r.parsed!!.authed)
    }

    @Test
    fun authed_false_for_empty_sig_optional() {
        // optional mode with an empty sig is accepted but not authenticated —
        // so broker-mode update_app on such a frame is rejected by decide().
        val env = Envelope.buildWithMode("realkey", AuthMode.OPEN, "update_app",
            "controller:c", "player:p", jsonObj { put("version_code", 11) })
        val raw = Envelope.toWire(env)
        val r = Envelope.verify("realkey", raw, authMode = AuthMode.OPTIONAL)
        assertTrue(r.ok)
        assertFalse(r.parsed!!.authed)
    }
}
