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
    /**
     * 探针/重启这类"立刻能答"的请求预算。这些请求 daemon 侧不做重活,4s 足够宽。
     */
    private const val DEFAULT_RESPONSE_TIMEOUT_MS = 4_000
    const val daemonUpdateResponseTimeoutMs = 15_000

    /**
     * §OTA INSTALL 的响应预算。
     *
     * INSTALL 不是"立刻能答"的请求:daemon 侧要把 APK 复制到世界可读的暂存区,再顺序跑
     * `pm install -r`(失败则 `-r -f`),PackageManager 还要 re-dexopt —— 现场实测
     * send→reply 是 3450ms / 3521ms,而客户端预算是 4000ms。余量只有 ~500ms,盒子稍忙
     * 就必然超时,超时后客户端把 `null` 解释成 `unreachable`,于是日志出现
     * "probe 刚说 ready、4 秒后 daemon 不可达"这种自相矛盾的记录(现场实测 4010ms)。
     *
     * 而 daemon 那边其实**装成功了**,只是回复没人收 —— 所以设备重启后新版本就生效了,
     * 表现为"每次升级都要重启一次,而且控制端显示失败"。
     *
     * 这里给 INSTALL 一个与它真实工作量相称的预算(dexopt 在低配盒子上可以很慢),
     * 和 UPDATE_DAEMON 同级。超时不再是常态,真超时才代表真出问题。
     */
    const val installResponseTimeoutMs = 60_000
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
    private fun request(line: String): String? = requestDetailed(line).response

    /**
     * 请求结果的**真实分类**。区分这两件事很关键,因为它们的正确处置完全相反:
     *
     * - [Outcome.UNREACHABLE] —— 连不上 socket。daemon 没跑/没配置,**什么都没发生**,
     *   重试或报错都安全。
     * - [Outcome.TIMEOUT] —— 连上了、请求已发出,但在预算内没读到回复。这时 daemon
     *   **可能已经把活干完了**(INSTALL 的现场就是如此),结果是**未知**,绝不能当成
     *   "没发生"。
     *
     * 以前两者都返回 `null`,调用方一律写成 `unreachable` —— 于是"探针刚说 ready、
     * 4 秒后不可达"这种自相矛盾的日志诞生了,而且把一次**其实成功**的安装报成失败。
     */
    internal enum class Outcome { OK, TIMEOUT, UNREACHABLE }

    internal data class Reply(val outcome: Outcome, val response: String?)

    private fun requestDetailed(line: String): Reply {
        val socket = LocalSocket()
        return try {
            socket.connect(
                LocalSocketAddress(RootDaemonProtocol.SOCKET_NAME, LocalSocketAddress.Namespace.ABSTRACT),
            )
            socket.soTimeout = responseTimeoutMs(line)
            socket.outputStream.write((line + "\n").toByteArray())
            socket.outputStream.flush()
            socket.shutdownOutput()
            val text = socket.inputStream.bufferedReader().readText().trim()
            // 读到空串同样是"没拿到回复",不是一个有效响应。
            if (text.isEmpty()) Reply(Outcome.TIMEOUT, null) else Reply(Outcome.OK, text)
        } catch (e: java.io.InterruptedIOException) {
            // soTimeout 到期(SocketTimeoutException 是它的子类)。请求已经发出去了。
            Log.w(TAG, "daemon request timed out after ${responseTimeoutMs(line)}ms")
            Reply(Outcome.TIMEOUT, null)
        } catch (e: Exception) {
            Log.w(TAG, "daemon request failed: ${e.javaClass.simpleName}")
            Reply(Outcome.UNREACHABLE, null)
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }

    internal fun responseTimeoutMs(request: String): Int = when {
        request.startsWith("UPDATE_DAEMON ") -> daemonUpdateResponseTimeoutMs
        // INSTALL 要等 pm install + dexopt,预算必须与实际工作量相称(见 installResponseTimeoutMs)。
        request.startsWith("INSTALL ") -> installResponseTimeoutMs
        else -> DEFAULT_RESPONSE_TIMEOUT_MS
    }

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
        val reply = requestDetailed(RootDaemonProtocol.installRequest(apk.absolutePath))
        if (reply.outcome != Outcome.OK) {
            // 没拿到回复 ≠ 没装上。daemon 侧 pm install + dexopt 可能仍在跑或已经跑完,
            // 结果是**未知**的 —— 直接报 fail 就是之前"其实装成功了却显示失败、还要靠
            // 重启兜住"的来源。这里如实报告未知,并交给上层去核对真实结果。
            val why = if (reply.outcome == Outcome.TIMEOUT) "timeout" else "unreachable"
            Log.e(TAG, "daemon install no reply: $why")
            log("install_daemon_no_reply why=$why budget_ms=${installResponseTimeoutMs}")
            return InstallResult(
                ok = false,
                detail = "daemon-no-reply:$why",
                state = RootDaemonProtocol.InstallState.UNKNOWN,
            )
        }
        val resp = reply.response
        val parsed = RootDaemonProtocol.parseInstall(resp ?: "")
        if (parsed.state == RootDaemonProtocol.InstallState.FAILED) {
            Log.e(TAG, "daemon install failed: $resp")
            log("install_daemon_fail resp=$resp")
            return InstallResult(false, "daemon:$resp")
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
