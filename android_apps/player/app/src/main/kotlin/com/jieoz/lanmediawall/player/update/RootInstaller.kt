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

    /**
     * The shell script piped to `su`. Pure string builder so it's unit-testable
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
     * Install [apk] for package [pkg] via root, then reboot. Returns false
     * (without rebooting) if the APK is missing or `su` can't be run — the
     * caller reports that back over the wire. On success the box reboots and
     * the package scanner adopts the new APK; the return here is effectively
     * "reboot dispatched".
     */
    fun install(pkg: String, apk: File): Boolean {
        if (!apk.exists() || apk.length() <= 0) {
            Log.e(TAG, "apk missing/empty: ${apk.absolutePath}")
            return false
        }
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
