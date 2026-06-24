package com.jieoz.lanmediawall.player.net

import com.jieoz.lanmediawall.player.sync.ClockSync
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * WebSocket client to the broker — protocol_spec §1, §2, §3, §8. The Android
 * analogue of windows_player/websocket_client.py.
 *
 * Responsibilities:
 *   - one long-lived WS with exponential backoff reconnect (1,2,4,…,30s, §1);
 *   - wrap outbound payloads in signed envelopes, verify inbound ones (§2/§3);
 *   - drive the time_sync handshake on connect + every 30s, feeding ClockSync;
 *   - dispatch verified inbound messages to [onMessage];
 *   - send binary frames (thumbnails, §6.4).
 *
 * Built on OkHttp's WebSocket. Transport pings are configured via
 * OkHttpClient.pingInterval (§1: 20s). On every (re)connect [onConnect] fires so
 * the owner re-hellos + the clock resets.
 */
class BrokerClient(
    @Volatile var url: String,
    private val psk: String,
    private val deviceId: String,
    private val clock: ClockSync,
    private val onConnect: () -> Unit,
    private val onMessage: (type: String, payload: Json.Obj, env: Envelope.Parsed) -> Unit,
    /** Auth mode to start with before the broker's `welcome` declares one
     *  (§13). OPTIONAL bootstrap = "verify a sig if present, accept if absent",
     *  which interoperates with open / optional / required brokers alike until
     *  we lock to the declared mode. */
    initialAuthMode: AuthMode = AuthMode.OPTIONAL,
    private val timeSyncIntervalS: Long = 30,
    private val pingIntervalS: Long = 20,
) : CoordinatorLink {
    private val from = "player:$deviceId"
    private val replay = ReplayCache()

    @Volatile override var authMode: AuthMode = initialAuthMode
        private set

    /** Adopt the auth mode the coordinator declared in `welcome`/`announce`
     *  (§13). Called by the owner once the mode is known. */
    fun setAuthMode(mode: AuthMode) { authMode = mode }

    private val client = OkHttpClient.Builder()
        .pingInterval(pingIntervalS, TimeUnit.SECONDS)
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS) // long-lived
        .build()

    @Volatile private var ws: WebSocket? = null
    @Volatile private var connected = false
    private val stopped = AtomicBoolean(false)
    private var firstConnect = true

    // pending time_sync round-trips: t1 -> t1 (correlate by t1; broker echoes it)
    private val pendingSync = ConcurrentHashMap<Long, Long>()

    private val scheduler: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "ws-scheduler").apply { isDaemon = true }
        }
    private var syncFuture: java.util.concurrent.ScheduledFuture<*>? = null
    private var backoffS = 1.0

    val isConnected: Boolean get() = connected

    override fun start() {
        connect()
    }

    private fun connect() {
        if (stopped.get()) return
        val request = Request.Builder().url(url).build()
        client.newWebSocket(request, Listener())
    }

    private inner class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            ws = webSocket
            connected = true
            backoffS = 1.0
            clock.reset() // §1: re-handshake on reconnect
            try { onConnect() } catch (_: Exception) {}
            startSyncLoop()
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            handleText(text)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            // players don't expect inbound binary; ignore defensively
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
            onDisconnected()
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            onDisconnected()
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            onDisconnected()
        }
    }

    private fun onDisconnected() {
        connected = false
        ws = null
        firstConnect = false
        stopSyncLoop()
        if (stopped.get()) return
        val delay = backoffS
        backoffS = (backoffS * 2).coerceAtMost(30.0) // §1 cap 30s
        scheduler.schedule({ connect() }, (delay * 1000).toLong(), TimeUnit.MILLISECONDS)
    }

    // --- outbound -----------------------------------------------------
    /** Build, sign, and send an envelope. Returns msg_id, or null if not
     *  connected (caller may retry after reconnect). */
    fun send(type: String, payload: Json, to: String = "broker"): String? {
        val socket = ws ?: return null
        if (!connected) return null
        val env = Envelope.build(psk, type, from, to, payload)
        val text = Envelope.toWire(env)
        return if (socket.send(text)) {
            (env.entries["msg_id"] as? Json.Str)?.value
        } else null
    }

    /** Send a raw binary frame (thumbnail JPEG, §6.4). Must follow a
     *  thumb_meta text frame sent by the caller. */
    fun sendBinary(data: ByteArray): Boolean {
        val socket = ws ?: return false
        if (!connected) return false
        return socket.send(data.toByteString())
    }

    // --- time sync (§8) ----------------------------------------------
    private fun startSyncLoop() {
        stopSyncLoop()
        syncFuture = scheduler.scheduleWithFixedDelay(
            { sendTimeSync() }, 0, timeSyncIntervalS, TimeUnit.SECONDS)
    }

    private fun stopSyncLoop() {
        syncFuture?.cancel(false)
        syncFuture = null
    }

    private fun sendTimeSync() {
        if (!connected) return
        val t1 = Envelope.nowMs()
        val payload = jsonObj { put("t1", t1) }
        val mid = send("time_sync", payload)
        if (mid != null) {
            pendingSync[t1] = t1
            if (pendingSync.size > 64) {
                val it = pendingSync.keys.iterator()
                if (it.hasNext()) { it.next(); it.remove() }
            }
        }
    }

    private fun handleText(raw: String) {
        val result = Envelope.verify(psk, raw, replay = replay, firstConnect = firstConnect)
        if (!result.ok || result.parsed == null) return
        val parsed = result.parsed
        // time_sync_ack handled internally to keep the clock authoritative
        if (parsed.type == "time_sync_ack") {
            onTimeSyncAck(parsed.payloadObj)
            return
        }
        try {
            onMessage(parsed.type, parsed.payloadObj, parsed)
        } catch (_: Exception) {
        }
    }

    private fun onTimeSyncAck(payload: Json.Obj) {
        val t4 = Envelope.nowMs()
        val e = payload.entries
        var t1 = e["t1"].asLongOrNull() ?: return
        val t2 = e["t2"].asLongOrNull() ?: return
        val t3 = e["t3"].asLongOrNull() ?: return
        // [v1.1] prefer req_msg_id correlation if present; else correlate by t1
        // (our recorded send time defends against a tampered echo). The broker
        // currently echoes t1 only, so t1 is the practical key.
        pendingSync.remove(t1)?.let { t1 = it }
        clock.addSample(t1, t2, t3, t4)
    }

    fun stop() {
        stopped.set(true)
        stopSyncLoop()
        try { ws?.close(1000, "shutdown") } catch (_: Exception) {}
        ws = null
        connected = false
        scheduler.shutdownNow()
    }
}
