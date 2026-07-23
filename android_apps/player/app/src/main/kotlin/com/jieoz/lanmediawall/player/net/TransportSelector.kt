package com.jieoz.lanmediawall.player.net

/**
 * Pure transport-selection seam — protocol_spec §14.5 (the decide-then-pick flow
 * windows_player/main.py::_discover_decision + _build_transport encode). It maps
 * a device's configuration + a UDP discovery result to a concrete [Plan] the
 * service then turns into a [BrokerClient] or a [P2pServer].
 *
 * It is split out of [com.jieoz.lanmediawall.player.PlayerService] precisely so
 * the broker→client / none→p2p-server branch is unit-testable without an Android
 * runtime, sockets, or timers — the brief's requirement.
 *
 * [Intent] is authoritative: BROKER dials the persisted endpoint, P2P always
 * starts the local server, and AUTO may adopt a discovered broker before
 * falling back to P2P. Keeping P2P distinct from AUTO is essential: clearing a
 * Broker override while that Broker is still discoverable must not immediately
 * select it again.
 *
 * The result is a pure function of its inputs — no I/O here.
 */
object TransportSelector {

    enum class Intent(val wire: String) {
        AUTO("auto"),
        BROKER("broker"),
        P2P("p2p");

        companion object {
            fun fromWire(raw: String?): Intent? = values().firstOrNull { it.wire == raw }
            fun parse(raw: String?): Intent = fromWire(raw) ?: AUTO
        }
    }

    /** What [select] resolved to. The service builds the matching transport. */
    sealed class Plan {
        /** Connect as a WS client (modes A/B). [url] is the ws(s):// endpoint. */
        data class Client(
            val url: String,
            val authMode: AuthMode,
            val keyMode: KeyMode,
            val topology: String,
            /** True only when this client endpoint came from the persisted
             *  operator-configured Broker intent, not opportunistic discovery. */
            val configured: Boolean,
        ) : Plan()

        /** Become the p2p WS server (mode C, §14.3). */
        data class P2pServer(
            val authMode: AuthMode,
            val keyMode: KeyMode,
            val listenPort: Int,
        ) : Plan()
    }

    /** The device's local configuration relevant to transport choice. */
    data class Config(
        val intent: Intent,
        val brokerHost: String,
        val brokerPort: Int,
        val useWss: Boolean,
        /** The key_mode persisted from pairing (§17.3) — the start mode for the
         *  configured-broker path before its `welcome` re-declares one. */
        val configuredKeyMode: KeyMode,
        /** True when the device holds real key material (a usable PSK or a
         *  device_key). Decides the p2p-server fallback's declared auth mode:
         *  with material → `optional` (sign when we can, interop with all);
         *  without → `open` (zero-config, §15.3). We are authoritative in p2p. */
        val hasKeyMaterial: Boolean,
        val p2pListenPort: Int = DiscoveryDecision.P2P_PORT,
    )

    /**
     * Resolve the transport [Plan] from [config] + [announces] (the UDP
     * `announce` replies a [DiscoveryProbe] collected; empty when none / probe
     * skipped). See the precedence note on the object.
     */
    fun select(
        config: Config,
        announces: List<DiscoveryDecision.Announce> = emptyList(),
    ): Plan {
        // §14.5 fallback auth for a path where *we* declare it (p2p server): a
        // device that has key material signs (`optional`), else stays open.
        val p2pAuth = if (config.hasKeyMaterial) AuthMode.OPTIONAL else AuthMode.OPEN

        if (config.intent == Intent.P2P) {
            return Plan.P2pServer(
                authMode = p2pAuth,
                keyMode = config.configuredKeyMode,
                listenPort = config.p2pListenPort,
            )
        }

        // A persisted broker intent wins. AUTO considers only discovery.
        val candidates = if (config.intent == Intent.BROKER) {
            buildList {
                add(
                    DiscoveryDecision.Announce(
                        brokerHint = "${config.brokerHost}:${config.brokerPort}",
                        topology = "dedicated",
                        // a configured player bootstraps OPTIONAL and adopts the
                        // broker's welcome mode (§13); represent that as null so
                        // decide() uses the OPTIONAL fallback below.
                        authMode = null,
                        deviceId = null,
                    ),
                )
                addAll(announces)
            }
        } else {
            announces
        }

        // configured path bootstraps OPTIONAL (BrokerClient's historical start
        // mode); unconfigured discovery uses OPEN as the §15.3 zero-config base
        // (a discovered announce that declares a mode overrides it in decide()).
        val fallbackAuth = if (config.intent == Intent.BROKER) AuthMode.OPTIONAL else AuthMode.OPEN
        return when (val d = DiscoveryDecision.decide(candidates, fallbackAuth = fallbackAuth)) {
            is DiscoveryDecision.Decision.ConnectBroker -> {
                val configured = config.intent == Intent.BROKER &&
                    d.endpoint.host == config.brokerHost && d.endpoint.port == config.brokerPort
                Plan.Client(
                    url = urlFor(d.endpoint, config, configured),
                    authMode = d.authMode,
                    // configured broker starts from the paired key_mode; a
                    // discovered one starts GLOBAL and adopts via welcome (§17.3).
                    keyMode = if (configured) config.configuredKeyMode else KeyMode.GLOBAL,
                    topology = d.topology,
                    configured = configured,
                )
            }
            is DiscoveryDecision.Decision.StartP2pServer -> Plan.P2pServer(
                authMode = p2pAuth,
                keyMode = config.configuredKeyMode,
                listenPort = config.p2pListenPort,
            )
        }
    }

    /**
     * Build the ws(s):// URL for an endpoint. WSS is only used for the
     * **configured** dedicated broker (its `use_wss` + the 8771 TLS port
     * convention); discovered/cohosted brokers are plain `ws` on their hint port
     * (mirrors windows main.py::_build_transport).
     */
    private fun urlFor(
        ep: DiscoveryDecision.BrokerEndpoint,
        config: Config,
        configured: Boolean,
    ): String {
        if (configured && config.useWss) {
            val tlsPort = if (ep.port == 8770) 8771 else ep.port
            return "wss://${ep.host}:$tlsPort"
        }
        return "ws://${ep.host}:${ep.port}"
    }
}
