package com.jieoz.lanmediawall.player.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * §22 update diagnostics: the pre-daemon guard branches of [RootInstaller.install]
 * must return a TRUTHFUL [RootInstaller.InstallResult.detail] AND emit a log line,
 * instead of the old flat `false`. These three branches short-circuit before any
 * socket call, so they run on a plain JVM with real files (no device/daemon).
 *
 * This is the fix for "P2P update fails with no visible reason": the specific
 * breakpoint (unknown package / missing apk / non-canonical path / daemon error)
 * now reaches the controller + player.log verbatim.
 */
class RootInstallerTest {

    private fun caplog(): Pair<MutableList<String>, (String) -> Unit> {
        val out = mutableListOf<String>()
        return out to { line -> out.add(line) }
    }

    @Test
    fun install_rejects_unknown_package_with_reason_and_log() {
        val (log, sink) = caplog()
        val r = RootInstaller.install("com.evil.app", File("/tmp/whatever.apk"), sink)
        assertFalse(r.ok)
        assertEquals("unknown-package", r.detail)
        assertTrue(log.any { it.startsWith("install_reject reason=unknown-package") })
    }

    @Test
    fun install_rejects_missing_apk_with_reason_and_log() {
        val (log, sink) = caplog()
        val missing = File.createTempFile("lmw-missing", ".apk").apply { delete() }
        val r = RootInstaller.install("com.jieoz.lanmediawall.player", missing, sink)
        assertFalse(r.ok)
        assertEquals("apk-missing", r.detail)
        assertTrue(log.any { it.startsWith("install_reject reason=apk-missing") })
    }

    @Test
    fun install_rejects_non_canonical_path_with_reason_and_log() {
        val (log, sink) = caplog()
        // A real non-empty file, but NOT at the single canonical install path.
        val tmp = File.createTempFile("lmw-noncanon", ".apk")
        tmp.writeBytes(byteArrayOf(1, 2, 3))
        try {
            val r = RootInstaller.install("com.jieoz.lanmediawall.player", tmp, sink)
            assertFalse(r.ok)
            assertEquals("non-canonical-path", r.detail)
            assertTrue(log.any { it.startsWith("install_reject reason=non-canonical-path") })
        } finally {
            tmp.delete()
        }
    }

    @Test
    fun install_result_ok_carries_detail() {
        // Shape guard: a success result must carry the daemon's line, a failure its reason.
        val ok = RootInstaller.InstallResult(true, "ok install activated via=pm_install restart_dispatched")
        val bad = RootInstaller.InstallResult(false, "daemon:error install pm_failed detail=Failure")
        assertTrue(ok.ok); assertTrue(ok.detail.startsWith("ok "))
        assertFalse(bad.ok); assertTrue(bad.detail.contains("pm_failed"))
    }
}
