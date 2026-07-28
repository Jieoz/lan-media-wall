package com.jieoz.lanmediawall.player.cache

import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import com.jieoz.lanmediawall.player.net.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * §6.5 「删歌后保存列表卡很久」回归。
 *
 * 现场:96 首音乐已全部缓存在盒子上,删掉一首再保存,控制端要等十几秒才回结果。
 *
 * 根因不是删除逻辑,而是**每次列表变更都把整个列表重新哈希一遍**:
 * `prefetch → ensureEntryAndStart` 对每个已在磁盘上的文件调 `sha256File`(整文件读),
 * 而且是在 `synchronized(this)` 里、由接收线程同步跑。校验本身必须保留(只比 size 会把
 * 截断文件当可播 → 黑屏),但不该重复做。
 *
 * 观测量是 [Downloader.sha256ComputeCount] —— 真实发生的全文件哈希次数。
 */
class DownloaderRehashTest {
    private lateinit var server: MockWebServer
    private lateinit var folder: TemporaryFolder

    @Before fun setUp() {
        server = MockWebServer()
        server.start()
        folder = TemporaryFolder()
        folder.create()
    }

    @After fun tearDown() {
        try { server.shutdown() } catch (_: IOException) {}
        folder.delete()
    }

    /**
     * 核心回归:删掉一首后重新保存,其余未变动的条目**一次哈希都不该重算**。
     * 修复前 = 11 次(整个列表重新读一遍);修复后 = 0 次。
     */
    @Test
    fun `re-saving after a deletion does not re-hash unchanged files`() {
        val payloads = LinkedHashMap<String, ByteArray>()
        repeat(12) { i -> payloads["t$i"] = "payload-$i-${"x".repeat(64)}".toByteArray() }
        serveStatic(payloads)

        val downloader = Downloader(folder.root, retryBaseDelayMs = 1, retryJitterMs = 0)
        val items = payloads.entries.map { item(it.key, it.value) }

        downloader.prefetch(items)
        assertTrue("首次应全部 ready", waitUntil(30_000) {
            items.all { downloader.isReady(it.itemId) }
        })

        // 模拟"删一首后保存":其余 11 首内容与磁盘文件都没变。
        val trimmed = items.drop(1)
        val before = downloader.sha256ComputeCount()
        downloader.prefetch(trimmed)
        assertTrue("第二次应仍然全部 ready", waitUntil(10_000) {
            trimmed.all { downloader.isReady(it.itemId) }
        })

        assertEquals(
            "内容未变的重复保存不该重算任何哈希(修复前会重算 ${trimmed.size} 次)",
            0L, downloader.sha256ComputeCount() - before,
        )
        downloader.stopAndAwait(2_000)
    }

    /**
     * 内存索引被清掉(模拟重启后 restoreReadyFromDisk 的路径)后仍不该重算:
     * 备忘录按**文件身份**命中,与内存索引无关。
     */
    @Test
    fun `restore after index loss reuses the memo`() {
        val payloads = LinkedHashMap<String, ByteArray>()
        repeat(8) { i -> payloads["r$i"] = "restore-$i-${"y".repeat(64)}".toByteArray() }
        serveStatic(payloads)

        val downloader = Downloader(folder.root, retryBaseDelayMs = 1, retryJitterMs = 0)
        val items = payloads.entries.map { item(it.key, it.value) }

        downloader.prefetch(items)
        assertTrue("首次应全部 ready", waitUntil(30_000) {
            items.all { downloader.isReady(it.itemId) }
        })

        downloader.pruneEntries(items.map { it.itemId })  // 丢掉内存索引
        val before = downloader.sha256ComputeCount()
        val restored = downloader.restoreReadyFromDisk(items)

        assertEquals("应全部从磁盘恢复", items.size, restored)
        assertEquals(
            "文件没变,恢复不该重算哈希",
            0L, downloader.sha256ComputeCount() - before,
        )
        downloader.stopAndAwait(2_000)
    }

    /**
     * 省开销不能牺牲安全:文件在背后被改坏(长度/mtime 变化)后备忘录必须失效,
     * 重新校验并拒绝该文件,而不是继续信任上次结论。
     */
    @Test
    fun `memo is invalidated when the file changes on disk`() {
        val payloads = mapOf("song" to "good-audio-payload".toByteArray())
        serveStatic(payloads)

        val downloader = Downloader(folder.root, retryBaseDelayMs = 1, retryJitterMs = 0)
        val it0 = item("song", payloads.getValue("song"))

        downloader.prefetch(listOf(it0))
        assertTrue("应先 ready", waitUntil(10_000) { downloader.isReady("song") })

        val onDisk = downloader.readyPaths()["song"]
        assertTrue("应能定位已 ready 的文件", onDisk != null && onDisk.exists())
        downloader.pruneEntries(listOf("song"))
        // 关键:**等长**篡改。长度变了 quickOk 会先挡掉,根本走不到哈希 —— 那验不到备忘录。
        // 只有等长损坏(截断后恰好补齐、位翻转)才是必须靠 sha256 才能发现的情形,
        // 也正是 B2 黑屏的真实形态。
        val original = payloads.getValue("song")
        val tampered = original.copyOf()
        tampered[0] = (tampered[0] + 1).toByte()
        onDisk!!.writeBytes(tampered)
        assertEquals("篡改必须等长", original.size.toLong(), onDisk.length())
        Thread.sleep(20)

        // 服务器这次拒绝提供内容:能否 ready 完全取决于是否重新校验了磁盘文件。
        server.setDispatcher(object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                MockResponse().setResponseCode(500)
        })
        val before = downloader.sha256ComputeCount()
        downloader.prefetch(listOf(it0))
        Thread.sleep(400)

        assertTrue(
            "文件身份变了必须真的重新算一次哈希",
            downloader.sha256ComputeCount() > before,
        )
        assertFalse(
            "被改坏的文件绝不能因为备忘录而被当成 ready",
            downloader.isReady("song"),
        )
        downloader.stopAndAwait(2_000)
    }

    /**
     * 哈希不得在 downloader 的监视器内进行。
     *
     * 探针必须选一个**真的要拿这把锁**的入口 —— `cacheStatus()` 读的是
     * ConcurrentHashMap,根本不进监视器,用它做探针永远测不出锁竞争(第一版就错在这里,
     * 变异验证时它照样通过)。`enforceQuota()` 是 `@Synchronized`,才是有效探针。
     */
    @Test
    fun `hashing does not hold the downloader monitor`() {
        val big = ByteArray(48 * 1024 * 1024) { (it % 253).toByte() }
        serveStatic(mapOf("big" to big))

        val downloader = Downloader(folder.root, retryBaseDelayMs = 1, retryJitterMs = 0)
        val bigItem = item("big", big)

        downloader.prefetch(listOf(bigItem))
        assertTrue("大文件应先缓存好", waitUntil(60_000) { downloader.isReady("big") })

        // 清内存索引 + 改 mtime 让备忘录失效,强制下一次 prefetch 真算一遍哈希。
        downloader.pruneEntries(listOf("big"))
        val target = downloader.localPath(bigItem)
        target.setLastModified(System.currentTimeMillis() - 60_000)

        // enforceQuota 在 quota=0(unlimited)时直接 return,不会进临界区 —— 必须配一个
        // 足够大的配额,让它真的走完扫描并持锁,否则探针又变成空转。
        downloader.configureQuota(1024L * 1024 * 1024, emptySet())

        val worstUs = AtomicLong(0)
        val stop = AtomicBoolean(false)
        val prober = Thread {
            while (!stop.get()) {
                val t0 = System.nanoTime()
                downloader.enforceQuota()   // @Synchronized → 真的与哈希争同一把锁
                val us = (System.nanoTime() - t0) / 1000
                worstUs.getAndUpdate { prev -> if (us > prev) us else prev }
                try { Thread.sleep(2) } catch (_: InterruptedException) { return@Thread }
            }
        }
        prober.start()
        val before = downloader.sha256ComputeCount()
        val t0 = System.nanoTime()
        downloader.prefetch(listOf(bigItem))
        stop.set(true)
        prober.join(2_000)
        val hashUs = (System.nanoTime() - t0) / 1000

        assertTrue(
            "本用例前提是确实发生了一次哈希",
            downloader.sha256ComputeCount() > before,
        )
        // 阈值不写死:与"这台机器上这次哈希实际花了多久"比较。哈希在锁里时,探针必然被
        // 拖到与哈希同量级(实测占其大半);在锁外时,探针远小于它。取 1/3 作判据。
        assertTrue(
            "哈希不该占住监视器:探针最坏 ${worstUs.get() / 1000} ms,本次哈希约 ${hashUs / 1000} ms",
            worstUs.get() < hashUs / 3,
        )
        downloader.stopAndAwait(2_000)
    }

    // --- helpers ------------------------------------------------------
    private fun serveStatic(payloads: Map<String, ByteArray>) {
        server.setDispatcher(object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val id = request.path?.trimStart('/') ?: ""
                val body = payloads[id] ?: return MockResponse().setResponseCode(404)
                return MockResponse().setResponseCode(200)
                    .setBody(okio.Buffer().write(body))
            }
        })
    }

    private fun item(id: String, bytes: ByteArray) = MediaItem(
        itemId = id,
        type = "audio",
        name = "$id.mp3",
        url = server.url("/$id").toString(),
        size = bytes.size.toLong(),
        sha256 = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) },
        durationMs = null,
        loop = false,
        raw = Json.Obj(emptyMap()),
    )

    private fun waitUntil(timeoutMs: Long = 3000, predicate: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (predicate()) return true
            Thread.sleep(10)
        }
        return predicate()
    }
}
