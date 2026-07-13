package com.jieoz.lanmediawall.player.cache

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
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

        repeat(10) { index ->
            assertEquals(SubmitResult.ACCEPTED, executor.submit("item-$index", DownloadPriority.BACKGROUND) {
                val now = active.incrementAndGet()
                while (true) {
                    val old = peak.get()
                    if (now <= old || peak.compareAndSet(old, now)) break
                }
                entered.countDown()
                release.await(2, TimeUnit.SECONDS)
                active.decrementAndGet()
                finished.countDown()
            })
        }

        assertTrue(entered.await(1, TimeUnit.SECONDS))
        assertEquals(2, peak.get())
        release.countDown()
        assertTrue(finished.await(3, TimeUnit.SECONDS))
        executor.shutdownNow()
    }

    @Test
    fun `foreground promotion runs queued item before background fifo`() {
        val executor = BoundedDownloadExecutor(maxConcurrent = 1, maxQueued = 4)
        val blockerEntered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val finished = CountDownLatch(3)
        val order = Collections.synchronizedList(mutableListOf<String>())

        executor.submit("active", DownloadPriority.BACKGROUND) {
            blockerEntered.countDown(); release.await(2, TimeUnit.SECONDS); finished.countDown()
        }
        assertTrue(blockerEntered.await(1, TimeUnit.SECONDS))
        executor.submit("old-bg", DownloadPriority.BACKGROUND) { order.add("old-bg"); finished.countDown() }
        executor.submit("current", DownloadPriority.BACKGROUND) { order.add("current"); finished.countDown() }

        assertEquals(
            SubmitResult.PROMOTED,
            executor.submit("current", DownloadPriority.FOREGROUND) { throw AssertionError("duplicate ran") },
        )
        release.countDown()
        assertTrue(finished.await(2, TimeUnit.SECONDS))
        assertEquals(listOf("current", "old-bg"), order)
        executor.shutdownNow()
    }

    @Test
    fun `same item is deduplicated while queued or active`() {
        val executor = BoundedDownloadExecutor(maxConcurrent = 1, maxQueued = 2)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        executor.submit("same", DownloadPriority.BACKGROUND) { entered.countDown(); release.await() }
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        assertEquals(SubmitResult.DUPLICATE, executor.submit("same", DownloadPriority.BACKGROUND) {})
        assertEquals(SubmitResult.DUPLICATE, executor.submit("same", DownloadPriority.FOREGROUND) {})
        release.countDown()
        executor.shutdownNow()
    }

    @Test
    fun `pending bound rejects without retaining item`() {
        val executor = BoundedDownloadExecutor(maxConcurrent = 1, maxQueued = 2)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        executor.submit("active", DownloadPriority.BACKGROUND) { entered.countDown(); release.await() }
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        assertEquals(SubmitResult.ACCEPTED, executor.submit("one", DownloadPriority.BACKGROUND) {})
        assertEquals(SubmitResult.ACCEPTED, executor.submit("two", DownloadPriority.BACKGROUND) {})
        assertEquals(SubmitResult.REJECTED, executor.submit("three", DownloadPriority.BACKGROUND) {})
        assertEquals(2, executor.queued)
        assertFalse(executor.contains("three"))
        release.countDown()
        executor.shutdownNow()
    }

    @Test
    fun `shutdown cancels every queued task and interrupts active task`() {
        val executor = BoundedDownloadExecutor(maxConcurrent = 2, maxQueued = 8)
        val entered = CountDownLatch(2)
        val activeStopped = CountDownLatch(2)
        val cancelled = Collections.synchronizedList(mutableListOf<String>())
        repeat(2) { index ->
            executor.submit("active-$index", DownloadPriority.BACKGROUND, onCancelled = { cancelled.add("active-$index") }) {
                entered.countDown()
                try { CountDownLatch(1).await() } catch (_: InterruptedException) { activeStopped.countDown() }
            }
        }
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        repeat(4) { index ->
            executor.submit("queued-$index", DownloadPriority.BACKGROUND, onCancelled = { cancelled.add("queued-$index") }) {}
        }

        executor.shutdownNow()

        assertTrue(activeStopped.await(1, TimeUnit.SECONDS))
        assertEquals((0..3).map { "queued-$it" }.toSet(), cancelled.filter { it.startsWith("queued") }.toSet())
        assertEquals(0, executor.queued)
        assertTrue(executor.awaitTermination(1_000))
        assertEquals(SubmitResult.REJECTED,
            executor.submit("after-close", DownloadPriority.FOREGROUND) {})
    }
}
