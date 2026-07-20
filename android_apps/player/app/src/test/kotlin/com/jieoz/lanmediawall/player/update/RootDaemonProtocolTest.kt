package com.jieoz.lanmediawall.player.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure protocol tests for the root-daemon local-socket client (§root-daemon).
 * These pin the exact line protocol + probe parsing the [RootInstaller] client
 * speaks to `scripts/lmw_root_daemon.c`, with no device/socket needed:
 *   requests: PROBE | REBOOT | INSTALL <abs-path>
 *   probe-ready iff response starts "ready " AND reports daemon_euid=0
 */
class RootDaemonProtocolTest {

    @Test
    fun socket_is_abstract_named() {
        // Must match LMW_SOCKET_NAME in lmw_root_daemon.c (abstract namespace).
        assertEquals("lmw_root_daemon", RootDaemonProtocol.SOCKET_NAME)
    }

    @Test
    fun canonical_apk_path_is_single_fixed_file_under_cache_update() {
        val p = RootDaemonProtocol.CANONICAL_APK_PATH
        assertEquals(
            "/data/data/com.jieoz.lanmediawall.player/cache/update/" +
                "com.jieoz.lanmediawall.player-update.apk",
            p,
        )
    }

    @Test
    fun probe_request_is_bare_verb() {
        assertEquals("PROBE", RootDaemonProtocol.probeRequest())
    }

    @Test
    fun reboot_request_is_bare_verb() {
        assertEquals("REBOOT", RootDaemonProtocol.rebootRequest())
    }

    @Test
    fun restart_app_request_is_bare_verb() {
        // §restart-semantics: normal restart is app-only, a distinct verb from the
        // whole-device REBOOT. Must match CMD_RESTART_APP in lmw_root_daemon.c.
        assertEquals("RESTART_APP", RootDaemonProtocol.restartAppRequest())
    }

    @Test
    fun restart_app_and_reboot_are_distinct_verbs() {
        // Guards against ever collapsing the two (a warm reboot bricks Wi-Fi on
        // QZX_C1; normal restart must never reboot).
        assertNotEquals(RootDaemonProtocol.restartAppRequest(), RootDaemonProtocol.rebootRequest())
    }

    @Test
    fun install_request_is_verb_space_path() {
        assertEquals(
            "INSTALL ${RootDaemonProtocol.CANONICAL_APK_PATH}",
            RootDaemonProtocol.installRequest(RootDaemonProtocol.CANONICAL_APK_PATH),
        )
    }

    @Test
    fun daemon_candidate_path_and_update_request_are_fixed_and_hash_only() {
        assertEquals(
            "/data/data/com.jieoz.lanmediawall.player/cache/update/lmw_root_daemon.candidate",
            RootDaemonProtocol.CANONICAL_DAEMON_CANDIDATE_PATH,
        )
        val sha = "A".repeat(64)
        assertEquals("UPDATE_DAEMON $sha", RootDaemonProtocol.updateDaemonRequest(sha))
    }

    @Test(expected = IllegalArgumentException::class)
    fun daemon_update_request_rejects_non_sha256_argument() {
        RootDaemonProtocol.updateDaemonRequest("../../system/xbin/lmw_root_daemon")
    }

    @Test
    fun daemon_update_reply_requires_verified_installed_state() {
        assertTrue(RootDaemonProtocol.parseDaemonUpdate(
            "ok update_daemon verified installed sha256=${"a".repeat(64)}").ok)
        assertFalse(RootDaemonProtocol.parseDaemonUpdate(
            "error update_daemon apply_failed rollback=restored").ok)
        assertFalse(RootDaemonProtocol.parseDaemonUpdate("ok update_daemon staged").ok)
    }

    @Test
    fun daemon_update_timeout_outlives_candidate_probe_budget() {
        // The daemon may spend up to 5 seconds starting/probing the candidate.
        // The client must not time out first and delete the candidate mid-proof.
        assertTrue(RootInstaller.daemonUpdateResponseTimeoutMs > 5_000)
        assertTrue(
            RootInstaller.responseTimeoutMs(
                RootDaemonProtocol.updateDaemonRequest("a".repeat(64)),
            ) > RootInstaller.responseTimeoutMs(RootDaemonProtocol.probeRequest()),
        )
    }

    @Test
    fun parse_probe_ready_requires_ready_prefix_and_euid0() {
        val r = RootDaemonProtocol.parseProbe(
            "ready daemon_euid=0 peer_uid=10020 allowed_uid=10020 pkg=com.jieoz.lanmediawall.player")
        assertTrue(r.ready)
        assertTrue(r.detail.contains("daemon_euid=0"))
    }

    @Test
    fun parse_probe_rejects_non_root_daemon() {
        val r = RootDaemonProtocol.parseProbe("ready daemon_euid=10020 peer_uid=10020 allowed_uid=10020")
        assertFalse(r.ready)
    }

    @Test
    fun parse_probe_rejects_error_response() {
        val r = RootDaemonProtocol.parseProbe("error unauthorized peer_uid=10021")
        assertFalse(r.ready)
        assertEquals("error unauthorized peer_uid=10021", r.detail)
    }

    @Test
    fun parse_probe_rejects_blank() {
        val r = RootDaemonProtocol.parseProbe("")
        assertFalse(r.ready)
    }

    @Test
    fun install_response_ok_detected() {
        assertTrue(RootDaemonProtocol.isOk("ok install state=pm_success activated via=pm_install restart_dispatched"))
        assertTrue(RootDaemonProtocol.isOk("ok restart_app accepted restart_dispatched"))
        assertTrue(RootDaemonProtocol.isOk("ok reboot rebooting"))
        assertFalse(RootDaemonProtocol.isOk("error install pm_failed detail=Failure [INSTALL_FAILED]"))
        assertFalse(RootDaemonProtocol.isOk("error install path rejected code=6"))
        assertFalse(RootDaemonProtocol.isOk(""))
    }

    @Test
    fun parse_install_distinguishes_pm_legacy_and_failure() {
        val pm = RootDaemonProtocol.parseInstall(
            "ok install state=pm_success activated via=pm_install restart_dispatched")
        assertEquals(RootDaemonProtocol.InstallState.PM_SUCCESS, pm.state)
        assertTrue(pm.ok)
        assertFalse(pm.rebootRequired)

        val legacy = RootDaemonProtocol.parseInstall(
            "ok install state=legacy_activation_dispatched reboot_required via=data_app_scanner")
        assertEquals(RootDaemonProtocol.InstallState.LEGACY_ACTIVATION_DISPATCHED, legacy.state)
        assertTrue(legacy.ok)
        assertTrue(legacy.rebootRequired)

        val failed = RootDaemonProtocol.parseInstall("error install pm_failed detail=Failure")
        assertEquals(RootDaemonProtocol.InstallState.FAILED, failed.state)
        assertFalse(failed.ok)
        assertFalse(failed.rebootRequired)
    }

    @Test
    fun parse_install_accepts_field_legacy_staged_reboot_pending_as_non_failure() {
        // §field-and-6037055a3d: a deployed daemon returned this exact line and the
        // player mis-classified it as install_daemon_fail. A legacy staged reboot is
        // a SUCCESS-with-reboot, never a failure — the update applies on reboot.
        val field = RootDaemonProtocol.parseInstall(
            "ok install state=legacy_staged reboot_pending via=data_app_scanner")
        assertEquals(RootDaemonProtocol.InstallState.LEGACY_ACTIVATION_DISPATCHED, field.state)
        assertTrue(field.ok)
        assertTrue(field.rebootRequired)
    }

    @Test
    fun parse_install_requires_both_legacy_stage_and_reboot_markers() {
        // A bare "ok install" with neither marker must NOT be silently treated as a
        // reboot-pending success (that would hide a genuinely ambiguous reply).
        val neither = RootDaemonProtocol.parseInstall("ok install something else")
        assertEquals(RootDaemonProtocol.InstallState.FAILED, neither.state)

        val failed = RootDaemonProtocol.parseInstall("error install pm_failed detail=Failure")
        assertEquals(RootDaemonProtocol.InstallState.FAILED, failed.state)
        assertFalse(failed.ok)
        assertFalse(failed.rebootRequired)
    }
}
