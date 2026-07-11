package com.jieoz.lanmediawall.player.media

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ThumbnailSingleFlightTest {
    @Test fun `only one capture can run until the lease is closed`() {
        val gate = ThumbnailSingleFlight()
        val first = gate.tryAcquire()

        assertTrue(first != null)
        assertFalse(gate.tryAcquire() != null)

        first!!.close()
        assertTrue(gate.tryAcquire() != null)
    }

    @Test fun `closing a lease twice does not unlock a newer capture`() {
        val gate = ThumbnailSingleFlight()
        val first = gate.tryAcquire()!!
        first.close()
        val second = gate.tryAcquire()!!

        first.close()
        assertFalse(gate.tryAcquire() != null)

        second.close()
        assertTrue(gate.tryAcquire() != null)
    }
}