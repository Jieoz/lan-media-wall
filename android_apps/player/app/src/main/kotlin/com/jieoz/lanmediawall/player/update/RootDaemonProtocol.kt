package com.jieoz.lanmediawall.player.update

/**
 * Pure (device-free, unit-testable) definition of the line protocol the
 * [RootInstaller] client speaks to the root daemon (`scripts/lmw_root_daemon.c`)
 * over an abstract AF_UNIX socket. Keeping every string + parse rule here means
 * the wire contract is locked by [RootDaemonProtocolTest] with no socket needed;
 * [RootInstaller] is then a thin side-effecting LocalSocket wrapper.
 *
 * Contract (must stay in lockstep with lmw_root_daemon.c):
 *   socket : abstract namespace, name [SOCKET_NAME]
 *   request: one line — "PROBE" | "RESTART_APP" | "REBOOT" | "INSTALL <abs-path>"
 *   probe  : ready iff response begins "ready " AND contains "daemon_euid=0"
 *            (proves the peer we reached is genuinely root, not a spoof)
 *
 * §restart-semantics — RESTART_APP vs REBOOT are DIFFERENT actions and must not be
 * conflated: RESTART_APP force-stops + relaunches ONLY the Player app (the normal
 * controller "restart" — preserves Wi-Fi + uptime). REBOOT restarts the whole
 * device (a separate HIGH-RISK action: a warm reboot loses Wi-Fi on QZX_C1 until a
 * cold power cycle). INSTALL now activates the new APK via `pm install -r` + an
 * app restart, never a whole-device reboot.
 */
object RootDaemonProtocol {
    /** Abstract socket name; matches LMW_SOCKET_NAME in the daemon. */
    const val SOCKET_NAME = "lmw_root_daemon"

    /** The ONE canonical update APK the daemon will INSTALL; matches
     *  LMW_CANONICAL_APK in the daemon and [AppUpdater]'s download target. */
    const val CANONICAL_APK_PATH =
        "/data/data/com.jieoz.lanmediawall.player/cache/update/" +
            "com.jieoz.lanmediawall.player-update.apk"

    fun probeRequest(): String = "PROBE"

    /** Normal restart: force-stop + relaunch ONLY the Player app (app-only, never
     *  a whole-device reboot). See §restart-semantics. */
    fun restartAppRequest(): String = "RESTART_APP"

    /** Whole-device reboot — the separate HIGH-RISK action only. */
    fun rebootRequest(): String = "REBOOT"

    fun installRequest(absPath: String): String = "INSTALL $absPath"

    data class Probe(val ready: Boolean, val detail: String)

    enum class InstallState { PM_SUCCESS, LEGACY_ACTIVATION_DISPATCHED, FAILED }
    data class InstallReply(val state: InstallState, val detail: String) {
        val ok: Boolean get() = state != InstallState.FAILED
        val rebootRequired: Boolean get() = state == InstallState.LEGACY_ACTIVATION_DISPATCHED
    }

    fun parseInstall(response: String): InstallReply {
        val line = response.trim()
        return when {
            line.startsWith("ok install ") && line.contains("state=pm_success") ->
                InstallReply(InstallState.PM_SUCCESS, line)
            // Legacy last-resort activation: the APK is staged for the boot scanner
            // and a whole-device reboot has been dispatched. This is NOT a failure —
            // the update will apply on reboot. Accept both the canonical reply
            // (state=legacy_activation_dispatched + reboot_required) AND the
            // field-observed variant (state=legacy_staged + reboot_pending) that
            // older/deployed daemons still emit, so a real staged reboot is never
            // mis-reported as install_daemon_fail (§field-and-6037055a3d).
            line.startsWith("ok install ") && isLegacyStagedReboot(line) ->
                InstallReply(InstallState.LEGACY_ACTIVATION_DISPATCHED, line)
            else -> InstallReply(InstallState.FAILED, line.ifBlank { "empty" })
        }
    }

    /** True if an `ok install` line carries legacy-stage semantics AND a reboot
     *  marker, in either the canonical or the field-observed token spelling. */
    private fun isLegacyStagedReboot(line: String): Boolean {
        val staged = line.contains("state=legacy_activation_dispatched") ||
            line.contains("state=legacy_staged")
        val reboot = line.contains("reboot_required") || line.contains("reboot_pending")
        return staged && reboot
    }

    /** Parse the daemon's PROBE reply. Ready requires an explicit root euid so a
     *  non-root impostor bound to the same abstract name can never look ready. */
    fun parseProbe(response: String): Probe {
        val line = response.trim()
        val ready = line.startsWith("ready ") && line.contains("daemon_euid=0")
        return Probe(ready = ready, detail = line.ifBlank { "empty" })
    }

    /** True if a REBOOT/INSTALL reply reports success. */
    fun isOk(response: String): Boolean = response.trim().startsWith("ok ")
}
