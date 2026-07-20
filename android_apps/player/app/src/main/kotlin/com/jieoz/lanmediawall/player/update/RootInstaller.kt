package com.jieoz.lanmediawall.player.update

import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.util.Log
import java.io.File

/**
 * §22 self-update / §9.4 remote restart bridge — a **local-socket client** to the
 * root daemon (`scripts/lmw_root_daemon.c`), which is started as root by
 * provisioning and stays root.
 *
 * WHY A DAEMON, NOT su / setuid:
 *   On QZX_C1 / YunOS 4.4.2 the app UID is denied by stock `su`, and zygote's
 *   no_new_privs makes a setuid-root helper's elevation a no-op — the app keeps
 *   euid=10020 no matter the file bits. The only design that works is a process
 *   that is ALREADY root and exposes a restricted socket. There is deliberately
 *   NO su / setuid fallback here: those paths never worked on the target and only
 *   added misleading "maybe it'll install" complexity. If the daemon is not
 *   reachable + root, install/reboot fail explicitly and loudly.
 *
 * SECURITY: the daemon authenticates us by kernel peer credentials (SO_PEERCRED)
 * against a root-owned uid file, and only accepts the single canonical update
 * path. The app-side §23 guardrails ([UpdateGuard]) still gate every call. The
 * wire protocol lives in the pure, unit-tested [RootDaemonProtocol].
 */
object RootInstaller {
    private const val TAG = "lmw.RootInstaller"
    private const val PROBE_CACHE_MS = 30_000L
    private const val DEFAULT_RESPONSE_TIMEOUT_MS = 4_000
    const val daemonUpdateResponseTimeoutMs = 15_000
    @Volatile private var cachedProbe: Probe? = null
    @Volatile private var cachedProbeAtMs = 0L

    /** The single canonical APK path the daemon will install (see AppUpdater). */
    val canonicalApkPath: String get() = RootDaemonProtocol.CANONICAL_APK_PATH
    val canonicalDaemonCandidatePath: String
        get() = RootDaemonProtocol.CANONICAL_DAEMON_CANDIDATE_PATH

    data class Probe(val ready: Boolean, val detail: String)

    /**
     * Outcome of an [install] attempt. [detail] is the *truthful* reason string —
     * on failure it carries the daemon's own error line (e.g.
     * `daemon:error install pm_failed detail=...`) or the pre-daemon guard reason,
     * so the controller/log sees the real breakpoint instead of a flat
     * "install-failed". On success it carries the daemon's `ok ...` line.
     */
    data class InstallResult(
        val ok: Boolean,
        val detail: String,
        val state: RootDaemonProtocol.InstallState = if (ok) RootDaemonProtocol.InstallState.PM_SUCCESS else RootDaemonProtocol.InstallState.FAILED,
        val rebootRequired: Boolean = false,
    )

    @Synchronized
    fun probe(force: Boolean = false): Probe {
        val now = android.os.SystemClock.elapsedRealtime()
        cachedProbe?.let {
            if (!force && now - cachedProbeAtMs < PROBE_CACHE_MS) return it
        }
        val result = probeNow()
        cachedProbe = result
        cachedProbeAtMs = now
        return result
    }

    private fun probeNow(): Probe {
        val resp = request(RootDaemonProtocol.probeRequest())
            ?: return Probe(false, "daemon-unreachable")
        val p = RootDaemonProtocol.parseProbe(resp)
        return Probe(p.ready, p.detail)
    }

    /**
     * Open the abstract socket, send one request line, read the single response
     * line. Returns null if the daemon isn't reachable (not provisioned / not
     * running). Best-effort with a bounded connect timeout so a dead daemon never
     * hangs the caller.
     */
    private fun request(line: String): String? {
        val socket = LocalSocket()
        return try {
            socket.connect(
                LocalSocketAddress(RootDaemonProtocol.SOCKET_NAME, LocalSocketAddress.Namespace.ABSTRACT),
            )
            socket.soTimeout = responseTimeoutMs(line)
            socket.outputStream.write((line + "\n").toByteArray())
            socket.outputStream.flush()
            socket.shutdownOutput()
            socket.inputStream.bufferedReader().readText().trim()
        } catch (e: Exception) {
            Log.w(TAG, "daemon request failed: ${e.javaClass.simpleName}")
            null
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }

    internal fun responseTimeoutMs(request: String): Int =
        if (request.startsWith("UPDATE_DAEMON ")) daemonUpdateResponseTimeoutMs
        else DEFAULT_RESPONSE_TIMEOUT_MS

    /**
     * §restart-semantics: ask the daemon to force-stop + relaunch ONLY the Player
     * app (the normal controller "restart" — preserves Wi-Fi + uptime, NEVER a
     * whole-device reboot). Returns false if the daemon is unreachable/not-root or
     * rejects the request; the caller then reports failure and does NOT fall back
     * to reboot (a normal restart must never warm-reboot on QZX_C1).
     */
    fun restartApp(): Boolean {
        val probe = probe(force = true)
        if (!probe.ready) {
            Log.e(TAG, "root daemon unavailable: ${probe.detail}")
            return false
        }
        val resp = request(RootDaemonProtocol.restartAppRequest())
        if (resp == null || !RootDaemonProtocol.isOk(resp)) {
            Log.e(TAG, "daemon restart_app failed: ${resp ?: "unreachable"}")
            return false
        }
        return true
    }

    /**
     * Install [apk] for package [pkg]: the daemon activates it via `pm install -r`
     * then restarts ONLY the app (no whole-device reboot). The APK MUST already be
     * at the canonical path — [AppUpdater] downloads it there. Returns false (no
     * partial state) if the daemon is unreachable/not-root or rejects the request.
     */
    fun install(pkg: String, apk: File, log: (String) -> Unit = {}): InstallResult {
        if (pkg != "com.jieoz.lanmediawall.player") {
            Log.e(TAG, "refusing unknown package: $pkg")
            log("install_reject reason=unknown-package pkg=$pkg")
            return InstallResult(false, "unknown-package")
        }
        if (!apk.exists() || apk.length() <= 0) {
            Log.e(TAG, "apk missing/empty: ${apk.absolutePath}")
            log("install_reject reason=apk-missing path=${apk.absolutePath} len=${apk.length()}")
            return InstallResult(false, "apk-missing")
        }
        if (apk.absolutePath != canonicalApkPath) {
            Log.e(TAG, "apk not at canonical path: ${apk.absolutePath}")
            log("install_reject reason=non-canonical-path path=${apk.absolutePath} expected=$canonicalApkPath")
            return InstallResult(false, "non-canonical-path")
        }
        val probe = probe(force = true)
        if (!probe.ready) {
            Log.e(TAG, "root daemon unavailable: ${probe.detail}")
            log("install_reject reason=daemon-not-ready detail=${probe.detail}")
            return InstallResult(false, "daemon-not-ready:${probe.detail}")
        }
        log("install_daemon_send path=${apk.absolutePath} daemon_probe=${probe.detail}")
        val resp = request(RootDaemonProtocol.installRequest(apk.absolutePath))
        val parsed = RootDaemonProtocol.parseInstall(resp ?: "")
        if (parsed.state == RootDaemonProtocol.InstallState.FAILED) {
            Log.e(TAG, "daemon install failed: ${resp ?: "unreachable"}")
            log("install_daemon_fail resp=${resp ?: "unreachable"}")
            return InstallResult(false, "daemon:${resp ?: "unreachable"}")
        }
        log("install_daemon_reply state=${parsed.state} reboot_required=${parsed.rebootRequired} resp=$resp")
        return InstallResult(
            ok = parsed.state == RootDaemonProtocol.InstallState.PM_SUCCESS,
            detail = parsed.detail,
            state = parsed.state,
            rebootRequired = parsed.rebootRequired,
        )
    }

    /**
     * Replace the daemon's own binary from the one fixed candidate path. The
     * daemon independently checks the expected SHA, executes the candidate on an
     * isolated probe socket, and atomically rolls back on any failed proof.
     */
    fun updateDaemon(candidate: File, expectedSha256: String, log: (String) -> Unit = {}): Boolean {
        if (candidate.absolutePath != canonicalDaemonCandidatePath ||
            !candidate.isFile || candidate.length() <= 0L) {
            log("daemon_update_reject reason=invalid-candidate path=${candidate.absolutePath}")
            return false
        }
        val command = try {
            RootDaemonProtocol.updateDaemonRequest(expectedSha256)
        } catch (_: IllegalArgumentException) {
            log("daemon_update_reject reason=invalid-sha256")
            return false
        }
        val probe = probe(force = true)
        if (!probe.ready) {
            log("daemon_update_reject reason=daemon-not-ready detail=${probe.detail}")
            return false
        }
        val response = request(command) ?: ""
        val parsed = RootDaemonProtocol.parseDaemonUpdate(response)
        log("daemon_update_reply ok=${parsed.ok} detail=${parsed.detail}")
        if (parsed.ok) cachedProbe = null
        return parsed.ok
    }

    /** Whole-device reboot — the separate HIGH-RISK action, only for the explicit
     *  `reboot` command. NOT used by normal restart or update (§restart-semantics). */
    fun rebootDevice(): Boolean {
        val probe = probe(force = true)
        if (!probe.ready) {
            Log.e(TAG, "root daemon unavailable: ${probe.detail}")
            return false
        }
        val resp = request(RootDaemonProtocol.rebootRequest())
        if (resp == null || !RootDaemonProtocol.isOk(resp)) {
            Log.e(TAG, "daemon reboot failed: ${resp ?: "unreachable"}")
            return false
        }
        return true
    }
}
