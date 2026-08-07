package com.jieoz.lanmediawall.player.cache

import com.jieoz.lanmediawall.player.net.Json
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * §6 缓存下载的**传输层失败重试**。
 *
 * 现场取证（96 项音乐列表，两台盒子 `d627e9ccb4a9` / `e3f4d752376d`）：这两项
 * 报 `error:ConnectException` 后**一次都没重试**就永久停在 error。当时 broker 侧
 * 只是短暂拒连（媒体口正在重启 / 瞬时端口拒绝），可另外 94 项都成功了。
 *
 * 根因：`worker()` 的重试循环只覆盖 HTTP **429/503**；任何 `IOException`
 * （`ConnectException` / `SocketTimeoutException` / 读到一半断流）都从 `catch`
 * 直接落到 `failIfCurrent(...)`，重试预算 `maxRetryAttempts` 对它完全不适用。
 *
 * 这些测试断言传输层异常与 429/503 **共用同一套退避预算**，且：
 *   - 瞬时拒连后能自愈成 ready（不需要人工重推列表）；
 *   - 预算耗尽才落 error，并保留真实异常名（诊断不能退化成 http-000）；
 *   - `stop()` 期间不得把 stop 当成可重试失败（否则永远停不下来）；
 *   - 断流重连必须带 `Range`，续传而不是从头下。
 */
class DownloaderTransportRetryTest {
    private lateinit var server: MockWebServer
    private lateinit var folder: TemporaryFolder

    @Before fun setUp() {
        server = MockWebServer()
        server.start()
        folder = TemporaryFolder()
        folder.create()
    }

    @After fun tearDown() {
        try {
            server.shutdown()
        } catch (_: IOException) {
        }
        folder.delete()
    }

    @Test
    fun `transient ConnectException is retried and the item still becomes ready`() {
        val bytes = "abcdefghij".toByteArray()
        val item = item("connect-refused", bytes)

        // 前两次直接抛 ConnectException（等价于现场的瞬时拒连），第三次交给
        // 真实 MockWebServer 完成下载。断言：不是「第一次失败就 error」。
        val attempts = AtomicInteger(0)
        val realClient = OkHttpClient()
        val flakyFactory = Call.Factory { request: Request ->
            if (attempts.getAndIncrement() < 2) {
                throwingCall(request, ConnectException("Connection refused"))
            } else {
                realClient.newCall(request)
            }
        }
        server.enqueue(MockResponse().setResponseCode(200).setBody(String(bytes)))

        val downloader = Downloader(
            folder.root,
            retryBaseDelayMs = 1,
            retryMaxDelayMs = 5,
            retryJitterMs = 0,
            maxRetryAttempts = 5,
            callFactory = flakyFactory,
        )
        val target = downloader.localPath(item)

        downloader.prefetchForeground(item)

        assertTrue(
            "transient ConnectException must be retried, not terminal",
            waitUntil { downloader.isReady(item.itemId) },
        )
        assertEquals("ready", downloader.cacheStatus()[item.itemId])
        assertEquals(bytes.toList(), target.readBytes().toList())
        assertEquals("must have consumed exactly 3 call attempts", 3, attempts.get())
        downloader.stop()
    }

    @Test
    fun `transport retries share the budget and report the real exception name`() {
        val item = item("always-refused", "zz".toByteArray())
        val attempts = AtomicInteger(0)
        val alwaysRefused = Call.Factory { request: Request ->
            attempts.incrementAndGet()
            throwingCall(request, ConnectException("Connection refused"))
        }

        val downloader = Downloader(
            folder.root,
            retryBaseDelayMs = 1,
            retryMaxDelayMs = 3,
            retryJitterMs = 0,
            maxRetryAttempts = 2,
            callFactory = alwaysRefused,
        )

        downloader.prefetchForeground(item)

        assertTrue(
            "budget exhaustion must land in error",
            waitUntil { downloader.cacheStatus()[item.itemId]?.startsWith("error:") == true },
        )
        // 诊断价值：错误里必须还看得出是 ConnectException，不能退化成通用码。
        assertEquals("error:ConnectException", downloader.cacheStatus()[item.itemId])
        // maxRetryAttempts=2 → 首次 + 2 次重试 = 3 次尝试，和 429/503 同一预算。
        assertEquals(3, attempts.get())
        downloader.stop()
    }

    @Test
    fun `stop during transport retry is terminal and never loops`() {
        val item = item("stop-wins", "abc".toByteArray())
        val attempts = AtomicInteger(0)
        val alwaysRefused = Call.Factory { request: Request ->
            attempts.incrementAndGet()
            throwingCall(request, ConnectException("Connection refused"))
        }
        val downloader = Downloader(
            folder.root,
            retryBaseDelayMs = 60_000,
            retryMaxDelayMs = 60_000,
            retryJitterMs = 0,
            maxRetryAttempts = 100,
            callFactory = alwaysRefused,
        )

        downloader.prefetchForeground(item)
        assertTrue(waitUntil { downloader.cacheStatus()[item.itemId] == "retrying" })
        downloader.stop()

        assertTrue(
            waitUntil { downloader.cacheStatus()[item.itemId] == "error:stopped" },
        )
        val seen = attempts.get()
        Thread.sleep(120)
        assertEquals("stop must end the retry loop", seen, attempts.get())
    }

    @Test
    fun `mid-stream disconnect resumes with Range instead of restarting`() {
        val bytes = "0123456789".toByteArray()
        // 第一次：声明 10 字节却只发 4 字节然后断开 → 读流阶段 IOException。
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                // 注意顺序:setBody() 会按 body 长度**重算** Content-Length,所以声明
                // 「我要发 10 字节却只发 4」必须把 header 写在 setBody 之后,否则
                // Content-Length 被改成 4,downloaded==total,根本构造不出截断。
                .setBody("0123")
                .setHeader("Content-Length", "10")
                .setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.DISCONNECT_AT_END),
        )
        // 第二次：应带 Range: bytes=4- 续传剩余 6 字节。
        server.enqueue(
            MockResponse().setResponseCode(206)
                .setHeader("Content-Range", "bytes 4-9/10")
                .setBody("456789"),
        )

        val item = item("stream-cut", bytes)
        val downloader = Downloader(
            folder.root,
            retryBaseDelayMs = 1,
            retryMaxDelayMs = 5,
            retryJitterMs = 0,
            maxRetryAttempts = 3,
        )
        val target = downloader.localPath(item)

        downloader.prefetchForeground(item)

        assertTrue(
            "a cut stream must be retried, not failed outright",
            waitUntil(6_000) { downloader.isReady(item.itemId) },
        )
        assertEquals(bytes.toList(), target.readBytes().toList())
        assertNotNull(server.takeRequest(2, TimeUnit.SECONDS))
        val second = server.takeRequest(2, TimeUnit.SECONDS)
        assertEquals("bytes=4-", second?.getHeader("Range"))
        downloader.stop()
    }

    /** 一个 execute() 必抛指定异常的 Call，用来注入传输层失败。 */
    private fun throwingCall(request: Request, error: IOException): Call {
        val delegate = OkHttpClient().newCall(request)
        return object : Call {
            @Volatile private var canceled = false
            override fun request(): Request = request
            override fun execute(): okhttp3.Response = throw error
            override fun enqueue(responseCallback: okhttp3.Callback) =
                responseCallback.onFailure(this, error)
            override fun cancel() { canceled = true }
            override fun isExecuted(): Boolean = false
            override fun isCanceled(): Boolean = canceled
            override fun timeout(): okio.Timeout = delegate.timeout()
            @Suppress("USELESS_ELVIS")
            override fun clone(): Call = delegate.clone() ?: delegate
        }
    }

    private fun item(id: String, bytes: ByteArray) = MediaItem(
        itemId = id,
        type = "video",
        name = "$id.bin",
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
