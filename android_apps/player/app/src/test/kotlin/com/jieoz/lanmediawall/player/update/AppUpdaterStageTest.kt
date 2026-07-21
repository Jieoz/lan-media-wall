package com.jieoz.lanmediawall.player.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * §probe OTA stage-mapping test. Locks [AppUpdater.stageForReason] so the
 * UPDATE_STAGE that lands in `update_status.detail` (and therefore what field
 * ops read) always matches the real breakpoint carried by a
 * [AppUpdater.Result.Failed] reason string. Pure — no device / OkHttp needed.
 */
class AppUpdaterStageTest {

    private fun stage(reason: String) = AppUpdater.stageForReason(reason)

    @Test
    fun daemon_not_ready_maps_to_daemon_probe() {
        assertEquals("daemon_probe", stage("daemon-not-ready:daemon-unreachable"))
        assertEquals("daemon_probe", stage("daemon-not-ready:ready false daemon_euid=10020"))
    }

    @Test
    fun http_and_no_body_map_to_download() {
        assertEquals("download", stage("http-404"))
        assertEquals("download", stage("http-500"))
        assertEquals("download", stage("no-body"))
    }

    @Test
    fun sha256_mismatch_maps_to_sha256() {
        assertEquals("sha256", stage("sha256-mismatch"))
    }

    @Test
    fun pm_failed_and_daemon_error_map_to_pm_install() {
        assertEquals("pm_install", stage("daemon:daemon:error install pm_failed detail=..."))
        assertEquals("pm_install", stage("daemon:unreachable"))
        // A bare daemon-reported pm failure string also lands on pm_install.
        assertEquals("pm_install", stage("error install pm_failed detail=INSTALL_FAILED_VERSION_DOWNGRADE"))
    }

    @Test
    fun unknown_reasons_fall_back_to_failed() {
        assertEquals("failed", stage("IOException"))
        assertEquals("failed", stage("SocketTimeoutException"))
        assertEquals("failed", stage(""))
    }

    @Test
    fun daemon_probe_takes_precedence_over_daemon_prefix() {
        // "daemon-not-ready" starts with neither "daemon:" nor contains pm_failed,
        // so ordering must send it to daemon_probe, not pm_install.
        assertEquals("daemon_probe", stage("daemon-not-ready:x"))
    }

    @Test
    fun daemon_asset_contract_is_fixed_and_fail_closed() {
        assertEquals("lmw_root_daemon", AppUpdater.DAEMON_ASSET_ENTRY)
        assertEquals("daemon_update", stage("daemon-update-failed:verification_failed"))
        assertEquals("daemon_update", stage("daemon-asset-missing"))
    }

    @Test
    fun staged_daemon_is_executable_before_legacy_daemon_probe() {
        val dir = createTempDir(prefix = "lmw-daemon-stage-")
        val candidate = java.io.File(dir, "lmw_root_daemon.candidate")
        try {
            candidate.writeBytes(byteArrayOf(0x7f, 0x45, 0x4c, 0x46))
            candidate.setExecutable(false, false)
            assertFalse(candidate.canExecute())

            assertTrue(AppUpdater.prepareDaemonCandidate(candidate))
            assertTrue(candidate.canExecute())
        } finally {
            dir.deleteRecursively()
        }
    }
}
