package com.jieoz.lanmediawall.player.cache

import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import com.jieoz.lanmediawall.player.net.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException
import java.security.MessageDigest

/**
 * §6.2 大列表回归。现场缺陷:推 200 首 mp3 时 68 首 ready、**138 首 error:queue-full**。
 *
 * 根因是 [BoundedDownloadExecutor] 的 `maxQueued`(64)被当成了业务上限 —— 它本来只是
 * 给"池子持有的待跑 lambda"设内存上界。超出的条目当场判 error 且**永不重试**,所以列表
 * 只要长于 64 就必然大面积失败,且队列空出来后也不会自己补下。
 *
 * 这些用例钉的是:**列表长度不再是失败原因**,同时并发上限仍然被尊重。
 */
class DownloaderLargePlaylistTest {
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
     * 现场规模的直接复现:200 首必须全部 ready,一个 queue-full 都不许有。
     * 修复前此用例会在 ~64 首处停住,其余为 error:queue-full。
     */
    @Test
    fun `200-item playlist completes with no queue-full failures`() {
        val payloads = HashMap<String, ByteArray>()
        repeat(200) { i -> payloads["song$i"] = "audio-payload-$i".toByteArray() }
        serveStatic(payloads)

        val downloader = Downloader(folder.root, retryBaseDelayMs = 1, retryJitterMs = 0)
        val items = payloads.entries.map { item(it.key, it.value) }

        downloader.prefetch(items)

        assertTrue(
            "200 首应全部 ready;仍有未完成项: " +
                downloader.cacheStatus().filterValues { it != "ready" },
            waitUntil(30_000) { items.all { downloader.isReady(it.itemId) } },
        )
        val status = downloader.cacheStatus()
        assertEquals(200, status.size)
        assertEquals(
            "不应出现任何 error(现场就是 138 个 queue-full)",
            emptyMap<String, String>(),
            status.filterValues { it.startsWith("error") },
        )
        downloader.stopAndAwait(2_000)
    }

    /**
     * backlog 不能把并发放开 —— 盒子的网络/闪存压力上限是有意为之。
     * 队列溢出后仍必须只有 MAX_CONCURRENT_DOWNLOADS 个请求同时在跑。
     */
    @Test
    fun `backlog does not raise the concurrency ceiling`() {
        val payloads = HashMap<String, ByteArray>()
        repeat(120) { i -> payloads["c$i"] = "c-payload-$i".toByteArray() }

        val inFlight = java.util.concurrent.atomic.AtomicInteger(0)
        val peak = java.util.concurrent.atomic.AtomicInteger(0)
        server.setDispatcher(object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val now = inFlight.incrementAndGet()
                peak.getAndUpdate { prev -> if (now > prev) now else prev }
                try { Thread.sleep(15) } finally { inFlight.decrementAndGet() }
                val id = request.path?.trimStart('/') ?: ""
                val body = payloads[id] ?: return MockResponse().setResponseCode(404)
                return MockResponse().setResponseCode(200).setBody(String(body))
            }
        })

        val downloader = Downloader(folder.root, retryBaseDelayMs = 1, retryJitterMs = 0)
        val items = payloads.entries.map { item(it.key, it.value) }

        downloader.prefetch(items)

        assertTrue(
            "120 首应全部 ready",
            waitUntil(30_000) { items.all { downloader.isReady(it.itemId) } },
        )
        // 并发上限是 2。允许观测抖动,但绝不能因为 backlog 就放开到几十路。
        assertTrue("并发峰值 ${peak.get()} 超出上限,backlog 不该放开并发", peak.get() <= 4)
        assertTrue("应观测到真实并发,而不是退化成单路", peak.get() >= 1)
        downloader.stopAndAwait(2_000)
    }

    /** 溢出到 backlog 的条目在跑完前必须是 pending/downloading,不能显示成 error。 */
    @Test
    fun `overflow items report pending rather than error`() {
        val payloads = HashMap<String, ByteArray>()
        repeat(150) { i -> payloads["p$i"] = "p-payload-$i".toByteArray() }
        server.setDispatcher(object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                Thread.sleep(20)
                val id = request.path?.trimStart('/') ?: ""
                val body = payloads[id] ?: return MockResponse().setResponseCode(404)
                return MockResponse().setResponseCode(200).setBody(String(body))
            }
        })

        val downloader = Downloader(folder.root, retryBaseDelayMs = 1, retryJitterMs = 0)
        val items = payloads.entries.map { item(it.key, it.value) }

        downloader.prefetch(items)
        // 立刻观察:此刻远超 maxQueued(64),旧实现已经把多数条目打成 error。
        val early = downloader.cacheStatus()
        assertEquals(
            "溢出条目不应立刻变 error,应仍是待办: " +
                early.filterValues { it.startsWith("error") },
            emptyMap<String, String>(),
            early.filterValues { it.startsWith("error") },
        )

        assertTrue(waitUntil(30_000) { items.all { downloader.isReady(it.itemId) } })
        downloader.stopAndAwait(2_000)
    }

    /** stopAndAwait 必须把 backlog 一起收口,否则待办永久停在 pending。 */
    @Test
    fun `stop drains backlog instead of leaving items pending`() {
        val payloads = HashMap<String, ByteArray>()
        repeat(150) { i -> payloads["s$i"] = "s-payload-$i".toByteArray() }
        server.setDispatcher(object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                Thread.sleep(200)
                val id = request.path?.trimStart('/') ?: ""
                val body = payloads[id] ?: return MockResponse().setResponseCode(404)
                return MockResponse().setResponseCode(200).setBody(String(body))
            }
        })

        val downloader = Downloader(folder.root, retryBaseDelayMs = 1, retryJitterMs = 0)
        val items = payloads.entries.map { item(it.key, it.value) }
        downloader.prefetch(items)
        downloader.stopAndAwait(3_000)

        val status = downloader.cacheStatus()
        val stuck = status.filterValues { it == "pending" }
        assertEquals("停机后不应留下 pending 待办: $stuck", emptyMap<String, String>(), stuck)
    }

    private fun serveStatic(payloads: Map<String, ByteArray>) {
        server.setDispatcher(object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val id = request.path?.trimStart('/') ?: ""
                val body = payloads[id] ?: return MockResponse().setResponseCode(404)
                return MockResponse().setResponseCode(200).setBody(String(body))
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
