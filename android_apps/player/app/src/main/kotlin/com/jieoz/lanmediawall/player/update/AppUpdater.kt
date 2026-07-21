package com.jieoz.lanmediawall.player.update

import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * §22 self-update orchestration glue: download the APK from the broker media
 * store (resumable Range GET), re-verify its sha256, then hand off to
 * [RootInstaller]. The security DECISIONS live in [UpdateGuard] (pure, tested);
 * the daemon wire protocol lives in [RootDaemonProtocol] (pure, tested).
 * This class is the thin side-effecting wiring between them.
 *
 * Result is reported back to the controller by the caller ([PlayerService]).
 */
class AppUpdater(
    private val cacheDir: File,
    private val daemonAssetProvider: (() -> java.io.InputStream)? = null,
    timeoutSeconds: Long = 60,
) {
    private val client = OkHttpClient.Builder()
        .callTimeout(0, TimeUnit.SECONDS)
        .connectTimeout(timeoutSeconds, TimeUnit.SECONDS)
        .readTimeout(timeoutSeconds, TimeUnit.SECONDS)
        .build()

    sealed class Result {
        /** PackageManager activated the APK and app restart was dispatched. */
        object Installing : Result()
        /** Legacy scanner file is staged and reboot activation was dispatched. */
        data class ActivationDispatched(val detail: String, val rebootRequired: Boolean = true) : Result()
        data class Failed(val reason: String) : Result()
    }

    /**
     * OTA-probe stage marker (§probe): emit a machine-readable
     * `UPDATE_STAGE=<stage> <msg>` line so remote log scraping can pin the exact
     * breakpoint of a push-upgrade (daemon_probe / download / sha256 / staged /
     * pm_install / restart_app / legacy_stage / exception). Additive — the
     * existing `update_*` lines are kept for backward compatibility.
     */
    private fun stage(log: (String) -> Unit, stage: String, msg: String = "") {
        log(if (msg.isBlank()) "UPDATE_STAGE=$stage" else "UPDATE_STAGE=$stage $msg")
    }

    /**
     * Download [url] into the update cache, verify against [expectedSha256]
     * (lower-hex, already shape-checked by [UpdateGuard]), and root-install for
     * [pkg]. Blocking — call off the main thread. Never partially installs: a
     * hash mismatch deletes the file and returns [Result.Failed] before any su.
     */
    fun downloadVerifyInstall(
        packageName: String,
        url: String,
        expectedSha256: String,
        log: (String) -> Unit = {},
    ): Result {
        val daemonReady = reconcileDaemon(log)
        if (daemonReady is Result.Failed) return daemonReady
        val dir = File(cacheDir, "update").apply { mkdirs() }
        try {
            // §probe fail-closed: verify the root daemon is reachable + genuinely
            // root BEFORE spending bandwidth on the APK. A dead root bridge fails
            // here at daemon_probe instead of downloading megabytes just to die at
            // the pm_install hand-off.
            val probe = RootInstaller.probe(force = true)
            if (!probe.ready) {
                stage(log, "daemon_probe", "ready=false detail=${probe.detail}")
                return Result.Failed("daemon-not-ready:${probe.detail}")
            }
            stage(log, "daemon_probe", "ready=true detail=${probe.detail}")

            // ONE fixed canonical filename — the daemon only ever installs this exact path.
            val apk = File(dir, "$packageName-update.apk")
            val part = File(dir, "$packageName-update.apk.part")
            var existing = if (part.exists()) part.length() else 0L
            val builder = Request.Builder().url(url).get()
            if (existing > 0) builder.header("Range", "bytes=$existing-")
            stage(log, "download", "start url=$url resume_from=$existing")
            log("update_download_start url=$url resume_from=$existing")

            client.newCall(builder.build()).execute().use { resp ->
                val code = resp.code()
                if (code != 200 && code != 206) {
                    stage(log, "download", "fail http=$code")
                    log("update_download_fail http=$code")
                    return Result.Failed("http-$code")
                }
                if (code == 200 && existing > 0) { existing = 0; part.delete() }
                val body = resp.body() ?: run {
                    stage(log, "download", "fail reason=no-body http=$code")
                    log("update_download_fail reason=no-body http=$code")
                    return Result.Failed("no-body")
                }
                val append = existing > 0
                java.io.FileOutputStream(part, append).use { fos ->
                    val src = body.byteStream()
                    val buf = ByteArray(256 * 1024)
                    while (true) {
                        val n = src.read(buf)
                        if (n < 0) break
                        if (n > 0) fos.write(buf, 0, n)
                    }
                }
                stage(log, "download", "ok http=$code bytes=${part.length()}")
                log("update_download_done http=$code bytes=${part.length()}")
            }

            stage(log, "sha256", "start expected=$expectedSha256")
            val actual = sha256File(part)
            if (!actual.equals(expectedSha256, ignoreCase = true)) {
                part.delete()
                stage(log, "sha256", "fail expected=$expectedSha256 actual=$actual")
                log("update_verify_fail reason=sha256-mismatch expected=$expectedSha256 actual=$actual")
                return Result.Failed("sha256-mismatch")
            }
            stage(log, "sha256", "ok sha256=$actual")
            log("update_verify_ok sha256=$actual")
            if (!part.renameTo(apk)) {
                part.copyTo(apk, overwrite = true); part.delete()
            }
            stage(log, "staged", "path=${apk.absolutePath}")
            log("update_staged path=${apk.absolutePath}")

            // Hand off to the root daemon over its local socket. There is NO su
            // fallback — on the target su denies the app UID and setuid is a
            // no-op under no_new_privs, so the daemon is the only path that works.
            stage(log, "pm_install", "daemon_send path=${apk.absolutePath}")
            val installed = RootInstaller.install(packageName, apk, log)
            return when (installed.state) {
                RootDaemonProtocol.InstallState.PM_SUCCESS -> {
                    stage(log, "restart_app", "pm_success detail=${installed.detail}")
                    Result.Installing
                }
                RootDaemonProtocol.InstallState.LEGACY_ACTIVATION_DISPATCHED -> {
                    stage(log, "legacy_stage", "reboot_required=${installed.rebootRequired} detail=${installed.detail}")
                    Result.ActivationDispatched(installed.detail, installed.rebootRequired)
                }
                RootDaemonProtocol.InstallState.FAILED -> {
                    stage(log, "pm_install", "fail detail=${installed.detail}")
                    Result.Failed(installed.detail)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "update failed: ${e.javaClass.simpleName}")
            stage(log, "exception", "${e.javaClass.simpleName}: ${e.message ?: ""}")
            log("update_exception ${e.javaClass.simpleName}: ${e.message ?: ""}")
            return Result.Failed(e.javaClass.simpleName)
        }
    }

    fun reconcileDaemon(log: (String) -> Unit = {}): Result? {
        val provider = daemonAssetProvider ?: return null
        val dir = File(cacheDir, "update").apply { mkdirs() }
        val candidate = File(RootInstaller.canonicalDaemonCandidatePath)
        return try {
            val parent = candidate.parentFile
            if (parent == null || parent.canonicalFile != dir.canonicalFile) {
                Result.Failed("daemon-update-invalid-candidate-path")
            } else {
                provider().use { input -> candidate.outputStream().use { input.copyTo(it) } }
                if (!prepareDaemonCandidate(candidate)) {
                    candidate.delete()
                    Result.Failed("daemon-candidate-not-executable")
                } else {
                    val sha = sha256File(candidate)
                    stage(log, "daemon_update", "candidate_sha256=$sha")
                    if (RootInstaller.updateDaemon(candidate, sha, log)) null
                    else {
                        candidate.delete()
                        Result.Failed("daemon-update-failed:verification_failed")
                    }
                }
            }
        } catch (e: Exception) {
            candidate.delete()
            Result.Failed("daemon-update-failed:${e.javaClass.simpleName}")
        }
    }

    private fun sha256File(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { ins ->
            val buf = ByteArray(1024 * 1024)
            while (true) {
                val n = ins.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    companion object {
        private const val TAG = "lmw.AppUpdater"
        const val DAEMON_ASSET_ENTRY = "lmw_root_daemon"

        /**
         * The currently installed daemon performs the candidate probe, so the
         * app-owned staging file must already be executable before UPDATE_DAEMON
         * is sent. A chmod inside the candidate/new daemon cannot bootstrap this
         * transition because that binary has not executed yet.
         */
        internal fun prepareDaemonCandidate(candidate: File): Boolean {
            if (!candidate.isFile || candidate.length() <= 0L) return false
            if (!candidate.setExecutable(true, true)) return false
            return candidate.canExecute()
        }

        /**
         * §probe: map a [Result.Failed] reason string to the UPDATE_STAGE it
         * belongs to, so the controller can put `UPDATE_STAGE=<stage>` into
         * `update_status.detail` and field ops can pin the breakpoint without
         * reading player.log. Pure (device-free) — locked by AppUpdaterStageTest.
         *
         *   daemon-not-ready*          -> daemon_probe
         *   http-* / no-body           -> download
         *   sha256-mismatch            -> sha256
         *   *pm_failed* / daemon:*     -> pm_install
         *   else                       -> failed
         */
        fun stageForReason(reason: String): String = when {
            reason.startsWith("daemon-update-") || reason == "daemon-asset-missing" ||
                reason == "daemon-candidate-not-executable" -> "daemon_update"
            reason.startsWith("daemon-not-ready:") -> "daemon_probe"
            reason.startsWith("http-") || reason == "no-body" -> "download"
            reason == "sha256-mismatch" -> "sha256"
            reason.contains("pm_failed") || reason.startsWith("daemon:") -> "pm_install"
            else -> "failed"
        }
    }
}
