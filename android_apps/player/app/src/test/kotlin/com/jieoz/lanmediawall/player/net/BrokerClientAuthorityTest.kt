package com.jieoz.lanmediawall.player.net

import com.jieoz.lanmediawall.player.sync.ClockSync
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BrokerClientAuthorityTest {
    @Test
    fun default_broker_client_is_not_an_unauthenticated_ota_authority() {
        val client = brokerClient()
        assertFalse(client.operatorConfigured)
    }

    @Test
    fun only_explicit_operator_configured_broker_client_is_ota_authority() {
        val client = brokerClient(operatorConfigured = true)
        assertTrue(client.operatorConfigured)
    }

    @Test
    fun auto_discovered_plan_remains_non_authoritative_through_client_factory() {
        val plan = TransportSelector.select(
            TransportSelector.Config(
                intent = TransportSelector.Intent.AUTO,
                // Even a stale matching endpoint is not persisted operator intent.
                brokerHost = "10.10.8.108",
                brokerPort = 8770,
                useWss = false,
                configuredKeyMode = KeyMode.GLOBAL,
                hasKeyMaterial = false,
            ),
            listOf(DiscoveryDecision.Announce(
                brokerHint = "10.10.8.108:8770",
                topology = "dedicated",
                authMode = AuthMode.OPEN.wire,
                deviceId = null,
            )),
        ) as TransportSelector.Plan.Client

        val link = brokerClientForPlan(
            plan = plan,
            psk = "",
            deviceId = "and-test",
            clock = ClockSync(),
            onConnect = {},
            onMessage = { _, _, _ -> },
        )
        assertFalse(plan.configured)
        assertFalse(link.operatorConfigured)
        assertFalse(isOperatorConfiguredBrokerLink(link))
    }

    @Test
    fun persisted_broker_plan_becomes_authoritative_through_client_factory() {
        val plan = TransportSelector.select(
            TransportSelector.Config(
                intent = TransportSelector.Intent.BROKER,
                brokerHost = "10.10.8.108",
                brokerPort = 8770,
                useWss = false,
                configuredKeyMode = KeyMode.GLOBAL,
                hasKeyMaterial = true,
            ),
        ) as TransportSelector.Plan.Client

        val link = brokerClientForPlan(
            plan = plan,
            psk = "psk",
            deviceId = "and-test",
            clock = ClockSync(),
            onConnect = {},
            onMessage = { _, _, _ -> },
        )
        assertTrue(plan.configured)
        assertTrue(link.operatorConfigured)
        assertTrue(isOperatorConfiguredBrokerLink(link))
    }

    private fun brokerClient(operatorConfigured: Boolean = false) = BrokerClient(
        url = "ws://10.10.8.108:8770",
        psk = "",
        deviceId = "and-test",
        clock = ClockSync(),
        onConnect = {},
        onMessage = { _, _, _ -> },
        operatorConfigured = operatorConfigured,
    )
}
