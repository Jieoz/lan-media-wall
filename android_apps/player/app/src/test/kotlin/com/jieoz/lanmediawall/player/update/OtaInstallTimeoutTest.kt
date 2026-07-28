package com.jieoz.lanmediawall.player.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * §OTA 现场缺陷回归。
 *
 * 现场日志(设备 c937df0cdb):
 *   `install_daemon_send ... daemon_probe=ready daemon_euid=0`
 *   4010ms 后 → `install_daemon_fail resp=unreachable` → `update_app failed`
 * 而同一台设备上两次**成功**的安装,send→reply 实测 3450ms / 3521ms。
 *
 * 客户端 INSTALL 的响应预算当时是 4000ms —— 余量只有 ~500ms。于是:
 *   1. 盒子稍忙 → soTimeout 到期 → 客户端拿到 null
 *   2. null 被写成 "unreachable"(与 4ms 前 probe=ready 直接矛盾)
 *   3. daemon 其实装成功了,但结果被报成 failed,新版本要等下次重启才生效
 *
 * 这组用例把三件事钉住:预算与真实耗时相称、超时不等于不可达、未知不等于失败。
 */
class OtaInstallTimeoutTest {

    // ---- 1. 预算必须与真实工作量相称 ----------------------------------

    @Test
    fun `install budget covers observed daemon install latency`() {
        val budget = RootInstaller.responseTimeoutMs(
            RootDaemonProtocol.installRequest(RootDaemonProtocol.CANONICAL_APK_PATH),
        )
        // 现场实测最慢一次成功安装 3521ms。旧的 4000ms 预算只剩 ~479ms 余量,
        // dexopt 稍慢就超时。要求预算至少是实测耗时的 4 倍。
        val observedWorstMs = 3521
        assertTrue(
            "INSTALL 预算 ${budget}ms 相对实测 ${observedWorstMs}ms 余量不足,盒子稍忙就会误报失败",
            budget >= observedWorstMs * 4,
        )
    }

    @Test
    fun `probe keeps the short budget`() {
        // 探针是"立刻能答"的请求,不该跟着 INSTALL 一起放宽 —— 否则死掉的 daemon
        // 会把调用方拖住几十秒。
        val probeBudget = RootInstaller.responseTimeoutMs(RootDaemonProtocol.probeRequest())
        val installBudget = RootInstaller.responseTimeoutMs(
            RootDaemonProtocol.installRequest(RootDaemonProtocol.CANONICAL_APK_PATH),
        )
        assertTrue("探针预算不应被放宽", probeBudget <= 5_000)
        assertTrue("INSTALL 预算应显著大于探针预算", installBudget > probeBudget)
    }

    // ---- 2. UNKNOWN 不是成功,也不是失败 ------------------------------

    @Test
    fun `unknown install state is not reported as ok`() {
        // 加 UNKNOWN 时最容易踩的坑:ok 原本是 `state != FAILED`,
        // 那样一加枚举值,"不知道"会立刻变成"成功"。
        val unknown = RootDaemonProtocol.InstallReply(
            RootDaemonProtocol.InstallState.UNKNOWN, "daemon-no-reply:timeout",
        )
        assertFalse("UNKNOWN 不能算成功", unknown.ok)
        assertFalse("UNKNOWN 不该触发重启语义", unknown.rebootRequired)
    }

    @Test
    fun `no reply maps to pm_install stage not a bare failed`() {
        // 断点信息必须留下来,否则控制端只看到一个没头没尾的 "failed"。
        assertEquals("pm_install", AppUpdater.stageForReason("daemon-no-reply:timeout"))
        assertEquals("pm_install", AppUpdater.stageForReason("daemon-no-reply:unreachable"))
    }

    @Test
    fun `existing stage mapping is unchanged`() {
        // 回归护栏:新增分支不能改变原有分类(daemon-not-ready 必须仍走 daemon_probe,
        // 它的前缀和 daemon: 有重叠)。
        assertEquals("daemon_probe", AppUpdater.stageForReason("daemon-not-ready:daemon-unreachable"))
        assertEquals("pm_install", AppUpdater.stageForReason("daemon:unreachable"))
        assertEquals("sha256", AppUpdater.stageForReason("sha256-mismatch"))
        assertEquals("download", AppUpdater.stageForReason("http-404"))
        assertEquals("daemon_update", AppUpdater.stageForReason("daemon-update-failed:IOException"))
    }
}
