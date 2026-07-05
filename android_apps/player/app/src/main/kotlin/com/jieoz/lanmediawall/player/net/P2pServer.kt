package com.jieoz.lanmediawall.player.net

import android.util.Log
import com.jieoz.lanmediawall.player.sync.ClockSync
import java.io.BufferedInputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * p2p server-mode transport — protocol_spec §14.3. The Android analogue of
 * windows_player/p2p_server.py.
 *
 * Mode C: no broker exists, so the controller becomes the coordinator and dials
 * each player directly. The player runs a WS **server** on 8770 instead of
 * dialing out. Everything else (playback / cache / status / three-phase
 * handshake response) is unchanged — only the transport *role* and the *clock
 * source* flip:
 *
 *   - On controller connect we answer `welcome` with `topology:"p2p"` (we play
 *     the broker's welcome role, §14.3), declaring our [authMode]/[keyMode]
 *     (the coordinator — *us* in p2p — is authoritative, §13/§17.3).
 *   - **Controller = master clock** (§14.3). We still run the §8 handshake to
 *     learn our offset to it: we *send* `time_sync` to the controller and feed
 *     its `time_sync_ack` into [ClockSync], exactly as against a broker. If a
 *     controller instead *sends* us a `time_sync` (treating us as a peer), we
 *     answer `time_sync_ack` echoing its t1 — harmless and robust either way.
 *   - Inbound `prepare`/`play_at`/controls dispatch through the *same*
 *     [onMessage] handler the player already uses against a broker.
 *
 * Implements [CoordinatorLink] so [com.jieoz.lanmediawall.player.PlayerService]
 * swaps transports without touching its protocol logic. `to` addressing stays
 * "broker" on outbound frames (§14.3: the connected controller plays the broker
 * role), so the same status/ready/ack/thumb frames work byte-for-byte.
 *
 * OkHttp only ships a WS *client*, so the server side is hand-rolled on a plain
 * [ServerSocket] + [WsHandshake] (RFC6455 opening handshake) + [WsFrame] (frame
 * codec). One controller at a time (§14.4): a second controller is rejected with
 * WS close code 1013, mirroring p2p_server.py.
 */
class P2pServer(
    private val psk: String,
    private val deviceId: String,
    private val groupId: String,
    private val clock: ClockSync,
    private val onConnect: () -> Unit,
    private val onMessage: (type: String, payload: Json.Obj, env: Envelope.Parsed) -> Unit,
    /** §2 可见性:入站帧因验签/时效/重放被丢弃时回调(带 [Envelope.Reason])。
     *  让 PlayerService 把"已连接但持续丢帧"反映到 [com.jieoz.lanmediawall.player.ConnState]
     *  与设置页,不再误报"已连接"。默认 no-op(单测/内部调用无需关心)。 */
    private val onInboundDrop: (reason: Envelope.Reason, type: String?) -> Unit = { _, _ -> },
    /** Auth mode we declare as coordinator (§13). In p2p *we* are authoritative,
     *  so unlike [BrokerClient] this is not a bootstrap that gets overwritten by
     *  a welcome — it is the mode for the whole session. */
    initialAuthMode: AuthMode = AuthMode.OPEN,
    /** Key mode we declare as coordinator (§17.3). */
    initialKeyMode: KeyMode = KeyMode.GLOBAL,
    /** §17.4 dk-only end: our own `device_key` bytes (from the pairing QR `dk`).
     *  When present we sign with it directly and never need the PSK. */
    private val deviceKey: ByteArray? = null,
    private val listenHost: String = "0.0.0.0",
    private val listenPort: Int = DiscoveryDecision.P2P_PORT,
    private val timeSyncIntervalS: Long = 30,
) : CoordinatorLink {

    private val from = "player:$deviceId"
    private val replay = ReplayCache()

    @Volatile override var authMode: AuthMode = initialAuthMode
        private set

    @Volatile var keyMode: KeyMode = initialKeyMode
        private set

    // the single connected controller (§14.4) — its socket + output stream.
    private val active = AtomicReference<Conn?>(null)
    @Volatile private var server: ServerSocket? = null
    private val stopped = AtomicBoolean(false)
    private var firstConnect = true

    // pending time_sync round-trips, correlated by msg_id (we are the prober).
    private val pendingSync = ConcurrentHashMap<String, Long>()

    private val scheduler: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "p2p-scheduler").apply { isDaemon = true }
        }
    private var syncFuture: ScheduledFuture<*>? = null

    /** One controller connection: the socket + a lock guarding ordered writes. */
    private class Conn(val socket: Socket, val out: OutputStream) {
        val writeLock = Any()
    }

    override val isConnected: Boolean
        get() = active.get()?.socket?.isClosed == false

    override fun start() {
        if (stopped.get()) return
        val srv = try {
            ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(listenHost, listenPort))
            }
        } catch (e: Exception) {
            // §14.3: cannot bind 8770 (port busy / no permission). Surface via a
            // dead link rather than crashing — PlayerService keeps running, the
            // status loop simply has no peer. Mirrors p2p_server.py's bind-fail.
            return
        }
        server = srv
        thread(name = "p2p-accept", isDaemon = true) { acceptLoop(srv) }
    }

    private fun acceptLoop(srv: ServerSocket) {
        while (!stopped.get()) {
            val socket = try {
                srv.accept()
            } catch (e: Exception) {
                if (stopped.get()) break else continue
            }
            // each controller handled on its own thread so a rejected second
            // controller (1013) never blocks the accept loop or the active one.
            thread(name = "p2p-conn", isDaemon = true) { handleController(socket) }
        }
    }

    private fun handleController(socket: Socket) {
        try {
            socket.tcpNoDelay = true
            val input = BufferedInputStream(socket.getInputStream())
            val out = socket.getOutputStream()
            // --- RFC6455 opening handshake (§14.3) ------------------------
            val head = readHandshakeHead(input) ?: run { socket.close(); return }
            val req = WsHandshake.parseRequest(head)
            val peer = socket.remoteSocketAddress?.toString() ?: "?"
            val key = req?.takeIf { it.isUpgrade }?.key ?: run {
                // not a WS upgrade — reject politely and drop.
                Log.w(TAG, "reject non-WS request from $peer")
                try { out.write(BAD_REQUEST.toByteArray(Charsets.UTF_8)); out.flush() } catch (_: Exception) {}
                socket.close(); return
            }
            WsFrame.write(out, WsHandshake.responseFor(key).toByteArray(Charsets.UTF_8))
            Log.i(TAG, "WS handshake OK from $peer (authMode=${authMode.wire} keyMode=${keyMode.wire})")

            // --- single-controller guard (§14.4) --------------------------
            val conn = Conn(socket, out)
            if (!active.compareAndSet(null, conn)) {
                // a controller is already connected; reject this extra one with
                // close code 1013 (try again later), mirroring p2p_server.py.
                Log.w(TAG, "reject 2nd controller $peer (1013): one already connected")
                try {
                    WsFrame.write(out, WsFrame.encodeClose(1013))
                } catch (_: Exception) {}
                socket.close()
                return
            }
            Log.i(TAG, "controller connected: $peer")

            clock.reset() // §1: re-handshake on every (re)connect
            replay.clear() // §3: fresh replay window per connection (no stale DUPs)
            firstConnect = true // §3: widen freshness window for the first frame
            // we are the coordinator now — send welcome immediately (§14.3).
            sendOn(conn, "welcome", buildWelcomePayload())
            try { onConnect() } catch (_: Exception) {}
            startSyncLoop()
            try {
                recvLoop(conn, input)
            } finally {
                stopSyncLoop()
                active.compareAndSet(conn, null)
                firstConnect = false
                Log.i(TAG, "controller disconnected: $peer")
                try { socket.close() } catch (_: Exception) {}
            }
        } catch (e: Exception) {
            Log.w(TAG, "controller conn error: ${e.javaClass.simpleName}: ${e.message}")
            try { socket.close() } catch (_: Exception) {}
            active.updateAndGet { if (it?.socket === socket) null else it }
        }
    }

    /**
     * Read the HTTP request head (up to and including the CRLFCRLF blank line)
     * one byte at a time. Returns null on EOF before the terminator or if the
     * head exceeds [MAX_HEAD] bytes (defensive — a real WS handshake is tiny).
     */
    private fun readHandshakeHead(input: BufferedInputStream): String? {
        val buf = StringBuilder()
        while (buf.length < MAX_HEAD) {
            val b = input.read()
            if (b < 0) return null
            buf.append(b.toChar())
            if (buf.length >= 4 &&
                buf[buf.length - 4] == '\r' && buf[buf.length - 3] == '\n' &&
                buf[buf.length - 2] == '\r' && buf[buf.length - 1] == '\n'
            ) {
                return buf.toString()
            }
            // tolerate bare-LF terminators too (\n\n).
            if (buf.length >= 2 &&
                buf[buf.length - 2] == '\n' && buf[buf.length - 1] == '\n'
            ) {
                return buf.toString()
            }
        }
        return null
    }

    private fun recvLoop(conn: Conn, input: BufferedInputStream) {
        while (!stopped.get() && !conn.socket.isClosed) {
            val frame = try {
                WsFrame.readFrame(input)
            } catch (e: Exception) {
                // §2 可见性:区分断开原因(异常 read vs 干净 EOF vs close 帧),
                // 否则\"连上又断\"到底谁先挂无从判断。
                Log.w(TAG, "recv ended: read error ${e.javaClass.simpleName}: ${e.message}")
                break
            } ?: run { Log.i(TAG, "recv ended: clean EOF (peer closed socket)"); null } ?: break
            when {
                frame.isClose -> {
                    Log.i(TAG, "recv ended: controller sent CLOSE frame")
                    try { synchronized(conn.writeLock) { WsFrame.write(conn.out, WsFrame.encodeClose(1000)) } } catch (_: Exception) {}
                    break
                }
                frame.isPing -> {
                    try { synchronized(conn.writeLock) { WsFrame.write(conn.out, WsFrame.encodePong(frame.payload)) } } catch (_: Exception) {}
                }
                frame.isPong -> { /* transport keepalive ack — ignore */ }
                frame.isText -> handleText(frame.text())
                frame.isBinary -> { /* controller→player binary is unused (§6.4) */ }
                else -> { /* continuation/unknown — ignore */ }
            }
        }
    }

    /**
     * The `welcome` we (acting as coordinator) send the controller (§14.3).
     * Declares topology:"p2p", our auth_mode + key_mode so the controller adapts
     * (§13/§17.3). `server_time` is our local clock — but the controller is
     * authoritative for sync (§14.3), so it is diagnostic only. Mirrors
     * p2p_server.py::build_welcome_payload.
     */
    private fun buildWelcomePayload(): Json.Obj = jsonObj {
        put("assigned", true)
        put("server_time", Envelope.nowMs())
        put("v", Envelope.PROTOCOL_VERSION)
        put("group_id", groupId)
        put("topology", "p2p")
        put("auth_mode", authMode.wire)
        put("key_mode", keyMode.wire)
    }

    // --- outbound (CoordinatorLink) ----------------------------------
    /** Build, sign (per [authMode]/[keyMode]), and send an envelope to the
     *  connected controller. `to` stays "broker" by default (§14.3: the
     *  controller plays the broker role). Returns msg_id, or null if no
     *  controller is connected. */
    override fun send(type: String, payload: Json, to: String): String? {
        val conn = active.get() ?: return null
        return sendOn(conn, type, payload, to)
    }

    private fun sendOn(conn: Conn, type: String, payload: Json, to: String = "broker"): String? {
        if (conn.socket.isClosed) return null
        val env = buildOutbound(type, payload, to)
        val text = Envelope.toWire(env)
        return try {
            synchronized(conn.writeLock) {
                WsFrame.write(conn.out, WsFrame.encodeText(text))
            }
            // §2 可见性:TX 侧此前全无日志,welcome/time_sync 有没有真发出去看不到,
            // 是\"只见 RX 不见 TX\"盲区的元凶。心跳类(time_sync)降噪到 debug。
            if (type == "time_sync" || type == "time_sync_ack") {
                Log.d(TAG, "TX $type -> $to")
            } else {
                Log.i(TAG, "TX $type -> $to")
            }
            (env.entries["msg_id"] as? Json.Str)?.value
        } catch (e: Exception) {
            Log.w(TAG, "TX $type FAILED: ${e.javaClass.simpleName}: ${e.message}")
            null
        }
    }

    private fun buildOutbound(type: String, payload: Json, to: String): Json.Obj =
        if (keyMode == KeyMode.DERIVED && deviceKey != null) {
            // dk-only end (§17.4): sign directly with our stored device_key —
            // byte-identical to deriving HMAC(PSK, from) but we never hold PSK.
            Envelope.buildWithDeviceKey(deviceKey, authMode, type, from, to, payload)
        } else {
            Envelope.buildWithMode(psk, authMode, type, from, to, payload, keyMode = keyMode)
        }

    /** Send a raw binary frame (thumbnail JPEG, §6.4) to the controller. Must
     *  follow a thumb_meta text frame sent by the caller. */
    override fun sendBinary(data: ByteArray): Boolean {
        val conn = active.get() ?: return false
        if (conn.socket.isClosed) return false
        return try {
            synchronized(conn.writeLock) {
                WsFrame.write(conn.out, WsFrame.encodeBinary(data))
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    // --- inbound verify + dispatch -----------------------------------
    private fun handleText(raw: String) {
        // §8: freshness is checked against the **controller's** master clock, not
        // our raw wall clock. We fold local now → master via the learned offset
        // (0 before the first time_sync lands, harmless: the first-connect window
        // is 120s). Using uncorrected nowMs() would STALE-drop a controller whose
        // clock legitimately differs from ours — the exact silent-drop bug.
        val nowMaster = clock.masterNow()
        val result = Envelope.verify(
            psk, raw, replay = replay, firstConnect = firstConnect,
            now = nowMaster,
            authMode = authMode, keyMode = keyMode,
            verifyKeyFor = ::verifyKeyFor,
        )
        if (!result.ok || result.parsed == null) {
            // §2 可见性:入站帧被丢 → 打原因 + 帧概要,并回调让 UI 反映。此前是
            // `if (!result.ok) return` 静默吞掉,是"没有日志"的直接元凶。
            val peek = Envelope.peekTypeFrom(raw)
            Log.w(TAG, "DROP inbound: reason=${result.reason} " +
                "type=${peek?.first ?: "?"} from=${peek?.second ?: "?"} " +
                "sigLen=${peek?.third ?: -1} authMode=${authMode.wire} keyMode=${keyMode.wire}")
            try { onInboundDrop(result.reason, peek?.first) } catch (_: Exception) {}
            return
        }
        val parsed = result.parsed
        Log.i(TAG, "RX ${parsed.type} from=${parsed.from} authed=${parsed.authed} " +
            "sigLen=${parsed.sig.length}")
        when (parsed.type) {
            // controller answered *our* probe → learn offset to its clock.
            "time_sync_ack" -> { onTimeSyncAck(parsed.payloadObj); return }
            // controller probing us → answer as the spec's ack-er (§8.1).
            "time_sync" -> { answerTimeSync(parsed); return }
            // controller's hello to us; welcome already sent, nothing to register.
            "hello" -> return
        }
        try {
            onMessage(parsed.type, parsed.payloadObj, parsed)
        } catch (e: Exception) {
            Log.e(TAG, "onMessage(${parsed.type}) threw: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * §17.4 dk-only verify-key resolver. Only consulted by [Envelope.verify] in
     * derived mode **when we don't hold the PSK**. In p2p the inbound `from` is
     * the controller (`controller:<id>`), not `"broker"` — and a dk-only player
     * holds only its own key, never the controller's. So a PSK-less p2p player
     * cannot verify controller frames: we fail closed (return null → dropped).
     * See FEEDBACK_TO_UPSTREAM (controller bk identity-varies-by-topology gap).
     * A player that holds the PSK derives the controller key directly inside
     * [Envelope.verify] and never reaches here.
     */
    private fun verifyKeyFor(fromIdentity: String): ByteArray? = null

    // --- §8 clock: controller is master ------------------------------
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
        val t1 = Envelope.nowMs()
        val mid = send("time_sync", jsonObj { put("t1", t1) }) ?: return
        pendingSync[mid] = t1
        if (pendingSync.size > 64) {
            val it = pendingSync.keys.iterator()
            if (it.hasNext()) { it.next(); it.remove() }
        }
    }

    private fun onTimeSyncAck(payload: Json.Obj) {
        val t4 = Envelope.nowMs()
        val e = payload.entries
        var t1 = e["t1"].asLongOrNull() ?: return
        val t2 = e["t2"].asLongOrNull() ?: return
        val t3 = e["t3"].asLongOrNull() ?: return
        // [v1.1] prefer req_msg_id correlation if present; else correlate by t1
        // (our recorded send time defends against a tampered echo).
        val reqMid = (e["req_msg_id"].asString() ?: e["msg_id"].asString())
        if (reqMid != null) pendingSync.remove(reqMid)?.let { t1 = it }
        clock.addSample(t1, t2, t3, t4)
    }

    private fun answerTimeSync(req: Envelope.Parsed) {
        val t2 = Envelope.nowMs()
        val t1 = req.payloadObj.entries["t1"].asLongOrNull() ?: return
        send("time_sync_ack", jsonObj {
            put("t1", t1)
            put("t2", t2)
            put("t3", Envelope.nowMs())
            put("req_msg_id", req.msgId)
        })
    }

    override fun stop() {
        stopped.set(true)
        stopSyncLoop()
        try { server?.close() } catch (_: Exception) {}
        active.getAndSet(null)?.let { conn ->
            try { synchronized(conn.writeLock) { WsFrame.write(conn.out, WsFrame.encodeClose(1000)) } } catch (_: Exception) {}
            try { conn.socket.close() } catch (_: Exception) {}
        }
        scheduler.shutdownNow()
    }

    companion object {
        private const val TAG = "lmw.P2pServer"

        // a WS opening-handshake head is small; cap to defend against a peer
        // that never sends the blank-line terminator.
        private const val MAX_HEAD = 16 * 1024

        private const val BAD_REQUEST =
            "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
    }
}
