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
    timeoutSeconds: Long = 60,
) {
    private val client = OkHttpClient.Builder()
        .callTimeout(0, TimeUnit.SECONDS)
        .connectTimeout(timeoutSeconds, TimeUnit.SECONDS)
        .readTimeout(timeoutSeconds, TimeUnit.SECONDS)
        .build()

    sealed class Result {
        /** APK downloaded + sha256-verified + activated by the daemon via
         *  `pm install -r` + app restart (no whole-device reboot). */
        object Installing : Result()
        data class Failed(val reason: String) : Result()
    }

    /**
     * Download [url] into the update cache, verify against [expectedSha256]
     * (lower-hex, already shape-checked by [UpdateGuard]), and root-install for
     * [pkg]. Blocking — call off the main thread. Never partially installs: a
     * hash mismatch deletes the file and returns [Result.Failed] before any su.
     */
    fun downloadVerifyInstall(
        pkg: String,
        url: String,
        expectedSha256: String,
        log: (String) -> Unit = {},
    ): Result {
        val dir = File(cacheDir, "update").apply { mkdirs() }
        // ONE fixed canonical filename — the daemon only ever installs this exact
        // path (RootDaemonProtocol.CANONICAL_APK_PATH / LMW_CANONICAL_APK). Using
        // "$pkg-update.apk" keeps that contract regardless of the pushed package.
        val apk = File(dir, "$pkg-update.apk")
        val part = File(dir, "$pkg-update.apk.part")
        try {
            var existing = if (part.exists()) part.length() else 0L
            val builder = Request.Builder().url(url).get()
            if (existing > 0) builder.header("Range", "bytes=$existing-")
            log("update_download_start url=$url resume_from=$existing")

            client.newCall(builder.build()).execute().use { resp ->
                val code = resp.code()
                if (code != 200 && code != 206) {
                    log("update_download_fail http=$code")
                    return Result.Failed("http-$code")
                }
                if (code == 200 && existing > 0) { existing = 0; part.delete() }
                val body = resp.body() ?: run {
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
                log("update_download_done http=$code bytes=${part.length()}")
            }

            val actual = sha256File(part)
            if (!actual.equals(expectedSha256, ignoreCase = true)) {
                part.delete()
                log("update_verify_fail reason=sha256-mismatch expected=$expectedSha256 actual=$actual")
                return Result.Failed("sha256-mismatch")
            }
            log("update_verify_ok sha256=$actual")
            if (!part.renameTo(apk)) {
                part.copyTo(apk, overwrite = true); part.delete()
            }
            log("update_staged path=${apk.absolutePath}")

            // Hand off to the root daemon over its local socket. There is NO su
            // fallback — on the target su denies the app UID and setuid is a
            // no-op under no_new_privs, so the daemon is the only path that works.
            val installed = RootInstaller.install(pkg, apk, log)
            return if (installed.ok) Result.Installing
                   // Propagate the daemon's real reason (pm failure / path / probe)
                   // instead of a flat "install-failed" so the breakpoint is visible.
                   else Result.Failed(installed.detail)
        } catch (e: Exception) {
            Log.e(TAG, "update failed: ${e.javaClass.simpleName}")
            log("update_exception ${e.javaClass.simpleName}: ${e.message ?: ""}")
            return Result.Failed(e.javaClass.simpleName)
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

    companion object { private const val TAG = "lmw.AppUpdater" }
}
