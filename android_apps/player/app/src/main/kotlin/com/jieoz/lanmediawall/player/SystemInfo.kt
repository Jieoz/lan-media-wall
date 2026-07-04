package com.jieoz.lanmediawall.player

import android.content.Context
import android.content.pm.PackageManager
import android.os.Environment
import android.os.StatFs
import java.io.File

/**
 * Read-only hardware/self-check probes for the first-boot / settings page —
 * redesign §2 "一眼可核对". Pure reads, no I/O side effects, safe on API 19.
 *
 * Two jobs:
 *  - [memTotalMb] / [dataFreeMb] / [dataTotalMb]: the box's **real** RAM and
 *    /data capacity, so an operator can eyeball whether cheap 外贸盒 hardware is
 *    good enough (Jay can't debug remotely — a screenshot must tell the story).
 *    RAM comes from `/proc/meminfo` MemTotal (device-wide, always readable);
 *    storage from [StatFs] on the data dir.
 *  - [scanBloatware]: flag known PCDN-miner / background-daemon packages these
 *    boxes ship with (§junk). Visible warning only — we never uninstall or kill
 *    (4.4 permissions + risk). The list is a constant so it's trivial to extend.
 */
object SystemInfo {

    /**
     * Known junk/miner packages seen preinstalled on these 外贸/山寨 boxes. They
     * quietly burn bandwidth (PCDN) or run background daemons that steal CPU/RAM
     * from the wall. Extend this list as new ones surface — each entry is
     * `packageName to human label`.
     */
    val KNOWN_BLOATWARE: List<Pair<String, String>> = listOf(
        "com.youku.taitan.tv" to "优酷泰坦 (PCDN 带宽挖矿)",
        "com.youku.cloud.dog" to "优酷云狗 (后台云服务)",
        // room to grow: add more package names + labels as they're identified.
    )

    /** A detected junk package: the [pkg] name and its human [label]. */
    data class Bloat(val pkg: String, val label: String)

    /** Total device RAM in MiB, read from `/proc/meminfo` MemTotal (kB). Null if
     *  the file can't be read/parsed (shouldn't happen on Android). */
    fun memTotalMb(): Long? {
        return try {
            val line = File("/proc/meminfo").useLines { seq ->
                seq.firstOrNull { it.startsWith("MemTotal") }
            } ?: return null
            // "MemTotal:       2048576 kB"
            val kb = line.filter { it.isDigit() || it == ' ' }.trim()
                .split(Regex("\\s+")).firstOrNull()?.toLongOrNull() ?: return null
            kb / 1024
        } catch (_: Exception) {
            null
        }
    }

    /** Free bytes on the /data partition, as MiB. Null on failure. */
    fun dataFreeMb(): Long? = statfsMb { it.availableBytesCompat }

    /** Total bytes on the /data partition, as MiB. Null on failure. */
    fun dataTotalMb(): Long? = statfsMb { it.totalBytesCompat }

    private inline fun statfsMb(pick: (StatFs) -> Long): Long? {
        return try {
            // getDataDirectory() is /data — the internal partition the app +
            // media cache live on (install is pinned internalOnly, §6.3).
            val stat = StatFs(Environment.getDataDirectory().absolutePath)
            pick(stat) / (1024 * 1024)
        } catch (_: Exception) {
            null
        }
    }

    /** Which of [KNOWN_BLOATWARE] are actually installed on this box. */
    fun scanBloatware(context: Context): List<Bloat> {
        val pm = context.packageManager
        return KNOWN_BLOATWARE.mapNotNull { (pkg, label) ->
            if (isInstalled(pm, pkg)) Bloat(pkg, label) else null
        }
    }

    private fun isInstalled(pm: PackageManager, pkg: String): Boolean {
        return try {
            pm.getPackageInfo(pkg, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    // StatFs gained the `*Bytes` (Long) accessors at API 18; getDataDirectory
    // + minSdk 19 means they're always present, but keep the names local so the
    // call sites read cleanly.
    private val StatFs.availableBytesCompat: Long get() = availableBytes
    private val StatFs.totalBytesCompat: Long get() = totalBytes
}
