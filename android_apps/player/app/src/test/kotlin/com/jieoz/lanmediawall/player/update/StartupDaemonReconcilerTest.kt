package com.jieoz.lanmediawall.player.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StartupDaemonReconcilerTest {
    @Test
    fun runs_reconcile_only_once_per_service_instance() {
        var calls = 0
        val logs = mutableListOf<String>()
        val reconciler = StartupDaemonReconciler(
            reconcile = { calls++; true },
            log = logs::add,
        )

        assertTrue(reconciler.runOnce())
        assertTrue(reconciler.runOnce())
        assertEquals(1, calls)
        assertTrue(logs.contains("daemon_startup_reconcile ok"))
        assertTrue(logs.contains("daemon_startup_reconcile skip=already-run"))
    }

    @Test
    fun reports_failure_without_retrying_in_same_service_instance() {
        var calls = 0
        val logs = mutableListOf<String>()
        val reconciler = StartupDaemonReconciler(
            reconcile = { calls++; false },
            log = logs::add,
        )

        assertFalse(reconciler.runOnce())
        assertFalse(reconciler.runOnce())
        assertEquals(1, calls)
        assertTrue(logs.contains("daemon_startup_reconcile failed"))
    }

    @Test
    fun contains_exceptions_and_logs_the_real_type() {
        val logs = mutableListOf<String>()
        val reconciler = StartupDaemonReconciler(
            reconcile = { throw IllegalStateException("boom") },
            log = logs::add,
        )

        assertFalse(reconciler.runOnce())
        assertTrue(logs.any { it == "daemon_startup_reconcile exception=IllegalStateException detail=boom" })
    }
}
