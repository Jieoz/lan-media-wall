package com.jieoz.lanmediawall.player.update

/**
 * Runs the embedded-daemon reconciliation at most once for one PlayerService
 * instance. The caller owns the IO thread; this class only locks lifecycle and
 * truthful logging so retries happen on the next service/process start rather
 * than racing inside the same startup.
 */
class StartupDaemonReconciler(
    private val reconcile: () -> Boolean,
    private val log: (String) -> Unit,
) {
    private var attempted = false
    private var lastResult = false

    @Synchronized
    fun runOnce(): Boolean {
        if (attempted) {
            log("daemon_startup_reconcile skip=already-run")
            return lastResult
        }
        attempted = true
        lastResult = try {
            val ok = reconcile()
            log(if (ok) "daemon_startup_reconcile ok" else "daemon_startup_reconcile failed")
            ok
        } catch (t: Throwable) {
            log("daemon_startup_reconcile exception=${t.javaClass.simpleName} detail=${t.message ?: ""}")
            false
        }
        return lastResult
    }
}
