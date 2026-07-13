package com.jieoz.lanmediawall.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class PrepareGenerationTest {
    @Test
    fun `new prepare invalidates old waiter`() {
        val generations = PrepareGeneration()
        val old = generations.replace()
        val current = generations.replace()
        assertFalse(generations.isCurrent(old))
        assertTrue(generations.isCurrent(current))
    }

    @Test
    fun `cancel invalidates current waiter`() {
        val generations = PrepareGeneration()
        val current = generations.replace()
        generations.cancel()
        assertFalse(generations.isCurrent(current))
    }

    @Test
    fun `replacement waits for current owned side effects and stale waiter cannot resume`() {
        val generations = PrepareGeneration()
        val old = generations.replace()
        val oldEntered = CountDownLatch(1)
        val releaseOld = CountDownLatch(1)
        val replacementReturned = CountDownLatch(1)
        val events = Collections.synchronizedList(mutableListOf<String>())
        val oldRan = AtomicBoolean(false)

        val staleWaiter = Thread {
            generations.runIfCurrent(old) {
                oldEntered.countDown()
                assertTrue(releaseOld.await(2, TimeUnit.SECONDS))
                events.add("old-prime-ready")
                oldRan.set(true)
            }
        }
        staleWaiter.start()
        assertTrue(oldEntered.await(2, TimeUnit.SECONDS))

        val replacement = Thread {
            generations.replace()
            events.add("replace-returned")
            replacementReturned.countDown()
        }
        replacement.start()

        assertFalse("replace must not cut into owned prime/ready effects",
            replacementReturned.await(100, TimeUnit.MILLISECONDS))
        releaseOld.countDown()
        staleWaiter.join(2_000)
        replacement.join(2_000)

        assertTrue(oldRan.get())
        assertEquals(listOf("old-prime-ready", "replace-returned"), events)

        // Once replacement owns the generation, a delayed old waiter performs no effects.
        assertFalse(generations.runIfCurrent(old) { events.add("stale") })
        assertEquals(listOf("old-prime-ready", "replace-returned"), events)
    }
}
