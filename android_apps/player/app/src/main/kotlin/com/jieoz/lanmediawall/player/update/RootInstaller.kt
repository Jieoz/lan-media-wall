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
    private const val CONNECT_TIMEOUT_MS = 4_000
    @Volatile private var cachedProbe: Probe? = null
    @Volatile private var cachedProbeAtMs = 0L

    /** The single canonical APK path the daemon will install (see AppUpdater). */
    val canonicalApkPath: String get() = RootDaemonProtocol.CANONICAL_APK_PATH

    data class Probe(val ready: Boolean, val detail: String)

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
            socket.soTimeout = CONNECT_TIMEOUT_MS
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

    /**
     * Install [apk] for package [pkg], then reboot (the daemon does both). The
     * APK MUST already be at the canonical path — [AppUpdater] downloads it there.
     * Returns false (no partial state) if the daemon is unreachable/not-root or
     * rejects the request.
     */
    fun install(pkg: String, apk: File): Boolean {
        if (pkg != "com.jieoz.lanmediawall.player") {
            Log.e(TAG, "refusing unknown package: $pkg")
            return false
        }
        if (!apk.exists() || apk.length() <= 0) {
            Log.e(TAG, "apk missing/empty: ${apk.absolutePath}")
            return false
        }
        if (apk.absolutePath != canonicalApkPath) {
            Log.e(TAG, "apk not at canonical path: ${apk.absolutePath}")
            return false
        }
        val probe = probe(force = true)
        if (!probe.ready) {
            Log.e(TAG, "root daemon unavailable: ${probe.detail}")
            return false
        }
        val resp = request(RootDaemonProtocol.installRequest(apk.absolutePath))
        if (resp == null || !RootDaemonProtocol.isOk(resp)) {
            Log.e(TAG, "daemon install failed: ${resp ?: "unreachable"}")
            return false
        }
        return true // reboot dispatched by the daemon
    }

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
