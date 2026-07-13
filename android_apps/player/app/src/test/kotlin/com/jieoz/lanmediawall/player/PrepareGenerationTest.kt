package com.jieoz.lanmediawall.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

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
}
