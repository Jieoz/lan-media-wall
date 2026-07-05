package com.jieoz.lanmediawall.player

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.jieoz.lanmediawall.player.cache.Downloader
import com.jieoz.lanmediawall.player.cache.LastTask
import com.jieoz.lanmediawall.player.cache.MediaItem
import com.jieoz.lanmediawall.player.cache.MediaStore
import com.jieoz.lanmediawall.player.cache.Playlist
import com.jieoz.lanmediawall.player.media.PlayerController
import com.jieoz.lanmediawall.player.net.BrokerClient
import com.jieoz.lanmediawall.player.net.AuthMode
import com.jieoz.lanmediawall.player.net.CoordinatorLink
import com.jieoz.lanmediawall.player.net.Discovery
import com.jieoz.lanmediawall.player.net.DiscoveryProbe
import com.jieoz.lanmediawall.player.net.Envelope
import com.jieoz.lanmediawall.player.net.Json
import com.jieoz.lanmediawall.player.net.KeyMode
import com.jieoz.lanmediawall.player.net.P2pServer
import com.jieoz.lanmediawall.player.net.TransportSelector
import com.jieoz.lanmediawall.player.net.asArrayOrNull
import com.jieoz.lanmediawall.player.net.asBoolOrNull
import com.jieoz.lanmediawall.player.net.asIntOrNull
import com.jieoz.lanmediawall.player.net.asLongOrNull
import com.jieoz.lanmediawall.player.net.asString
import com.jieoz.lanmediawall.player.net.get
import com.jieoz.lanmediawall.player.net.jsonArr
import com.jieoz.lanmediawall.player.net.jsonObj
import com.jieoz.lanmediawall.player.net.jsonStrArr
import com.jieoz.lanmediawall.player.sync.ClockSync
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.atomic.AtomicReference

/**
 * Resident foreground service — the orchestrator (the Android analogue of
 * windows_player/main.py). Owns every subsystem and the protocol semantics:
 * §4 hello, §5 status, §6 cache/playlist, §6.4 thumbnails, §8 clock, §9
 * three-phase handshake + controls, §10 resume_last, §11 black-screen safety.
 *
 * Lives as a foreground service so Android keeps it alive; a partial wake lock
 * + a screen-on flag (on the kiosk Activity) keep the wall awake. The watchdog
 * loop re-asserts state and recovers playback after a player error.
 */
class PlayerService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private lateinit var settings: Settings
    private lateinit var clock: ClockSync
    private lateinit var mediaStore: MediaStore
    private lateinit var downloader: Downloader
    /** §14: the coordinator link — a [BrokerClient] (modes A/B) or a [P2pServer]
     *  (mode C). Chosen at startup by [TransportSelector] from discovery; null
     *  until [startSubsystems] resolves and builds it. All protocol I/O goes
     *  through this interface so playback/status/handshake code is topology-
     *  agnostic (§14.3: `to:"broker"` addressing is unchanged in p2p). */
    @Volatile private var link: CoordinatorLink? = null
    private var discovery: Discovery? = null

    private var wakeLock: PowerManager.WakeLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    // playback state (mirrors main.py)
    @Volatile private var playState = "idle"
    @Volatile private var playlist: Playlist? = null
    @Volatile private var index = 0
    @Volatile private var audioMaster = true
    @Volatile private var controllerPresent = false
    private val errors = java.util.concurrent.ConcurrentLinkedDeque<String>()

    private val scheduledStart = AtomicReference<Job?>(null)
    /** §6.3 carousel: pending "hold this image for duration_ms, then advance"
     *  timer. Cancelled by any new prepare/play_at/advance/stop. */
    private val dwellTimer = AtomicReference<Job?>(null)
    private var deviceIp = "0.0.0.0"

    val controllerRef: PlayerController? get() = MainActivity.playerController

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        settings = Settings(applicationContext)
        clock = ClockSync()
        mediaStore = MediaStore(applicationContext)
        downloader = Downloader(mediaStore.mediaCacheDir, onChange = { /* status loop reads */ })
        controllerPresent = settings.alwaysCollectThumbnails
        deviceIp = detectIp()
        // §14: the transport (BrokerClient vs P2pServer) is not chosen here — it
        // depends on a UDP discovery probe that must run off the main thread.
        // startSubsystems() probes, selects, and builds `link` on a coroutine.
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundWithNotification()
        acquireLocks()
        startSubsystems()
        return START_STICKY
    }

    private fun startSubsystems() {
        if (started) return
        started = true
        // watchdog + resume_last don't need the link — start them immediately so
        // the screen shows the last task ASAP after a (re)boot (§10/§11).
        scope.launch { watchdogLoop() }
        scope.launch { resumeLast() }
        // §14.5: choose + build the transport off the main thread (the discovery
        // probe blocks), then start the link and the loops that talk to it.
        scope.launch { selectAndStartTransport() }
    }

    /**
     * §14.5 decide-then-pick: run a UDP discovery probe (skipped for a configured
     * player, which keeps dialing its paired broker — modes A/B byte-for-byte),
     * resolve a [TransportSelector.Plan], build the matching [CoordinatorLink],
     * advertise the chosen topology over UDP, and start the link + its loops.
     */
    private suspend fun selectAndStartTransport() {
        val keyMode = KeyMode.parse(settings.keyMode)
        val deviceKey = settings.deviceKeyHex.takeIf { it.isNotBlank() }
            ?.let { Envelope.hexToBytes(it) }
        val hasKeyMaterial = Envelope.hasUsableKey(settings.psk) || deviceKey != null

        // a player with a real (paired) broker host trusts it (no probe needed);
        // a box with a blank broker — whether never configured OR "configured"
        // via the zero-config path (§2, broker left empty) — probes the LAN for a
        // coordinator and falls back to the p2p server if none answers (§14.5).
        // Keying off hasBroker (not isConfigured) is the fix for a box that saved
        // setup with an empty broker and used to dead-dial a phantom host.
        val hasBroker = settings.hasBroker
        val announces = if (hasBroker) {
            ConnState.set(ConnState.Phase.CONNECTING_BROKER,
                "${settings.brokerHost}:${settings.brokerPort}")
            emptyList()
        } else {
            // §2: no broker configured → tell the UI we're probing the LAN.
            ConnState.set(ConnState.Phase.DISCOVERING)
            DiscoveryProbe(
                psk = settings.psk,
                deviceId = settings.deviceId,
                authMode = if (hasKeyMaterial) AuthMode.OPTIONAL else AuthMode.OPEN,
                keyMode = keyMode,
                deviceKey = deviceKey,
            ).probe(timeoutMs = 3000)
        }

        val plan = TransportSelector.select(
            TransportSelector.Config(
                // "configured" for transport = has a real broker to dial.
                isConfigured = hasBroker,
                brokerHost = settings.brokerHost,
                brokerPort = settings.brokerPort,
                useWss = settings.useWss,
                configuredKeyMode = keyMode,
                hasKeyMaterial = hasKeyMaterial,
            ),
            announces,
        )

        val brokerKey = settings.brokerKeyHex.takeIf { it.isNotBlank() }
            ?.let { Envelope.hexToBytes(it) }
        val newLink: CoordinatorLink = when (plan) {
            is TransportSelector.Plan.Client -> {
                // if we probe-discovered a broker (no configured host), reflect
                // the endpoint we're actually dialing.
                ConnState.set(ConnState.Phase.CONNECTING_BROKER,
                    brokerHintFromWsUrl(plan.url))
                BrokerClient(
                    url = plan.url,
                    psk = settings.psk,
                    deviceId = settings.deviceId,
                    clock = clock,
                    onConnect = { onCoordinatorConnected() },
                    onMessage = { type, payload, env -> onBrokerMessage(type, payload, env) },
                    initialKeyMode = plan.keyMode,
                    deviceKey = deviceKey,
                    brokerKey = brokerKey,
                )
            }
            is TransportSelector.Plan.P2pServer -> {
                // §14.3: no broker — we're the p2p server waiting for a controller.
                ConnState.set(ConnState.Phase.P2P_WAITING, "$deviceIp:${plan.listenPort}")
                P2pServer(
                    psk = settings.psk,
                    deviceId = settings.deviceId,
                    groupId = settings.groupId,
                    clock = clock,
                    // §14.3: a controller dialing in is now watching → open the
                    // thumbnail gate (§6.4). We are the coordinator; no hello to send.
                    onConnect = {
                        controllerPresent = true
                        ConnState.set(ConnState.Phase.P2P_CONNECTED)
                    },
                    onMessage = { type, payload, env -> onBrokerMessage(type, payload, env) },
                    initialAuthMode = plan.authMode,
                    initialKeyMode = plan.keyMode,
                    deviceKey = deviceKey,
                    listenPort = plan.listenPort,
                )
            }
        }
        link = newLink
        newLink.start()
        startDiscoveryResponder(plan)

        // loops that depend on the link start now that it exists.
        scope.launch { statusLoop() }
        scope.launch { thumbnailLoop() }
    }

    /**
     * §7/§14.5: advertise over UDP. In client mode (A/B) we point peers at the
     * broker we connected to (today's behavior). In p2p mode we advertise
     * **ourselves** as the coordinator (our ip:8770, topology:"p2p") so a
     * controller's discovery finds us and dials in (§14.3).
     */
    private fun startDiscoveryResponder(plan: TransportSelector.Plan) {
        val deviceKey = settings.deviceKeyHex.takeIf { it.isNotBlank() }
            ?.let { Envelope.hexToBytes(it) }
        discovery = when (plan) {
            is TransportSelector.Plan.Client -> {
                // §7: advertise on 8772 **whether or not we have a broker**. A
                // box with a paired broker points peers at it; a box with a blank
                // broker that nonetheless discovered one (mode B) still must be
                // visible to the controller AND relay the broker it found, so it
                // advertises the endpoint it actually connected to (parsed from
                // plan.url) rather than the empty configured host. Keying off
                // hasBroker (not isConfigured) is the fix for "两台互不发现" when a
                // broker exists but this box's broker field was never filled.
                val hint = if (settings.hasBroker) {
                    "${settings.brokerHost}:${settings.brokerPort}"
                } else {
                    brokerHintFromWsUrl(plan.url)
                }
                Discovery(
                    psk = settings.psk,
                    deviceId = settings.deviceId,
                    deviceName = settings.deviceName,
                    ip = deviceIp,
                    brokerHint = hint,
                )
            }
            is TransportSelector.Plan.P2pServer -> Discovery(
                psk = settings.psk,
                deviceId = settings.deviceId,
                deviceName = settings.deviceName,
                ip = deviceIp,
                brokerHint = "$deviceIp:${plan.listenPort}",
                topology = "p2p",
                authMode = plan.authMode,
                keyMode = plan.keyMode,
                deviceKey = deviceKey,
            )
        }.also { it.start() }
    }

    /**
     * Strip a `ws(s)://host:port` down to the `host:port` broker_hint an
     * `announce` carries (§7). Falls back to the raw string if it doesn't look
     * like a URL. Used so an unconfigured client relays the broker it actually
     * discovered/connected to, not the empty configured host.
     */
    private fun brokerHintFromWsUrl(url: String): String {
        val noScheme = url.substringAfter("://", url)
        // drop any trailing path/query, keep host:port only.
        return noScheme.substringBefore('/').substringBefore('?')
    }

    @Volatile private var started = false

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
        try { link?.stop() } catch (_: Exception) {}
        discovery?.stop()
        downloader.stop()
        releaseLocks()
        if (instance === this) instance = null
    }

    // --- foreground notification -------------------------------------
    private fun startForegroundWithNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, getString(R.string.notif_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) }
            nm.createNotificationChannel(channel)
        }
        val tapIntent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notif = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.notif_title))
            .setContentText(getString(R.string.notif_text))
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setOngoing(true)
            .setContentIntent(tapIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID, notif,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun acquireLocks() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (wakeLock == null) {
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "lmw:player").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (multicastLock == null && wifi != null) {
            multicastLock = wifi.createMulticastLock("lmw:discovery").apply {
                setReferenceCounted(false)
                try { acquire() } catch (_: Exception) {}
            }
        }
    }

    private fun releaseLocks() {
        try { wakeLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        try { multicastLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        wakeLock = null
        multicastLock = null
    }

    private fun detectIp(): String {
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces() ?: return "0.0.0.0"
            for (iface in ifaces) {
                if (!iface.isUp || iface.isLoopback) continue
                for (addr in iface.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        return addr.hostAddress ?: continue
                    }
                }
            }
        } catch (_: Exception) {
        }
        return "0.0.0.0"
    }

    // --- §4 hello on (re)connect -------------------------------------
    /** Fired when the coordinator link comes up. In client mode (A/B) this is a
     *  broker (re)connect → send `hello` (§4). In p2p mode the player IS the
     *  coordinator and sends `welcome` from [P2pServer] instead, so this is only
     *  wired for the client path. */
    private fun onCoordinatorConnected() {
        ConnState.set(ConnState.Phase.CONNECTED_BROKER, ConnState.detail)
        val payload = jsonObj {
            put("role", "player")
            put("device_id", settings.deviceId)
            put("device_name", settings.deviceName)
            put("platform", "android")
            put("app_version", Settings.APP_VERSION)
            put("ip", deviceIp)
            put("screen", screenJson())
            put("capabilities", jsonStrArr(listOf("video", "image", "audio", "thumbnail")))
            put("group_id", settings.groupId)
        }
        link?.send("hello", payload)
    }

    private fun screenJson(): Json {
        val metrics = resources.displayMetrics
        return jsonObj {
            put("w", metrics.widthPixels)
            put("h", metrics.heightPixels)
        }
    }

    // --- §5 status loop ----------------------------------------------
    private suspend fun statusLoop() {
        while (scope.isActive) {
            try {
                reconcileConnPhase()
                sendStatus()
            } catch (_: Exception) {
            }
            delay(1500) // §5: every 1–2s
        }
    }

    /**
     * §2 diagnostics: keep [ConnState] honest between the connect/onConnect
     * transitions. A [BrokerClient] reconnects silently with backoff, so poll its
     * live state here — a link that was up but is now down flips the phase to
     * DISCONNECTED so the settings page shows the drop instead of a stale
     * "已连接"; a silent reconnect flips it back to the matching connected phase.
     */
    private fun reconcileConnPhase() {
        val l = link ?: return
        val up = l.isConnected
        val p = ConnState.phase
        val isP2p = l is P2pServer
        if (up) {
            if (p == ConnState.Phase.DISCONNECTED) {
                ConnState.set(
                    if (isP2p) ConnState.Phase.P2P_CONNECTED else ConnState.Phase.CONNECTED_BROKER,
                    ConnState.detail,
                )
            }
        } else {
            // p2p down just means "still waiting for a controller"; a broker
            // client being down is a real drop worth surfacing.
            if (!isP2p && p == ConnState.Phase.CONNECTED_BROKER) {
                ConnState.set(ConnState.Phase.DISCONNECTED, ConnState.detail)
            }
        }
    }

    private fun sendStatus() {
        val ctl = controllerRef
        val snap = ctl?.snapshot()
        val item = currentItem()
        val currentJson: Json = if (item != null) {
            jsonObj {
                put("item_id", item.itemId)
                put("name", item.name)
                put("position_ms", snap?.positionMs ?: 0L)
                put("duration_ms", snap?.durationMs?.takeIf { it > 0 }
                    ?: (item.durationMs ?: 0L))
            }
        } else {
            Json.Null
        }
        val payload = jsonObj {
            put("device_id", settings.deviceId)
            put("online", true)
            put("group_id", settings.groupId)
            put("state", effectiveState())
            put("current", currentJson)
            put("playlist_id", playlist?.playlistId)
            put("volume", settings.volume)
            put("muted", settings.muted)
            put("audio_master", audioMaster)
            put("cache", cacheJson())
            put("clock_offset_ms", clock.offsetMs)
            put("app_version", Settings.APP_VERSION)
            // §5.1: resource telemetry. `cpu` kept for backward-compat with the
            // documented shape; low-end boxes can't read per-app CPU without
            // root, so we report an honest 0 rather than a fabricated value.
            // Memory IS readable everywhere via ActivityManager.MemoryInfo, so
            // we add real mem_* fields (controllers ignore unknown fields, §5.1).
            put("cpu", 0)
            putMemory(this)
            readTempC()?.let { put("temp_c", it) }
            put("errors", jsonStrArr(errors.toList().takeLast(5)))
        }
        link?.send("status", payload)
    }

    /**
     * §5.1 memory telemetry — always available on Android via
     * [ActivityManager.MemoryInfo]. Reports device-wide RAM so operators can
     * spot a box under memory pressure. Fields are additive (forward-compat):
     * `mem_avail_mb`, `mem_total_mb`, `mem_low` (OS low-memory flag).
     */
    private fun putMemory(b: com.jieoz.lanmediawall.player.net.JsonObjectBuilder) {
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            b.put("mem_avail_mb", (mi.availMem / (1024 * 1024)).toInt())
            b.put("mem_total_mb", (mi.totalMem / (1024 * 1024)).toInt())
            b.put("mem_low", mi.lowMemory)
        } catch (_: Exception) {
            // MemoryInfo shouldn't fail; if it does, simply omit (don't fake).
        }
    }

    /**
     * Best-effort SoC temperature (°C). Most 山寨 boxes expose no readable
     * thermal zone to an unprivileged app, so this returns null far more often
     * than not — we omit the field entirely rather than report a fake value
     * (§5.1 forward-compat: absent field is fine). Reads the common
     * `/sys/class/thermal/thermal_zone0/temp` (milli-°C or °C) when present.
     */
    private fun readTempC(): Int? {
        return try {
            val f = java.io.File("/sys/class/thermal/thermal_zone0/temp")
            if (!f.canRead()) return null
            val raw = f.readText().trim().toLongOrNull() ?: return null
            val c = if (raw > 1000) (raw / 1000).toInt() else raw.toInt()
            c.takeIf { it in 1..150 } // sanity-gate obvious garbage
        } catch (_: Exception) {
            null
        }
    }

    private fun cacheJson(): Json {
        val map = downloader.cacheStatus()
        return jsonObj { for ((k, v) in map) put(k, v) }
    }

    private fun effectiveState(): String {
        if (playState == "playing" || playState == "paused") {
            return playState
        }
        if (downloader.cacheStatus().values.any { it.startsWith("downloading") }) {
            return "downloading"
        }
        return if (playState in VALID_STATES) playState else "idle"
    }

    // --- inbound dispatch (§6, §9, §10) ------------------------------
    private fun onBrokerMessage(type: String, payload: Json.Obj, env: Envelope.Parsed) {
        when (type) {
            "cache_prefetch" -> hCachePrefetch(payload)
            "playlist" -> hPlaylist(payload)
            "prepare" -> hPrepare(payload)
            "play_at" -> hPlayAt(payload)
            "pause" -> hPause(payload)
            "resume" -> hResume(payload)
            "stop" -> hStop(payload)
            "next" -> hAdvance(payload, +1)
            "prev" -> hAdvance(payload, -1)
            "set_volume" -> hSetVolume(payload)
            "set_mute" -> hSetMute(payload)
            "set_audio_master" -> hSetAudioMaster(payload)
            "assign_group" -> hAssignGroup(payload)
            "configure_device" -> hConfigureDevice(payload)
            "update_app" -> hUpdateApp(payload, env)
            "resume_last" -> scope.launch { resumeLast() }
            "welcome" -> hWelcome(payload)
            "controller_presence" -> hControllerPresence(payload)
            else -> return
        }
        // ack commands that carry a msg_id (§10)
        if (type in ACKABLE) {
            link?.send("ack", jsonObj {
                put("ack_of", env.msgId)
                put("ok", true)
                put("err", "")
            })
        }
    }

    private fun hWelcome(payload: Json.Obj) {
        // §4.2: broker's group_id is authoritative for players.
        payload["group_id"].asString()?.let { gid ->
            if (gid != settings.groupId) settings.groupId = gid
        }
        // §13/§17.3: the coordinator is authoritative for auth_mode + key_mode.
        // Adopt both so subsequent frames sign/verify under the declared regime.
        // Only meaningful in client mode (we *receive* welcome from a broker); in
        // p2p WE send welcome and are authoritative, so there's no inbound one to
        // adopt — hence the BrokerClient-typed adoption.
        val client = link as? BrokerClient
        payload["auth_mode"].asString()?.let { client?.setAuthMode(AuthMode.parse(it)) }
        payload["key_mode"].asString()?.let {
            val km = KeyMode.parse(it)
            client?.setKeyMode(km)
            if (settings.keyMode != km.wire) settings.keyMode = km.wire
        }
        payload["controllers_online"].asIntOrNull()?.let {
            controllerPresent = it > 0 || settings.alwaysCollectThumbnails
        }
        if (payload["assigned"].asBoolOrNull() == false) {
            pushError("not-assigned")
        }
    }

    // §4.3 controller presence gates thumbnail collection.
    private fun hControllerPresence(payload: Json.Obj) {
        val present = payload["present"].asBoolOrNull()
            ?: ((payload["controllers_online"].asIntOrNull() ?: 0) > 0)
        controllerPresent = present || settings.alwaysCollectThumbnails
    }

    // --- §6.2 cache_prefetch -----------------------------------------
    private fun hCachePrefetch(payload: Json.Obj) {
        val items = (payload["items"].asArrayOrNull() ?: emptyList())
            .mapNotNull { MediaItem.fromJson(it) }
        if (items.isNotEmpty()) downloader.prefetch(items)
    }

    // --- §6.3 playlist -----------------------------------------------
    private fun hPlaylist(payload: Json.Obj) {
        val pl = Playlist.fromJson(payload) ?: return
        playlist = pl
        index = 0
        mediaStore.storePlaylist(pl)
        updateCacheProtection(pl)
        if (pl.items.isNotEmpty()) downloader.prefetch(pl.items)
    }

    /**
     * §6: tell the downloader which files back the current playlist so its
     * quota-eviction never deletes media we're about to play (§11), and refresh
     * the operator cap from Settings. Called whenever the active playlist
     * changes (playlist / prepare / resume_last).
     */
    private fun updateCacheProtection(pl: Playlist?) {
        val protectedFiles = pl?.items?.map { downloader.localPath(it).absolutePath }
            ?.toSet() ?: emptySet()
        downloader.configureQuota(settings.cacheMaxBytes, protectedFiles)
    }

    // --- §9.1 prepare -------------------------------------------------
    private fun hPrepare(payload: Json.Obj) {
        val pid = payload["playlist_id"].asString()
        val groupId = payload["group_id"].asString()
        val prepareId = payload["prepare_id"].asString()
        val startIndex = payload["start_index"].asIntOrNull() ?: 0
        val seekMs = payload["seek_ms"].asLongOrNull() ?: 0L
        // §21 预缓存栅栏:prefetch=true 表示"缓存好再回 ready"。未缓存时不立刻回
        // ready:false,而是后台等下载+校验完成再回 ready:true,让全员统一从头起播。
        val prefetchBarrier = payload["prefetch"].asBoolOrNull() ?: false
        val barrierTimeoutMs = payload["barrier_timeout_ms"].asLongOrNull() ?: 120000L
        val pl = resolvePlaylist(pid)
        var ready = false
        dwellTimer.getAndSet(null)?.cancel() // §6.3: a new session voids any dwell
        if (pl != null && startIndex in pl.items.indices) {
            val item = pl.items[startIndex]
            playlist = pl
            index = startIndex
            updateCacheProtection(pl)
            if (downloader.isReady(item.itemId)) {
                val readyFile = downloader.readyPath(item.itemId)
                readyFile?.let { downloader.touch(it) } // §6 LRU: mark just-used
                val path = readyFile?.absolutePath
                if (path != null) {
                    // §6.1: an image has no decoder to prime — it's shown at the
                    // sync instant (play_at → scheduledStart). A video primes
                    // paused so play_at just flips playWhenReady on.
                    if (item.type != "image") {
                        controllerRef?.loadPaused(path, seekMs, singleLoop(pl))
                    }
                    playState = "buffering"
                    ready = true
                }
            } else if (prefetchBarrier) {
                // §21 栅栏:后台等缓存完成再回 ready,不阻塞消息循环。
                downloader.prefetch(listOf(item))
                scope.launch {
                    awaitCacheThenReady(pid, groupId, prepareId, item, seekMs,
                        pl, barrierTimeoutMs)
                }
                return
            } else {
                downloader.prefetch(listOf(item)) // kick a fetch; report not-ready
            }
        }
        // §9.1: echo prepare_id + group_id back so broker matches the session.
        sendReady(pid, groupId, prepareId, ready)
    }

    /** §9.1 ready 上报:回带 prepare_id + group_id 供 broker/协调端匹配会话。 */
    private fun sendReady(pid: String?, groupId: String?, prepareId: String?,
                          ready: Boolean) {
        link?.send("ready", jsonObj {
            put("device_id", settings.deviceId)
            put("playlist_id", pid)
            put("group_id", groupId)
            put("prepare_id", prepareId)
            put("ready", ready)
        })
    }

    /** §21 预缓存栅栏:轮询缓存态,ready 后 prime 并回 ready:true;超时回 ready:false,
     *  交由控制端/broker 按"已就绪者"降级起播(不无限等)。 */
    private suspend fun awaitCacheThenReady(
        pid: String?, groupId: String?, prepareId: String?,
        item: MediaItem, seekMs: Long, pl: Playlist, timeoutMs: Long
    ) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (downloader.isReady(item.itemId)) {
                val readyFile = downloader.readyPath(item.itemId)
                readyFile?.let { downloader.touch(it) }
                val path = readyFile?.absolutePath
                if (path != null) {
                    if (item.type != "image") {
                        controllerRef?.loadPaused(path, seekMs, singleLoop(pl))
                    }
                    playState = "buffering"
                    sendReady(pid, groupId, prepareId, true)
                    return
                }
            }
            delay(500)
        }
        sendReady(pid, groupId, prepareId, false)
    }

    // --- §9.2 play_at (sync-critical path) ---------------------------
    private fun hPlayAt(payload: Json.Obj) {
        val pid = payload["playlist_id"].asString()
        val startIndex = payload["start_index"].asIntOrNull() ?: index
        val seekMs = payload["seek_ms"].asLongOrNull() ?: 0L
        val playAt = payload["play_at"].asLongOrNull() ?: 0L
        val pl = resolvePlaylist(pid) ?: return
        if (startIndex !in pl.items.indices) return
        playlist = pl
        index = startIndex
        updateCacheProtection(pl)
        val item = pl.items[startIndex]
        val readyFile = downloader.readyPath(item.itemId)
        readyFile?.let { downloader.touch(it) } // §6 LRU: mark just-used
        val source = readyFile?.absolutePath ?: item.url
        scheduledStart.getAndSet(null)?.cancel()
        dwellTimer.getAndSet(null)?.cancel() // §6.3: new session voids any dwell
        persistLastTask(pid!!, startIndex, seekMs)
        val job = scope.launch { scheduledStart(source, seekMs, playAt, pl, item) }
        scheduledStart.set(job)
    }

    private suspend fun scheduledStart(uri: String, seekMs: Long, playAt: Long,
                                       pl: Playlist, item: MediaItem) {
        val ctl = controllerRef ?: return
        if (item.type == "image") {
            // §6.1/§6.3: nothing to prime — wait for the sync instant, then show
            // the still and start its dwell so the carousel advances.
            awaitLocal(clock.toLocal(playAt))
            ctl.showImage(uri)
            playState = "playing"
            MainActivity.instance?.hideIdle()
            armDwell(item)
            return
        }
        // video: prime paused at seek (idempotent if prepare already did it),
        // arm end-of-video auto-advance, then unpause at the sync instant.
        ctl.onVideoEnded = { onCurrentEnded() }
        ctl.loadPaused(uri, seekMs, singleLoop(pl))
        awaitLocal(clock.toLocal(playAt)) // §8.2 fold master → local
        ctl.play()
        playState = "playing"
        MainActivity.instance?.hideIdle()
    }

    /** §8.2: coarse-sleep, then tight-spin the last few ms for ±50–100ms sync. */
    private suspend fun awaitLocal(localTarget: Long) {
        while (scope.isActive) {
            val remaining = localTarget - System.currentTimeMillis()
            if (remaining <= 0) break
            if (remaining > 60) {
                delay(minOf(remaining - 50, 50L).coerceAtLeast(1))
            } else {
                while (localTarget - System.currentTimeMillis() > 0) { /* spin */ }
                break
            }
        }
    }

    // --- §9.3 controls -----------------------------------------------
    private fun hPause(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        controllerRef?.pause()
        playState = "paused"
    }

    private fun hResume(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        val playAt = payload["play_at"].asLongOrNull()
        if (playAt != null && playAt > 0) {
            val localTarget = clock.toLocal(playAt)
            scope.launch {
                val delayMs = (localTarget - System.currentTimeMillis()).coerceAtLeast(0)
                delay(delayMs)
                controllerRef?.play()
                playState = "playing"
                MainActivity.instance?.hideIdle()
            }
        } else {
            controllerRef?.play()
            playState = "playing"
            MainActivity.instance?.hideIdle()
        }
    }

    private fun hStop(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        scheduledStart.getAndSet(null)?.cancel()
        dwellTimer.getAndSet(null)?.cancel()
        controllerRef?.stop()
        playState = "idle"
        persistLastTaskNull()
        MainActivity.instance?.showIdle()
    }

    private fun hAdvance(payload: Json.Obj, delta: Int) {
        if (!targetsMe(payload)) return
        advance(delta)
    }

    /**
     * §6.3 carousel step. Shared by external next/prev and the automatic
     * progressors (image dwell timer, video end-of-media). Moves [index] by
     * [delta] (wrapping when the playlist loops), then plays the new item:
     * an image is shown + its dwell armed; a video is loaded and auto-advances
     * on end. Any pending dwell is cancelled first so timers never stack.
     */
    private fun advance(delta: Int) {
        val pl = playlist ?: return
        if (pl.items.isEmpty()) return
        dwellTimer.getAndSet(null)?.cancel()
        var newIndex = index + delta
        if (newIndex < 0 || newIndex >= pl.items.size) {
            if (pl.loop) newIndex = ((newIndex % pl.items.size) + pl.items.size) % pl.items.size
            else return
        }
        index = newIndex
        val item = pl.items[newIndex]
        val readyFile = downloader.readyPath(item.itemId)
        readyFile?.let { downloader.touch(it) } // §6 LRU: mark just-used
        val source = readyFile?.absolutePath ?: item.url
        val ctl = controllerRef
        if (item.type == "image") {
            ctl?.showImage(source)
            armDwell(item)
        } else {
            ctl?.onVideoEnded = { onCurrentEnded() }
            ctl?.loadAndPlay(source, 0, singleLoop(pl))
        }
        playState = "playing"
        persistLastTask(pl.playlistId, newIndex, 0)
        MainActivity.instance?.hideIdle()
    }

    /** §6.3: hold the current image for its duration_ms (default
     *  [DEFAULT_IMAGE_DWELL_MS]) then step forward. */
    private fun armDwell(item: MediaItem) {
        val dwell = item.durationMs?.takeIf { it > 0 } ?: DEFAULT_IMAGE_DWELL_MS
        val job = scope.launch {
            delay(dwell)
            if (isActive) advance(+1)
        }
        dwellTimer.getAndSet(job)?.cancel()
    }

    /** §6.3: a non-looping video finished (ExoPlayer STATE_ENDED) → step
     *  forward. Fired on the main thread, so hop to a coroutine for the I/O. */
    private fun onCurrentEnded() {
        scope.launch { advance(+1) }
    }

    /** §6.3 loop semantics: only a *single-item* looping playlist maps to
     *  ExoPlayer's REPEAT_MODE_ONE. A multi-item loop must reach STATE_ENDED so
     *  we can advance + wrap; REPEAT_MODE_ONE would freeze it on item 0. */
    private fun singleLoop(pl: Playlist): Boolean = pl.loop && pl.items.size == 1

    private fun hSetVolume(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        val vol = payload["volume"].asIntOrNull() ?: settings.volume
        settings.volume = vol
        controllerRef?.currentVolumePercent = vol
        controllerRef?.setVolume(vol)
    }

    private fun hSetMute(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        val muted = payload["muted"].asBoolOrNull() ?: settings.muted
        settings.muted = muted
        controllerRef?.setMuted(muted)
    }

    private fun hSetAudioMaster(payload: Json.Obj) {
        // §9.3: device_ids lists who outputs sound; others mute. No list = all.
        val ids = payload["device_ids"].asArrayOrNull()
        audioMaster = if (ids == null) true
        else ids.mapNotNull { it.asString() }.contains(settings.deviceId)
        val muted = !audioMaster
        settings.muted = muted
        controllerRef?.setMuted(muted)
    }

    private fun hAssignGroup(payload: Json.Obj) {
        if (payload["device_id"].asString() != settings.deviceId) return
        payload["group_id"].asString()?.let { settings.groupId = it }
    }

    // --- §19 configure_device ----------------------------------------
    /** 盒子配置(§19):改显示名 / 设组 / 设音量。仅对本机 device_id 生效,缺省字段不动。
     *  改动持久化(SharedPreferences),重启后保留。 */
    private fun hConfigureDevice(payload: Json.Obj) {
        if (payload["device_id"].asString() != settings.deviceId) return
        payload["device_name"].asString()?.takeIf { it.isNotBlank() }?.let {
            settings.deviceName = it.trim()
        }
        payload["group_id"].asString()?.takeIf { it.isNotBlank() }?.let {
            settings.groupId = it
        }
        payload["volume"].asIntOrNull()?.let {
            val vol = it.coerceIn(0, 100)
            settings.volume = vol
            controllerRef?.currentVolumePercent = vol
            controllerRef?.setVolume(vol)
        }
    }

    // --- §22 update_app (remote self-update, root install) -----------
    /**
     * §22: remotely update this box's own APK. FOUR guardrails (see UpdateGuard
     * + RootInstaller): (1) the frame MUST be authenticated (env.authed) — an
     * `open`/unsigned box refuses; (2) target versionCode MUST be strictly
     * newer (no downgrade/replay); (3) url + 64-hex sha256 required and the
     * downloaded bytes are re-verified before install; (4) the Android platform
     * enforces same-signer at boot-scan time. Only after all pass do we root-
     * install via /data/app + reboot (the only path that works on these boxes).
     * Runs off-thread; reports the outcome back over the link.
     */
    private fun hUpdateApp(payload: Json.Obj, env: Envelope.Parsed) {
        if (!targetsMe(payload)) return
        val targetCode = payload["version_code"].asIntOrNull()
        val url = payload["url"].asString()
        val sha = payload["sha256"].asString()
        val decision = com.jieoz.lanmediawall.player.update.UpdateGuard.decide(
            authed = env.authed,
            currentVersionCode = BuildConfig.VERSION_CODE,
            targetVersionCode = targetCode,
            url = url,
            sha256 = sha,
        )
        if (decision is com.jieoz.lanmediawall.player.update.UpdateGuard.Decision.Reject) {
            reportUpdate("rejected", decision.reason)
            pushError("update:${decision.reason}")
            return
        }
        // Proceed on a background thread — download can be large; must not block
        // the link. url/sha are non-null here (guard passed).
        reportUpdate("downloading", "")
        scope.launch(Dispatchers.IO) {
            val updater = com.jieoz.lanmediawall.player.update.AppUpdater(cacheDir)
            when (val r = updater.downloadVerifyInstall(packageName, url!!, sha!!)) {
                is com.jieoz.lanmediawall.player.update.AppUpdater.Result.Installing ->
                    reportUpdate("installing", "reboot") // box reboots now
                is com.jieoz.lanmediawall.player.update.AppUpdater.Result.Failed -> {
                    reportUpdate("failed", r.reason)
                    pushError("update:${r.reason}")
                }
            }
        }
    }

    /** Report §22 update progress/outcome back to the coordinator (best-effort). */
    private fun reportUpdate(state: String, detail: String) {
        link?.send("update_status", jsonObj {
            put("device_id", settings.deviceId)
            put("state", state)      // downloading | installing | rejected | failed
            put("detail", detail)
            put("version_code", BuildConfig.VERSION_CODE)
        })
    }

    // --- §6.4 thumbnail loop -----------------------------------------
    private suspend fun thumbnailLoop() {
        while (scope.isActive) {
            delay(5000) // §6.4 ~5s
            val coordinator = link ?: continue
            if (!coordinator.isConnected) continue
            if (!(settings.alwaysCollectThumbnails || controllerPresent)) continue
            val ctl = controllerRef ?: continue
            val res = ctl.captureThumbnail(maxWidth = 320, quality = 70) ?: continue
            val (seq, jpeg) = res
            coordinator.send("thumb_meta", jsonObj {
                put("device_id", settings.deviceId)
                put("seq", seq)
                put("bytes", jpeg.size)
                put("mime", "image/jpeg")
            })
            coordinator.sendBinary(jpeg)
        }
    }

    // --- watchdog (§11) ----------------------------------------------
    private suspend fun watchdogLoop() {
        while (scope.isActive) {
            delay(5000)
            // re-assert kiosk immersive state on the activity (§11)
            MainActivity.instance?.reassertKiosk()
            // recover from a player error: resume last task within ~5s (§11)
            val err = controllerRef?.snapshot()?.error
            if (err != null && playState == "playing") {
                pushError("player:$err")
                resumeLast()
            }
        }
    }

    // --- helpers ------------------------------------------------------
    private fun targetsMe(payload: Json.Obj): Boolean {
        val dev = payload["device_id"].asString()
        val grp = payload["group_id"].asString()
        if (dev != null) return dev == settings.deviceId
        if (grp != null) return grp == settings.groupId
        return true
    }

    private fun resolvePlaylist(pid: String?): Playlist? {
        val current = playlist
        if (current != null && current.playlistId == pid) return current
        if (pid != null) mediaStore.loadPlaylist(pid)?.let { return it }
        return current
    }

    private fun currentItem(): MediaItem? {
        val pl = playlist ?: return null
        return pl.items.getOrNull(index)
    }

    private fun persistLastTask(pid: String, idx: Int, seekMs: Long) {
        mediaStore.setLastTask(
            LastTask(pid, idx, seekMs, settings.volume, settings.muted),
        )
    }

    private fun persistLastTaskNull() = mediaStore.setLastTask(null)

    private fun pushError(msg: String) {
        errors.addLast(msg)
        while (errors.size > 10) errors.pollFirst()
    }

    /** §10/§11: after crash/reboot, return to the last task so the screen is
     *  never the desktop. Falls back to the idle (black) screen. */
    private suspend fun resumeLast() {
        val ctl = controllerRef
        val task = mediaStore.getLastTask()
        if (task == null) {
            MainActivity.instance?.showIdle()
            return
        }
        val pl = resolvePlaylist(task.playlistId)
        if (pl == null || task.index !in pl.items.indices) {
            MainActivity.instance?.showIdle()
            return
        }
        playlist = pl
        index = task.index
        updateCacheProtection(pl)
        dwellTimer.getAndSet(null)?.cancel()
        val item = pl.items[task.index]
        val readyFile = downloader.readyPath(item.itemId)
        readyFile?.let { downloader.touch(it) } // §6 LRU: mark just-used
        val source = readyFile?.absolutePath ?: item.url
        settings.volume = task.volume
        settings.muted = task.muted
        ctl?.currentVolumePercent = task.volume
        if (item.type == "image") {
            ctl?.showImage(source)
            armDwell(item)
        } else {
            ctl?.onVideoEnded = { onCurrentEnded() }
            ctl?.loadAndPlay(source, task.seekMs, singleLoop(pl))
        }
        ctl?.setVolume(task.volume)
        ctl?.setMuted(task.muted)
        playState = "playing"
        MainActivity.instance?.hideIdle()
    }

    companion object {
        const val ACTION_START = "com.jieoz.lanmediawall.player.START"
        private const val CHANNEL_ID = "lmw_player"
        private const val NOTIF_ID = 1001

        private val VALID_STATES = setOf("playing", "paused", "idle", "buffering", "downloading")
        /** §6.3: default per-image dwell when a playlist item omits duration_ms. */
        private const val DEFAULT_IMAGE_DWELL_MS = 5000L
        private val ACKABLE = setOf(
            "prepare", "pause", "resume", "stop", "next", "prev",
            "set_volume", "set_mute", "set_audio_master", "assign_group",
            "configure_device", "cache_prefetch", "playlist", "update_app",
        )

        @Volatile
        var instance: PlayerService? = null
            private set
    }
}
