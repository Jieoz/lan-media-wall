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

    // --- guardrail 4: install command shape -----------------------------

    @Test
    fun helperCommand_targets_provisioned_setuid_helper() {
        val c = RootInstaller.helperCommand(
            "com.jieoz.lanmediawall.player", "/data/data/com.jieoz.lanmediawall.player/cache/update/x.apk")
        assertEquals("/data/local/tmp/lmw_root_helper", c[0])
        assertEquals("com.jieoz.lanmediawall.player", c[1])
        assertEquals("/data/data/com.jieoz.lanmediawall.player/cache/update/x.apk", c[2])
    }

    @Test
    fun rebootCommand_targets_provisioned_setuid_helper() {
        val c = RootInstaller.rebootCommand()
        assertEquals("/data/local/tmp/lmw_root_helper", c[0])
        assertEquals("reboot", c[1])
        assertEquals(2, c.size)
    }

    @Test
    fun installScript_targets_data_app_and_reboots() {
        val s = RootInstaller.installScript(
            "com.jieoz.lanmediawall.player", "/data/data/pkg/cache/update/x.apk")
        // copies into the package-scanner-adopted /data/app slot...
        assertTrue(s.contains("/data/app/com.jieoz.lanmediawall.player-1.apk"))
        // ...world-readable so the boot scanner can read it...
        assertTrue(s.contains("chmod 644"))
        // ...and reboots to trigger adoption (the only path that works on 4.4 boxes).
        assertTrue(s.trimEnd().endsWith("reboot"))
        // fail-fast so a bad cp doesn't reboot into a half-copied apk.
        assertTrue(s.startsWith("set -e"))
    }

    @Test
    fun installScript_single_quotes_paths() {
        // a path with a space must stay one argument (defense-in-depth even
        // though our real cache path is ASCII/space-free).
        val s = RootInstaller.installScript("pkg", "/tmp/a b/x.apk")
        assertTrue(s.contains("'/tmp/a b/x.apk'"))
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
