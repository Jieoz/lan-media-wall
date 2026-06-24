package com.jieoz.lanmediawall.player.net

/**
 * Topology auto-discovery decision — protocol_spec §14.5 (+§14.2/§14.3).
 *
 * On start the player UDP-broadcasts a `discover` and collects `announce`
 * replies (§7). What it does next is a **pure function** of those replies:
 *
 *   - a coordinator announced a usable `broker_hint` (dedicated mode A, or a
 *     cohosted broker mode B) → connect to it as a WS **client** (today's path);
 *   - **nothing usable** found → role-flip into **p2p server** mode (§14.3):
 *     run a WS server on 8770 and wait for the controller to dial in.
 *
 * Keeping the decision pure (no sockets, no timers) makes the broker→client /
 * none→p2p-server branch unit-testable, which the brief requires.
 */
object DiscoveryDecision {

    /** A parsed UDP `announce` reply (the fields §7/§13/§14 put on the wire). */
    data class Announce(
        val brokerHint: String?,   // "host:port" of a broker (modes A/B), or null
        val topology: String?,     // "dedicated" | "cohosted" | "p2p" (diagnostic)
        val authMode: String?,     // "open" | "optional" | "required"
        val deviceId: String?,     // present when a *player* announced (p2p peer)
    )

    /** Where to connect a broker. */
    data class BrokerEndpoint(val host: String, val port: Int)

    sealed class Decision {
        /** A broker was found — connect as a client (modes A/B). */
        data class ConnectBroker(
            val endpoint: BrokerEndpoint,
            val authMode: AuthMode,
            val topology: String,
        ) : Decision()

        /** No broker — become the p2p WS server (mode C, §14.3). */
        data class StartP2pServer(val authMode: AuthMode) : Decision()
    }

    const val DEFAULT_BROKER_PORT = 8770
    const val P2P_PORT = 8770

    /**
     * Decide the topology from collected announces.
     *
     * A reply counts as "a broker" when it carries a parseable `broker_hint`
     * AND its topology is not explicitly `p2p` (a p2p peer player may echo a
     * self broker_hint; we don't treat that as a coordinator). The first such
     * reply wins (callers gather in arrival order; the nearest tends to arrive
     * first). With no broker we go p2p-server.
     *
     * @param fallbackAuth the locally configured auth mode, used when the chosen
     *   path doesn't declare one (or for the p2p-server case where *we* are the
     *   one that would declare it). Defaults to OPEN per §15.3.
     */
    fun decide(
        announces: List<Announce>,
        fallbackAuth: AuthMode = AuthMode.OPEN,
    ): Decision {
        for (a in announces) {
            if (a.topology?.trim()?.lowercase() == "p2p") continue
            val ep = parseBrokerHint(a.brokerHint) ?: continue
            val mode = a.authMode?.let { AuthMode.parse(it) } ?: fallbackAuth
            val topo = a.topology?.trim()?.takeIf { it.isNotEmpty() } ?: "dedicated"
            return Decision.ConnectBroker(ep, mode, topo)
        }
        return Decision.StartP2pServer(fallbackAuth)
    }

    /**
     * Parse a `broker_hint` ("host:port" or bare "host") into an endpoint, or
     * null if there's no usable host. A missing/invalid port falls back to
     * [DEFAULT_BROKER_PORT]. IPv6 with explicit port isn't used on this LAN, so
     * we split on the **last** colon to be safe with bare IPv4/hostnames.
     */
    fun parseBrokerHint(hint: String?): BrokerEndpoint? {
        val h = hint?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val colon = h.lastIndexOf(':')
        if (colon < 0) return BrokerEndpoint(h, DEFAULT_BROKER_PORT)
        val host = h.substring(0, colon).trim()
        if (host.isEmpty()) return null
        val port = h.substring(colon + 1).trim().toIntOrNull()?.takeIf { it in 1..65535 }
            ?: DEFAULT_BROKER_PORT
        return BrokerEndpoint(host, port)
    }
}
