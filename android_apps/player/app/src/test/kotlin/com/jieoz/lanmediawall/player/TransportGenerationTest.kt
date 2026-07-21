package com.jieoz.lanmediawall.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransportGenerationTest {
    @Test
    fun staleTransportCallbackCannotMutateCurrentGeneration() {
        assertFalse(ownsTransportGeneration(current = 4L, callback = 3L))
    }

    @Test
    fun currentTransportCallbackOwnsGeneration() {
        assertTrue(ownsTransportGeneration(current = 4L, callback = 4L))
    }
}
