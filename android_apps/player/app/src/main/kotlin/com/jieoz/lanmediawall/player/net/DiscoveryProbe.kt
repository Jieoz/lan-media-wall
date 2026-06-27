package com.jieoz.lanmediawall.player.net

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

/**
 * Active UDP discovery probe — protocol_spec §7 + §14.5. The Android analogue of
 * windows_player/discovery_probe.py and the active counterpart to the passive
 * [Discovery] responder (which *answers* probes from controllers/brokers).
 *
 * On startup the player broadcasts a `discover` envelope and listens for
 * `announce` replies for a short window. A reply that names a `broker_hint`
 * means a coordinator exists → run as a client to it (modes A/B). Silence (or
 * only p2p peers, who carry no broker_hint) means no broker → flip to p2p server
 * mode (mode C, §14.5).
 *
 * The parse from an `announce` envelope to a [DiscoveryDecision.Announce] is
 * **pure** ([parseAnnounce]) and unit-tested; the socket broadcast/collect loop
 * ([probe]) is thin I/O around it.
 */
class DiscoveryProbe(
    private val psk: String,
    private val deviceId: String,
    private val authMode: AuthMode = AuthMode.OPEN,
    private val keyMode: KeyMode = KeyMode.GLOBAL,
    /** §17.4 dk-only end: our own device_key bytes; lets a PSK-less end still
     *  sign the probe in derived mode. Null → PSK-derivation / global. */
    private val deviceKey: ByteArray? = null,
    private val port: Int = 8772,
) {

    /**
     * Broadcast a `discover` and collect `announce` replies for [timeoutMs].
     * Returns every parsed [DiscoveryDecision.Announce] (in arrival order) so the
     * caller can hand them to [DiscoveryDecision.decide] / [TransportSelector].
     * Blocking — call off the main thread. Never throws: socket errors yield the
     * replies gathered so far (degrade to p2p / configured fallback).
     */
    fun probe(timeoutMs: Long = 3000): List<DiscoveryDecision.Announce> {
        val out = ArrayList<DiscoveryDecision.Announce>()
        val data = makeDiscover()
        val sock = try {
            DatagramSocket(null).apply {
                reuseAddress = true
                broadcast = true
                soTimeout = 500
                bind(null) // ephemeral source port; replies come back unicast
            }
        } catch (e: Exception) {
            return out
        }
        try {
            try {
                val bcast = InetAddress.getByName("255.255.255.255")
                sock.send(DatagramPacket(data, data.size, bcast, port))
            } catch (e: Exception) {
                return out
            }
            val deadline = System.currentTimeMillis() + timeoutMs
            val buf = ByteArray(8192)
            while (System.currentTimeMillis() < deadline) {
                val packet = DatagramPacket(buf, buf.size)
                try {
                    sock.receive(packet)
                } catch (e: java.net.SocketTimeoutException) {
                    continue
                } catch (e: Exception) {
                    break
                }
                val text = String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
                parseAnnounce(text)?.let { out.add(it) }
            }
        } finally {
            try { sock.close() } catch (_: Exception) {}
        }
        return out
    }

    private fun makeDiscover(): ByteArray {
        val env = if (keyMode == KeyMode.DERIVED && deviceKey != null) {
            Envelope.buildWithDeviceKey(deviceKey, authMode, "discover", "player:$deviceId", "all", jsonObj {})
        } else {
            Envelope.buildWithMode(psk, authMode, "discover", "player:$deviceId", "all", jsonObj {}, keyMode = keyMode)
        }
        return Envelope.toWire(env).toByteArray(Charsets.UTF_8)
    }

    companion object {
        /**
         * Parse one wire `announce` envelope into a [DiscoveryDecision.Announce],
         * or null if it isn't a valid announce. **Does not verify the signature**
         * — discovery is advisory (§7: control still flows over the WS, which
         * does verify); we only read the advertised fields. Tolerant of missing
         * v1.2/v1.3 fields (a v1.1 announce won't carry topology/auth/key mode).
         */
        fun parseAnnounce(raw: String): DiscoveryDecision.Announce? {
            val root = try {
                Json.parse(raw)
            } catch (e: Exception) {
                return null
            }
            val obj = root as? Json.Obj ?: return null
            if (obj.entries["type"].asString() != "announce") return null
            val payload = obj.entries["payload"] as? Json.Obj ?: return null
            val p = payload.entries
            return DiscoveryDecision.Announce(
                brokerHint = p["broker_hint"].asString(),
                topology = p["topology"].asString(),
                authMode = p["auth_mode"].asString(),
                deviceId = p["device_id"].asString(),
            )
        }
    }
}
