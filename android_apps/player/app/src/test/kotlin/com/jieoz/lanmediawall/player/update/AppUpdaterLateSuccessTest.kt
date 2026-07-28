package com.jieoz.lanmediawall.player.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * §OTA "装上了却报失败" 回归。
 *
 * 现场:daemon 没在预算内回复 → 客户端报 `daemon:unreachable` → 控制端显示 failed,
 * 但设备重启后新版本其实生效了 —— 说明**安装当时就成功了**,只是回复没收到。
 *
 * 修法:没拿到回复时不猜,去问 PackageManager 真实记录的 versionCode。
 * 这组用例直接钉住 [AppUpdater.resolveUnknownInstall] 的判定,不依赖真机/网络。
 */
class AppUpdaterLateSuccessTest {

    /** 把轮询做成确定性的:每次 read 返回脚本里的下一个值,sleep 不真的睡。 */
    private fun updater(): Pair<AppUpdater, MutableList<String>> {
        val u = AppUpdater(createTempDir())
        // 虚拟时钟:sleep 只推进时钟,不真的阻塞,所以"等 dexopt"的用例毫秒级完成。
        var now = 0L
        u.clock = { now }
        u.sleeper = { ms -> now += ms }
        u.verifyIntervalMs = 1_000L
        u.verifyBudgetMs = 5_000L
        return u to mutableListOf()
    }

    @Test
    fun `late success when package manager reports the target version`() {
        val (u, log) = updater()
        // daemon 没回复,但平台已经记录了目标版本 → 这是一次**成功**的安装。
        val r = u.resolveUnknownInstall(
            detail = "daemon-no-reply:timeout",
            targetVersionCode = 1200,
            installedVersionCode = { 1200 },
            log = { log.add(it) },
        )
        assertTrue("平台已记录目标版本时必须判成功", r is AppUpdater.Result.Installing)
        assertTrue(
            "应留下可核查的证据行",
            log.any { it.contains("late_success") && it.contains("1200") },
        )
    }

    @Test
    fun `still failed when package manager keeps reporting the old version`() {
        val (u, log) = updater()
        val r = u.resolveUnknownInstall(
            detail = "daemon-no-reply:timeout",
            targetVersionCode = 1200,
            installedVersionCode = { 1199 },   // 一直是旧版本
            log = { log.add(it) },
        )
        assertTrue("平台仍是旧版本时必须判失败", r is AppUpdater.Result.Failed)
        val reason = (r as AppUpdater.Result.Failed).reason
        assertTrue("失败原因要带上核对到的真实版本,便于现场定位", reason.contains("1199"))
    }

    @Test
    fun `waits out dexopt instead of reading once`() {
        val (u, log) = updater()
        // 关键:立刻读一次会读到旧版本(dexopt 还没完)。只读一次 → 假阴性 → 把成功报成失败。
        var calls = 0
        val r = u.resolveUnknownInstall(
            detail = "daemon-no-reply:timeout",
            targetVersionCode = 1200,
            installedVersionCode = { calls++; if (calls >= 3) 1200 else 1199 },
            log = { log.add(it) },
        )
        assertTrue("应当等到 dexopt 完成后判成功", r is AppUpdater.Result.Installing)
        assertTrue("必须真的轮询多次,而不是只读一次", calls >= 3)
    }

    @Test
    fun `honest unknown when verification is unavailable`() {
        val (u, log) = updater()
        // 没有核对手段时不能假装成功,如实报失败(保守方向)。
        val r = u.resolveUnknownInstall(
            detail = "daemon-no-reply:unreachable",
            targetVersionCode = null,
            installedVersionCode = null,
            log = { log.add(it) },
        )
        assertTrue("无法核对时必须保守判失败", r is AppUpdater.Result.Failed)
    }

    @Test
    fun `bounded so it cannot hang forever`() {
        val (u, log) = updater()
        var calls = 0
        val r = u.resolveUnknownInstall(
            detail = "daemon-no-reply:timeout",
            targetVersionCode = 1200,
            installedVersionCode = { calls++; 1199 },   // 永远不到目标
            log = { log.add(it) },
        )
        assertTrue(r is AppUpdater.Result.Failed)
        // budget 5000ms / interval 1000ms → 轮询次数必须有界,不能无限等。
        assertTrue("轮询必须有界,实际 $calls 次", calls in 2..8)
    }

    @Test
    fun `stage mapping keeps the breakpoint visible`() {
        assertEquals("pm_install", AppUpdater.stageForReason("daemon-no-reply:timeout"))
    }
}
