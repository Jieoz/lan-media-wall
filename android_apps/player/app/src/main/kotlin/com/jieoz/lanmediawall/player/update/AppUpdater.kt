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
 * the install COMMAND lives in [RootInstaller.installScript] (pure, tested).
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
        /** APK downloaded + sha256-verified + reboot dispatched. */
        object Installing : Result()
        data class Failed(val reason: String) : Result()
    }

    /**
     * Download [url] into the update cache, verify against [expectedSha256]
     * (lower-hex, already shape-checked by [UpdateGuard]), and root-install for
     * [pkg]. Blocking — call off the main thread. Never partially installs: a
     * hash mismatch deletes the file and returns [Result.Failed] before any su.
     */
    fun downloadVerifyInstall(pkg: String, url: String, expectedSha256: String): Result {
        val dir = File(cacheDir, "update").apply { mkdirs() }
        val apk = File(dir, "$pkg-update.apk")
        val part = File(dir, "$pkg-update.apk.part")
        try {
            var existing = if (part.exists()) part.length() else 0L
            val builder = Request.Builder().url(url).get()
            if (existing > 0) builder.header("Range", "bytes=$existing-")

            client.newCall(builder.build()).execute().use { resp ->
                val code = resp.code()
                if (code != 200 && code != 206) return Result.Failed("http-$code")
                if (code == 200 && existing > 0) { existing = 0; part.delete() }
                val body = resp.body() ?: return Result.Failed("no-body")
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
            }

            val actual = sha256File(part)
            if (!actual.equals(expectedSha256, ignoreCase = true)) {
                part.delete()
                return Result.Failed("sha256-mismatch")
            }
            if (!part.renameTo(apk)) {
                part.copyTo(apk, overwrite = true); part.delete()
            }

            // Do NOT preflight `su` here. On QZX/YunOS boxes the app UID is
            // usually denied by stock su, while the provisioned setuid helper is
            // exactly the supported path for in-app push upgrades. RootInstaller
            // tries the helper first and falls back to su only if helper is not
            // available.
            return if (RootInstaller.install(pkg, apk)) Result.Installing
                   else Result.Failed("install-failed")
        } catch (e: Exception) {
            Log.e(TAG, "update failed: ${e.javaClass.simpleName}")
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
