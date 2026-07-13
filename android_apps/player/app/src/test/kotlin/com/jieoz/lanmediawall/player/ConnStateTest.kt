package com.jieoz.lanmediawall.player

import org.junit.Assert.assertEquals
import org.junit.Test

class ConnStateTest {
    @Test
    fun `fresh install is waiting for setup rather than starting`() {
        assertEquals(
            ConnState.Phase.WAITING_SETUP,
            StartupStatusPolicy.phaseFor(
                configured = false,
                servicePresent = false,
                current = ConnState.Phase.STARTING,
                startRequestedElapsedMs = 0,
                nowElapsedMs = 20_000,
            ),
        )
    }

    @Test
    fun `configured service request times out into actionable failure`() {
        assertEquals(
            ConnState.Phase.START_FAILED,
            StartupStatusPolicy.phaseFor(
                configured = true,
                servicePresent = false,
                current = ConnState.Phase.STARTING,
                startRequestedElapsedMs = 1_000,
                nowElapsedMs = 9_000,
            ),
        )
    }

    @Test
    fun `live service never gets mislabeled as failed`() {
        assertEquals(
            ConnState.Phase.STARTING,
            StartupStatusPolicy.phaseFor(
                configured = true,
                servicePresent = true,
                current = ConnState.Phase.STARTING,
                startRequestedElapsedMs = 1_000,
                nowElapsedMs = 99_000,
            ),
        )
    }

    @Test
    fun `transport progression remains untouched`() {
        assertEquals(
            ConnState.Phase.DISCOVERING,
            StartupStatusPolicy.phaseFor(
                configured = true,
                servicePresent = false,
                current = ConnState.Phase.DISCOVERING,
                startRequestedElapsedMs = 1_000,
                nowElapsedMs = 99_000,
            ),
        )
    }
}
