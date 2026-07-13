package com.jieoz.lanmediawall.player

/**
 * Process-static, observable **connection phase** shared from [PlayerService]
 * (which owns the transport) to the UI ([SettingsActivity]) — redesign §2
 * "一眼可核对": a box that can't reach the wall must say *why*, on-screen, so
 * an operator (or Jay, remotely, from a screenshot) can self-diagnose instead of
 * only seeing "连接断开".
 *
 * Static-on-purpose, mirroring [KioskState]: the service and the settings UI are
 * different components with no direct handle to each other, and this is a tiny
 * diagnostic breadcrumb (no lifecycle weight). It resets naturally on process
 * death (reboot) and is re-populated the moment the service re-selects a
 * transport.
 */
object ConnState {

    /** Coarse phase of the transport lifecycle. Ordered roughly by progression. */
    enum class Phase {
        /** Fresh install: setup has not been saved, so no service should run yet. */
        WAITING_SETUP,
        /** Nothing selected yet (service just started). */
        STARTING,
        /** Foreground-service creation or bootstrap failed. */
        START_FAILED,
        /** No broker configured → UDP-probing the LAN for a coordinator (§14.5). */
        DISCOVERING,
        /** A broker was found/configured → dialing it as a WS client (modes A/B). */
        CONNECTING_BROKER,
        /** Broker WS is up and the §8 handshake/hello completed. */
        CONNECTED_BROKER,
        /** No broker → we are the p2p WS server, waiting for a controller (§14.3). */
        P2P_WAITING,
        /** A controller dialed into our p2p server. */
        P2P_CONNECTED,
        /** Link dropped; reconnect/backoff in progress (detail carries the reason). */
        DISCONNECTED,
    }

    @Volatile var phase: Phase = Phase.STARTING
        private set

    /** Human-readable extra (endpoint, listen port, or a failure reason). May be
     *  empty. Kept short so it fits the settings status line. */
    @Volatile var detail: String = ""
        private set

    /** Update the published phase (+ optional detail). Called by the service. */
    fun set(phase: Phase, detail: String = "") {
        this.phase = phase
        this.detail = detail
    }
}
