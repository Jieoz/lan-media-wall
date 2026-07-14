package com.jieoz.lanmediawall.player

/**
 * Keeps the settings diagnostics synchronized with the service lifecycle without
 * repeating the comparatively expensive root-daemon probes every one-second UI
 * tick. Only an availability edge requires a full diagnostics re-render.
 */
object DiagnosticsRefreshPolicy {
    fun shouldRefresh(previousServicePresent: Boolean, servicePresent: Boolean): Boolean =
        previousServicePresent != servicePresent
}
