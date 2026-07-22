package com.jieoz.lanmediawall.player.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TransportSelectorTest {
    @Test fun `cleared broker config restores p2p server even when key material remains`() {
        val plan = TransportSelector.select(
            TransportSelector.Config(
                isConfigured = false,
                brokerHost = "",
                brokerPort = 8770,
                useWss = false,
                configuredKeyMode = KeyMode.GLOBAL,
                hasKeyMaterial = true,
            ),
            announces = emptyList(),
        )

        assertTrue(plan is TransportSelector.Plan.P2pServer)
        val server = plan as TransportSelector.Plan.P2pServer
        assertEquals(DiscoveryDecision.P2P_PORT, server.listenPort)
        assertEquals(AuthMode.OPTIONAL, server.authMode)
    }

    @Test fun `configured broker remains the authoritative client endpoint`() {
        val plan = TransportSelector.select(
            TransportSelector.Config(
                isConfigured = true,
                brokerHost = "10.10.8.108",
                brokerPort = 8770,
                useWss = false,
                configuredKeyMode = KeyMode.GLOBAL,
                hasKeyMaterial = true,
            ),
            announces = emptyList(),
        )

        assertEquals(
            TransportSelector.Plan.Client(
                url = "ws://10.10.8.108:8770",
                authMode = AuthMode.OPTIONAL,
                keyMode = KeyMode.GLOBAL,
                topology = "dedicated",
            ),
            plan,
        )
    }
}
