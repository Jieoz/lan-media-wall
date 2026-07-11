package com.jieoz.lanmediawall.player.update

import android.util.Log
import java.io.File

/**
 * §22 self-update: install a downloaded+verified APK on a rooted 4.4 外贸盒 by
 * mirroring the proven `scripts/deploy_player.sh` path — the ONLY path that
 * actually installs on these boxes.
 *
 * WHY NOT `pm install` / PackageInstaller:
 *   These YunOS/AliOS boxes report a bogus recommendAppInstallLocation to a
 *   forked PackageManagerService, so `pm install` (and PackageInstaller) fail
 *   with INSTALL_FAILED_INVALID_INSTALL_LOCATION *before* our internalOnly flag
 *   applies (see AndroidManifest §6.3 + deploy_player.sh header). The reliable
 *   path — which these boxes allow because they default to `adb root`/`su` — is
 *   to drop the APK straight into /data/app and let the next boot's package
 *   scanner adopt it, skipping the location recommender entirely.
 *
 * SECURITY: this class only EXECUTES an install once every §22 guardrail in
 * [com.jieoz.lanmediawall.player.PlayerService] has passed (authenticated frame,
 * monotonic versionCode, sha256-verified file). The platform additionally
 * enforces same-signer on the upgrade scan, so a differently-signed APK dropped
 * here is rejected by PackageManager at boot — we get that for free.
 *
 * The command STRING is built by the pure, unit-testable [installScript]; the
 * side-effecting [install] just pipes it to `su`.
 */
object RootInstaller {
    private const val TAG = "lmw.RootInstaller"
    private const val HELPER = "/system/xbin/lmw_root_helper"
    private const val PROBE_CACHE_MS = 30_000L
    @Volatile private var cachedProbe: Probe? = null
    @Volatile private var cachedProbeAtMs = 0L

    /**
     * The helper argv used by the preferred install path. lmw_update.bat arms
     * this helper once using adb/root: owner root, group = Player app uid,
     * mode 6750. That is the durable fix for QZX_C1 stock su, which rejects
     * normal app UIDs (`su: uid N not allowed to su`).
     */
    fun helperCommand(pkg: String, srcApk: String): List<String> = listOf(HELPER, pkg, srcApk)

    fun rebootCommand(): List<String> = listOf(HELPER, "reboot")

    fun probeCommand(): List<String> = listOf(HELPER, "probe")

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

    private fun probeNow(): Probe = try {
        val p = ProcessBuilder(probeCommand()).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText().trim()
        val code = p.waitFor()
        Probe(
            ready = code == 0 && out.startsWith("ready ") && out.contains("euid=0"),
            detail = out.ifBlank { "exit=$code" },
        )
    } catch (e: Exception) {
        Probe(false, e.javaClass.simpleName)
    }

    /**
     * The fallback shell script piped to `su`. Pure string builder so it's unit-testable
     * with no device. Mirrors deploy_player.sh: copy into /data/app under the
     * package-scanner-adopted name, world-read so the scanner can read it at
     * boot, then reboot to trigger adoption.
     *
     * [pkg] is quoted-safe by construction (it's our own applicationId, ASCII).
     * [srcApk] is our own cache path (also ASCII, no spaces) — but we still
     * single-quote both so a future non-ASCII cache dir can't break the script.
     */
    fun installScript(pkg: String, srcApk: String): String {
        val dst = "/data/app/$pkg-1.apk"
        val q = { s: String -> "'" + s.replace("'", "'\\''") + "'" }
        return buildString {
            append("set -e; ")
            append("cp ").append(q(srcApk)).append(' ').append(q(dst)).append("; ")
            append("chmod 644 ").append(q(dst)).append("; ")
            append("sync; ")
            append("reboot")
        }
    }

    /** True if `su` is present + grants root (uid 0). Cheap probe, no install. */
    fun hasRoot(): Boolean = try {
        val p = ProcessBuilder("su", "-c", "id -u")
            .redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText().trim()
        p.waitFor()
        out.contains("0")
    } catch (e: Exception) {
        Log.w(TAG, "root probe failed: ${e.javaClass.simpleName}")
        false
    }

    /**
     * Install [apk] for package [pkg], then reboot. Preferred path is the
     * provisioned setuid helper because QZX_C1 stock `su` grants root to adb/shell
     * but rejects normal app UIDs. If an older box has real app-visible su, keep
     * the old path as a fallback.
     */
    fun install(pkg: String, apk: File): Boolean {
        if (!apk.exists() || apk.length() <= 0) {
            Log.e(TAG, "apk missing/empty: ${apk.absolutePath}")
            return false
        }
        val probe = probe(force = true)
        if (!probe.ready) {
            Log.e(TAG, "root bridge unavailable: ${probe.detail}")
            return false
        }
        if (installViaHelper(pkg, apk)) return true
        return installViaSu(pkg, apk)
    }

    fun rebootDevice(): Boolean {
        val probe = probe(force = true)
        if (!probe.ready) {
            Log.e(TAG, "root bridge unavailable: ${probe.detail}")
            return false
        }
        if (rebootViaHelper()) return true
        return rebootViaSu()
    }

    private fun rebootViaHelper(): Boolean = try {
        val p = ProcessBuilder(rebootCommand())
            .redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        val code = p.waitFor()
        if (code != 0) {
            Log.e(TAG, "helper reboot exited $code: ${out.take(200)}")
            false
        } else {
            true
        }
    } catch (e: Exception) {
        Log.w(TAG, "helper reboot unavailable: ${e.javaClass.simpleName}")
        false
    }

    private fun rebootViaSu(): Boolean = try {
        val p = ProcessBuilder("su", "-c", "reboot")
            .redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        val code = p.waitFor()
        if (code != 0) {
            Log.e(TAG, "su reboot exited $code: ${out.take(200)}")
            false
        } else {
            true
        }
    } catch (e: Exception) {
        Log.e(TAG, "su reboot failed: ${e.javaClass.simpleName}")
        false
    }

    private fun installViaHelper(pkg: String, apk: File): Boolean = try {
        val p = ProcessBuilder(helperCommand(pkg, apk.absolutePath))
            .redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        val code = p.waitFor()
        if (code != 0) {
            Log.e(TAG, "helper install exited $code: ${out.take(200)}")
            false
        } else {
            true // reboot dispatched
        }
    } catch (e: Exception) {
        Log.w(TAG, "helper install unavailable: ${e.javaClass.simpleName}")
        false
    }

    private fun installViaSu(pkg: String, apk: File): Boolean {
        val script = installScript(pkg, apk.absolutePath)
        return try {
            val p = ProcessBuilder("su", "-c", script)
                .redirectErrorStream(true).start()
            val out = p.inputStream.bufferedReader().readText()
            val code = p.waitFor()
            if (code != 0) {
                Log.e(TAG, "su install exited $code: ${out.take(200)}")
                false
            } else {
                true // reboot dispatched
            }
        } catch (e: Exception) {
            Log.e(TAG, "su install failed: ${e.javaClass.simpleName}")
            false
        }
    }
}
