package com.jieoz.lanmediawall.player.cache

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class BoundedDownloadExecutorTest {
    @Test
    fun `never runs more than configured downloads concurrently`() {
        val executor = BoundedDownloadExecutor(maxConcurrent = 2, maxQueued = 16)
        val entered = CountDownLatch(2)
        val release = CountDownLatch(1)
        val finished = CountDownLatch(10)
        val active = AtomicInteger(0)
        val peak = AtomicInteger(0)

        repeat(10) {
            executor.submit {
                val now = active.incrementAndGet()
                while (true) {
                    val old = peak.get()
                    if (now <= old || peak.compareAndSet(old, now)) break
                }
                entered.countDown()
                release.await(2, TimeUnit.SECONDS)
                active.decrementAndGet()
                finished.countDown()
            }
        }

        assertTrue("two workers should start", entered.await(1, TimeUnit.SECONDS))
        assertEquals("queued work must not exceed the bound", 2, peak.get())
        release.countDown()
        assertTrue("all queued work should drain", finished.await(3, TimeUnit.SECONDS))
        assertEquals(2, peak.get())
        executor.shutdownNow()
    }

    @Test
    fun `rejects work beyond the bounded queue instead of growing forever`() {
        val executor = BoundedDownloadExecutor(maxConcurrent = 1, maxQueued = 2)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        executor.submit { entered.countDown(); release.await(2, TimeUnit.SECONDS) }
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        assertTrue(executor.submit { })
        assertTrue(executor.submit { })
        assertEquals(false, executor.submit { })
        assertEquals(2, executor.queued)
        release.countDown()
        executor.shutdownNow()
    }
}
