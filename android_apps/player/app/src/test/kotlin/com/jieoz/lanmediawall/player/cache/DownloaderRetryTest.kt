package com.jieoz.lanmediawall.player.cache

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import com.jieoz.lanmediawall.player.net.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

class DownloaderRetryTest {
    private lateinit var server: MockWebServer
    private lateinit var folder: TemporaryFolder

    @Before fun setUp() {
        server = MockWebServer()
        server.start()
        folder = TemporaryFolder()
        folder.create()
    }

    @After fun tearDown() {
        server.shutdown()
        folder.delete()
    }

    @Test
    fun `503 retry-after resumes partial file with range and accepts 206`() {
        val bytes = "abcdefghij".toByteArray()
        server.enqueue(MockResponse().setResponseCode(503).setHeader("Retry-After", "0"))
        server.enqueue(
            MockResponse().setResponseCode(206)
                .setHeader("Content-Range", "bytes 4-9/10")
                .setBody("efghij"),
        )
        val item = item("retry", bytes)
        val downloader = Downloader(
            folder.root,
            retryBaseDelayMs = 1,
            retryMaxDelayMs = 5,
            retryJitterMs = 0,
            maxRetryAttempts = 2,
        )
        val target = downloader.localPath(item)
        File(target.parentFile, target.name + ".part").writeBytes(bytes.copyOfRange(0, 4))

        downloader.prefetchForeground(item)

        assertTrue(waitUntil { downloader.isReady(item.itemId) })
        assertEquals("ready", downloader.cacheStatus()[item.itemId])
        assertEquals(bytes.toList(), target.readBytes().toList())
        assertNotNull(server.takeRequest(1, TimeUnit.SECONDS))
        val second = server.takeRequest(1, TimeUnit.SECONDS)
        assertEquals("bytes=4-", second?.getHeader("Range"))
        downloader.stop()
    }

    @Test
    fun `stop while retrying is terminal and keeps part`() {
        server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "60"))
        val bytes = "partial-content".toByteArray()
        val item = item("stopped", bytes)
        val downloader = Downloader(
            folder.root,
            retryBaseDelayMs = 60_000,
            retryMaxDelayMs = 60_000,
            retryJitterMs = 0,
            maxRetryAttempts = 5,
        )
        val target = downloader.localPath(item)
        val part = File(target.parentFile, target.name + ".part")
        part.writeText("partial")

        downloader.prefetchForeground(item)
        assertTrue(waitUntil { downloader.cacheStatus()[item.itemId] == "retrying" })
        downloader.stop()

        assertTrue(waitUntil { downloader.cacheStatus()[item.itemId] == "error:stopped" })
        assertTrue(part.exists())
        assertEquals(1, server.requestCount)
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
