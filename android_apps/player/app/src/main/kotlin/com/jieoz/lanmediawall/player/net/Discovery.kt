package com.jieoz.lanmediawall.player.net

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
            running = false
            return
        }
        socket = sock
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
        val result = Envelope.verify(psk, text, replay = replay, firstConnect = true)
        if (!result.ok || result.parsed == null) return
        if (result.parsed.type != "discover") return
        val reply = makeAnnounce()
        try {
            val out = DatagramPacket(reply, reply.size, packet.address, packet.port)
            sock.send(out) // unicast reply
        } catch (_: Exception) {
        }
    }

    private fun makeAnnounce(): ByteArray {
        val payload = jsonObj {
            put("device_id", deviceId)
            put("device_name", deviceName)
            put("ip", ip)
            put("broker_hint", brokerHint)
        }
        val env = Envelope.build(psk, "announce", "player:$deviceId", "all", payload)
        return Envelope.toWire(env).toByteArray(Charsets.UTF_8)
    }

    fun updateIp(newIp: String) { ip = newIp }
    fun updateBrokerHint(hint: String) { brokerHint = hint }

    fun stop() {
        running = false
        try { socket?.close() } catch (_: Exception) {}
    }
}
