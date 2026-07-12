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
        assertTrue(RootDaemonProtocol.isOk("ok install activated via=pm_install restarting_app"))
        assertTrue(RootDaemonProtocol.isOk("ok restart_app restarting_app"))
        assertTrue(RootDaemonProtocol.isOk("ok reboot rebooting"))
        assertFalse(RootDaemonProtocol.isOk("error install pm_failed detail=Failure [INSTALL_FAILED]"))
        assertFalse(RootDaemonProtocol.isOk("error install path rejected code=6"))
        assertFalse(RootDaemonProtocol.isOk(""))
    }
}
