package com.jieoz.lanmediawall.player

/** Pure startup-state classifier used by the no-ADB settings diagnostics. */
object StartupStatusPolicy {
    const val SERVICE_START_TIMEOUT_MS = 8_000L

    fun phaseFor(
        configured: Boolean,
        servicePresent: Boolean,
        current: ConnState.Phase,
        startRequestedElapsedMs: Long,
        nowElapsedMs: Long,
    ): ConnState.Phase {
        if (!configured && !servicePresent && startRequestedElapsedMs <= 0L) {
            return ConnState.Phase.WAITING_SETUP
        }
        if (
            current == ConnState.Phase.STARTING &&
            !servicePresent &&
            startRequestedElapsedMs > 0L &&
            nowElapsedMs - startRequestedElapsedMs >= SERVICE_START_TIMEOUT_MS
        ) {
            return ConnState.Phase.START_FAILED
        }
        return current
    }
}
