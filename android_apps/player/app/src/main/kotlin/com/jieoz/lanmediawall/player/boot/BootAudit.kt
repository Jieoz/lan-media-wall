package com.jieoz.lanmediawall.player.boot

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.File

/**
 * boot-probe forensic sink — durable, dependency-free breadcrumbs for the
 * sdk29 autostart investigation. The existing player.log only exists once
 * [com.jieoz.lanmediawall.player.PlayerService] is up, so a boot that never
 * reaches the service leaves no evidence. [BootAudit] writes a separate
 * append-only log the instant [BootReceiver] fires, before any subsystem, so
 * we can tell apart "receiver never ran", "service start threw", and
 * "activity start blocked" on the target box.
 *
 * Contract: NEVER throws on the boot path. Every disk / API touch is wrapped;
 * a failure is best-effort mirrored to logcat and swallowed. Safe API 19+.
 */
object BootAudit {

    private const val TAG = "BootAudit"
    private const val LOG_NAME = "boot_audit.log"
    /** Rotate past ~128 KB so a reboot-looping box never fills storage. */
    private const val MAX_BYTES = 128 * 1024L

    /**
     * Pure line formatter — no Android deps, unit-testable. One record per
     * line: `time_ms=<wall> elapsed_ms=<sinceBoot> event=<e> detail=<d>`.
     * `detail` is sanitized so a stray newline can never split one record
     * into two (which would corrupt the tail parse).
     */
    fun formatLine(timeMs: Long, elapsedMs: Long, event: String, detail: String): String {
        val safeEvent = sanitize(event)
        val safeDetail = sanitize(detail)
        return "time_ms=$timeMs elapsed_ms=$elapsedMs event=$safeEvent detail=$safeDetail"
    }

    private fun sanitize(s: String): String =
        s.replace('\n', ' ').replace('\r', ' ').trim()

    /**
     * Append one durable record. Best-effort mirror to logcat first (so it is
     * visible even if the filesystem write fails), then to disk. Any failure
     * is swallowed — this must never crash the boot broadcast.
     */
    fun record(context: Context, event: String, detail: String = "") {
        val line = formatLine(System.currentTimeMillis(), SystemClock.elapsedRealtime(), event, detail)
        try {
            Log.i(TAG, line)
        } catch (_: Throwable) {
        }
        try {
            val dir = File(context.filesDir, "logs")
            if (!dir.exists()) dir.mkdirs()
            val file = File(dir, LOG_NAME)
            if (file.exists() && file.length() > MAX_BYTES) {
                val rotated = File(dir, "$LOG_NAME.1")
                if (rotated.exists()) rotated.delete()
                file.renameTo(rotated)
            }
            file.appendText(line + "\n")
        } catch (_: Throwable) {
            // Storage may be full / not yet ready this early in boot. The
            // logcat mirror above is the fallback; do not propagate.
        }
    }

    /**
     * Best-effort process start reason for the enter record. API 30+ exposes
     * [ActivityManager.getHistoricalProcessExitReasons] is about exits, not
     * starts; there is no public "why did I start" on 29. We return the pid
     * and, on API 31+, the foreground-service-eligible hint. On 29 we simply
     * return the pid — callers include it in `detail` and skip gracefully.
     */
    fun startReasonDetail(context: Context): String = try {
        val pid = Process.myPid()
        val extra = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            "bg_restricted=${am?.isBackgroundRestricted}"
        } else {
            "bg_restricted=na"
        }
        "pid=$pid $extra"
    } catch (_: Throwable) {
        "pid=?"
    }
}
