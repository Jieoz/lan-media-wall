package com.jieoz.lanmediawall.player.net

import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import kotlin.concurrent.thread

/**
 * UDP discovery responder — protocol_spec §7. The Android analogue of
 * windows_player/discovery.py.
 *
 * Listens on UDP [port] (8772). When a controller/broker broadcasts a
 * `discover` envelope, we unicast back an `announce` envelope (HMAC-signed like
 * any other message, §3) carrying device_id/name/ip + broker_hint. Control
 * still flows over the broker WS; UDP is only for list refresh / IP backfill.
 *
 * Runs on its own daemon thread with a blocking socket — independent of the WS
 * client.
 */
class Discovery(
    private val psk: String,
    private val deviceId: String,
    @Volatile private var deviceName: String,
    @Volatile private var ip: String,
    @Volatile private var brokerHint: String,
    private val port: Int = 8772,
    /**
     * §14/§13/§17.3: the topology this device advertises, and the auth/key mode
     * the coordinator declares. **Null `topology` = today's broker-client path**
     * — the announce payload is byte-for-byte unchanged (device_id/name/ip/
     * broker_hint, signed with the global PSK) so modes A/B are untouched. When
     * set (e.g. "p2p" — this device IS the coordinator, §14.3), the announce
     * additionally carries `topology`/`auth_mode`/`key_mode` and is signed under
     * that auth/key mode, matching windows_player/discovery.py::DiscoveryResponder.
     */
    @Volatile private var topology: String? = null,
    private val authMode: AuthMode = AuthMode.OPTIONAL,
    private val keyMode: KeyMode = KeyMode.GLOBAL,
    private val deviceKey: ByteArray? = null,
) {
    @Volatile private var socket: DatagramSocket? = null
    @Volatile private var running = false
    private val replay = ReplayCache()

    fun start() {
        if (running) return
        running = true
        thread(name = "udp-discovery", isDaemon = true) { run() }
    }

    private fun run() {
        val sock = try {
            DatagramSocket(null).apply {
                reuseAddress = true
                broadcast = true
                soTimeout = 1000
                bind(InetSocketAddress(port))
            }
        } catch (e: Exception) {
            Log.w(TAG, "UDP discovery bind failed on $port: ${e.javaClass.simpleName}: ${e.message}")
            running = false
            return
        }
        socket = sock
        Log.i(TAG, "UDP discovery responder listening on $port topology=${topology ?: "broker"} authMode=${authMode.wire} keyMode=${keyMode.wire}")
        val buf = ByteArray(8192)
        while (running) {
            val packet = DatagramPacket(buf, buf.size)
            try {
                sock.receive(packet)
            } catch (e: java.net.SocketTimeoutException) {
                continue
            } catch (e: Exception) {
                if (!running) break else continue
            }
            handle(packet, sock)
        }
        try { sock.close() } catch (_: Exception) {}
    }

    private fun handle(packet: DatagramPacket, sock: DatagramSocket) {
        val text = String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
        val result = Envelope.verify(
            psk,
            text,
            replay = replay,
            firstConnect = true,
            authMode = authMode,
            keyMode = keyMode,
            verifyKeyFor = ::verifyKeyFor,
        )
        if (!result.ok || result.parsed == null) {
            val peek = Envelope.peekTypeFrom(text)
            Log.w(TAG, "DROP discovery inbound: reason=${result.reason} type=${peek?.first ?: "?"} from=${peek?.second ?: "?"} sigLen=${peek?.third ?: -1} authMode=${authMode.wire} keyMode=${keyMode.wire}")
            return
        }
        if (result.parsed.type != "discover") return
        val reply = makeAnnounce()
        try {
            val out = DatagramPacket(reply, reply.size, packet.address, packet.port)
            sock.send(out) // unicast reply
            Log.i(TAG, "RX discover from=${result.parsed.from} ${packet.address.hostAddress}:${packet.port}; TX announce topology=${topology ?: "broker"} broker_hint=$brokerHint")
        } catch (_: Exception) {
        }
    }

    private fun verifyKeyFor(fromIdentity: String): ByteArray? = null

    private fun makeAnnounce(): ByteArray {
        val topo = topology
        val payload = jsonObj {
            put("device_id", deviceId)
            put("device_name", deviceName)
            put("ip", ip)
            put("broker_hint", brokerHint)
            // §14/§13/§17.3: only when this device declares a topology (it is the
            // coordinator). Omitted on the broker-client path → payload (and its
            // signature) stay byte-for-byte identical to the v1.2 announce.
            if (topo != null) {
                put("topology", topo)
                put("auth_mode", authMode.wire)
                put("key_mode", keyMode.wire)
            }
        }
        val env = if (topo == null) {
            // broker-client path: unchanged — global-PSK signed (§3).
            Envelope.build(psk, "announce", "player:$deviceId", "all", payload)
        } else if (keyMode == KeyMode.DERIVED && deviceKey != null) {
            // dk-only coordinator (§17.4): sign with our own device_key.
            Envelope.buildWithDeviceKey(deviceKey, authMode, "announce", "player:$deviceId", "all", payload)
        } else {
            // coordinator: sign per the declared auth/key mode (§13/§17).
            Envelope.buildWithMode(psk, authMode, "announce", "player:$deviceId", "all", payload, keyMode = keyMode)
        }
        return Envelope.toWire(env).toByteArray(Charsets.UTF_8)
    }

    fun updateIp(newIp: String) { ip = newIp }
    fun updateBrokerHint(hint: String) { brokerHint = hint }

    fun stop() {
        running = false
        try { socket?.close() } catch (_: Exception) {}
    }

    companion object {
        private const val TAG = "lmw.Discovery"
    }
}
