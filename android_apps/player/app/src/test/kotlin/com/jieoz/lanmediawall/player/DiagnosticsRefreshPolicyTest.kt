package com.jieoz.lanmediawall.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagnosticsRefreshPolicyTest {
    @Test
    fun `service becoming ready refreshes diagnostics`() {
        assertTrue(DiagnosticsRefreshPolicy.shouldRefresh(false, true))
    }

    @Test
    fun `service disappearing refreshes diagnostics`() {
        assertTrue(DiagnosticsRefreshPolicy.shouldRefresh(true, false))
    }

    @Test
    fun `unchanged service availability does not repeatedly probe diagnostics`() {
        assertFalse(DiagnosticsRefreshPolicy.shouldRefresh(false, false))
        assertFalse(DiagnosticsRefreshPolicy.shouldRefresh(true, true))
    }
}
