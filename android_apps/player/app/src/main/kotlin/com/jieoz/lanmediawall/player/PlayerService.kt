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
import com.jieoz.lanmediawall.player.cache.CacheCleanup
import com.jieoz.lanmediawall.player.cache.CacheReferenceSnapshot
import com.jieoz.lanmediawall.player.cache.Downloader
import java.io.File
import com.jieoz.lanmediawall.player.cache.LastTask
import com.jieoz.lanmediawall.player.cache.LiveCacheBackend
import com.jieoz.lanmediawall.player.cache.LoopMode
import com.jieoz.lanmediawall.player.cache.MediaItem
import com.jieoz.lanmediawall.player.cache.MediaStore
import com.jieoz.lanmediawall.player.cache.MusicPlaylist
import com.jieoz.lanmediawall.player.cache.Playlist
import com.jieoz.lanmediawall.player.cache.PlaylistOps
import com.jieoz.lanmediawall.player.media.PlayerController
import com.jieoz.lanmediawall.player.media.ThumbnailPolicy
import com.jieoz.lanmediawall.player.media.TransitionPolicy
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
import com.jieoz.lanmediawall.player.sync.LoopBoundarySync
import com.jieoz.lanmediawall.player.update.RootInstaller
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicLong

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
    @Volatile private var runtimeModeState = PlaybackModeState()
    @Volatile private var musicPlaylist: MusicPlaylist? = null
    @Volatile private var musicCurrentItemId: String? = null
    @Volatile private var musicPlayCount = 0L
    @Volatile private var musicFailures = emptySet<String>()
    private val musicShuffle = ShuffleBag<String>()
    private val modeGeneration = AtomicLong(0L)
    @Volatile private var audioMaster = true
    @Volatile private var controllerPresent = false
    // §27 last-cleanup bookkeeping for the §26 summary (at-ms, error string).
    @Volatile private var lastCleanupAt = 0L
    @Volatile private var lastCleanupError = ""
    /** §27 long-lived cleanup transaction — holds the bounded idempotency
     *  journal so a repeated destructive request_id returns its terminal result
     *  and never deletes twice. Built lazily on first cache request. */
    private var cleanupObj: CacheCleanup? = null
    private val cacheGenerationLock = Any()
    /** §6.4 bounded per-item extraction attempts. Successful bytes move into the
     *  permanent in-memory cache; repeated decoder failures stop after the policy
     *  limit instead of opening a retriever forever. */
    private val thumbAttempts = java.util.concurrent.ConcurrentHashMap<String, Int>()
    private val thumbSession =
        "${android.os.Process.myPid()}-${android.os.SystemClock.elapsedRealtime()}"
    private val errors = java.util.concurrent.ConcurrentLinkedDeque<String>()
    private val logBuffer = java.util.concurrent.ConcurrentLinkedDeque<String>()
    private val logLock = Any()
    private val logDir by lazy { File(filesDir, "logs") }
    private val logFile by lazy { File(logDir, "player.log") }

    private val scheduledStart = AtomicReference<Job?>(null)
    /** Generation guard + job handle prevent stale prepare waiters from priming. */
    private val prepareGeneration = PrepareGeneration()
    private val prepareWaiter = AtomicReference<Job?>(null)
    private val restoreTask = AtomicReference<Job?>(null)
    /** §6.3 carousel: pending "hold this image for duration_ms, then advance"
     *  timer. Cancelled by any new prepare/play_at/advance/stop. */
    private val dwellTimer = AtomicReference<Job?>(null)
    /**
     * Boundary-only synchronization for a seamless single-video loop. The job
     * sleeps until each shared master-clock lap boundary and samples once; it
     * never runs a continuous seek/rate-control loop. Any command that invalidates
     * the active timeline cancels it through [cancelLoopBoundarySync].
     */
    private val loopBoundaryJob = AtomicReference<Job?>(null)
    @Volatile private var activeLoopSync: ActiveLoopSync? = null
    @Volatile private var lastLoopDriftMs: Long? = null
    @Volatile private var lastLoopExpectedMs: Long? = null
    @Volatile private var loopBoundaryCount = 0L
    @Volatile private var loopCorrectionCount = 0L
    /** Exact transport generation whose authenticated Broker welcome was accepted. */
    @Volatile private var lastBrokerWelcomeGeneration = -1L
    private var deviceIp = "0.0.0.0"

    private data class ActiveLoopSync(
        val sessionId: String,
        val itemId: String,
        val playAtMasterMs: Long,
        val baseSeekMs: Long,
    )

    private val startupDaemonReconciler by lazy {
        com.jieoz.lanmediawall.player.update.StartupDaemonReconciler(
            reconcile = {
                val updater = com.jieoz.lanmediawall.player.update.AppUpdater(
                    cacheDir,
                    daemonAssetProvider = {
                        assets.open(com.jieoz.lanmediawall.player.update.AppUpdater.DAEMON_ASSET_ENTRY)
                    },
                )
                val result = updater.reconcileDaemon(log = { logEvent(it) })
                if (result is com.jieoz.lanmediawall.player.update.AppUpdater.Result.Failed) {
                    logEvent("daemon_startup_reconcile reason=${result.reason}")
                    false
                } else true
            },
            log = { logEvent(it) },
        )
    }

    val controllerRef: PlayerController? get() = MainActivity.playerController

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ConnState.set(ConnState.Phase.STARTING, "service onCreate")
        // boot-probe: durable breadcrumb proving the service actually reached
        // onCreate (vs. the receiver's start call throwing before we get here).
        com.jieoz.lanmediawall.player.boot.BootAudit.record(applicationContext, "service_oncreate", "")
        instance = this
        settings = Settings(applicationContext)
        clock = ClockSync()
        mediaStore = MediaStore(applicationContext)
        runtimeModeState = PlaybackModeState(
            PlaybackMode.parse(settings.runtimeMode) ?: PlaybackMode.VISUAL,
            PlaybackMode.parse(settings.previousActiveMode) ?: PlaybackMode.VISUAL,
        )
        musicPlaylist = mediaStore.loadMusicPlaylist()
        downloader = Downloader(
            mediaStore.mediaCacheDir,
            onChange = { /* status loop reads */ },
            logSink = { msg -> logEvent("dl $msg") },
        )
        controllerPresent = settings.alwaysCollectThumbnails
        deviceIp = AndroidNet.detectLanIp()
        logEvent("service_create ip=$deviceIp group=${settings.groupId}")
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
        // Every newly activated Player reconciles the daemon embedded in its own
        // APK immediately. Do not defer this until the next update_app command:
        // that leaves legacy boxes running stale privileged code indefinitely.
        scope.launch(Dispatchers.IO) { startupDaemonReconciler.runOnce() }
        // §14.5: choose + build the transport off the main thread (the discovery
        // probe blocks), then start the link and the loops that talk to it.
        scope.launch {
            try {
                rebuildTransport()
            } catch (t: Throwable) {
                val detail = "${t.javaClass.simpleName}: ${t.message ?: "transport bootstrap failed"}"
                ConnState.set(ConnState.Phase.START_FAILED, detail)
                logEvent("startup_failed $detail")
            }
        }
    }

    /**
     * §14.5 decide-then-pick: run a UDP discovery probe (skipped for a configured
     * player, which keeps dialing its paired broker — modes A/B byte-for-byte),
     * resolve a [TransportSelector.Plan], build the matching [CoordinatorLink],
     * advertise the chosen topology over UDP, and start the link + its loops.
     */
    private suspend fun selectAndStartTransport(generation: Long) {
        val keyMode = KeyMode.parse(settings.keyMode)
        val deviceKey = settings.deviceKeyHex.takeIf { it.isNotBlank() }
            ?.let { Envelope.hexToBytes(it) }
        val hasKeyMaterial = Envelope.hasUsableKey(settings.psk) || deviceKey != null

        // Persisted intent is authoritative: BROKER trusts its endpoint, AUTO
        // probes the LAN, and P2P never probes (so a live Broker cannot recapture
        // a box that was explicitly restored to direct mode).
        val intent = settings.transportIntent
        val announces = if (intent == TransportSelector.Intent.BROKER) {
            ConnState.set(ConnState.Phase.CONNECTING_BROKER,
                "${settings.brokerHost}:${settings.brokerPort}")
            emptyList()
        } else if (intent == TransportSelector.Intent.AUTO) {
            // §2: no broker configured → tell the UI we're probing the LAN.
            ConnState.set(ConnState.Phase.DISCOVERING)
            DiscoveryProbe(
                psk = settings.psk,
                deviceId = settings.deviceId,
                authMode = if (hasKeyMaterial) AuthMode.OPTIONAL else AuthMode.OPEN,
                keyMode = keyMode,
                deviceKey = deviceKey,
            ).probe(timeoutMs = 3000)
        } else {
            emptyList()
        }

        val plan = TransportSelector.select(
            TransportSelector.Config(
                intent = intent,
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
                    onConnect = {
                        if (ownsTransportGeneration(transportGeneration, generation)) {
                            onCoordinatorConnected()
                        }
                    },
                    onMessage = { type, payload, env ->
                        if (ownsTransportGeneration(transportGeneration, generation)) {
                            onBrokerMessage(type, payload, env, generation)
                        }
                    },
                    initialKeyMode = plan.keyMode,
                    deviceKey = deviceKey,
                    brokerKey = brokerKey,
                )
            }
            is TransportSelector.Plan.P2pServer -> {
                // §14.3: no broker — we're the p2p server waiting for a controller.
                val ip = refreshDeviceIp()
                ConnState.set(ConnState.Phase.P2P_WAITING, "$ip:${plan.listenPort}")
                P2pServer(
                    psk = settings.psk,
                    deviceId = settings.deviceId,
                    groupId = settings.groupId,
                    clock = clock,
                    // §14.3: a controller dialing in is now watching → open the
                    // thumbnail gate (§6.4). We are the coordinator; no hello to send.
                    onConnect = {
                        if (ownsTransportGeneration(transportGeneration, generation)) {
                            controllerPresent = true
                            ConnState.set(ConnState.Phase.P2P_CONNECTED)
                        }
                    },
                    onMessage = { type, payload, env ->
                        if (ownsTransportGeneration(transportGeneration, generation)) {
                            onBrokerMessage(type, payload, env, generation)
                        }
                    },
                    // §2 可见性:控制器已连上(WS 握手过)但入站帧持续被丢弃时,
                    // 不再误报"已连接"。把丢弃原因写进 P2P_CONNECTED 的 detail,
                    // 让设置页/远程截图能一眼看出"连着但收不下消息 + 为什么"。
                    onInboundDrop = { reason, _ ->
                        if (ownsTransportGeneration(transportGeneration, generation) && controllerPresent) {
                            ConnState.set(
                                ConnState.Phase.P2P_CONNECTED,
                                "已连接但丢帧: $reason",
                            )
                        }
                    },
                    initialAuthMode = plan.authMode,
                    initialKeyMode = plan.keyMode,
                    deviceKey = deviceKey,
                    listenPort = plan.listenPort,
                )
            }
        }
        if (!ownsTransportGeneration(transportGeneration, generation)) {
            try { newLink.stop() } catch (_: Exception) {}
            return
        }
        link = newLink
        newLink.start()
        startDiscoveryResponder(plan)

        // loops that depend on the link start once; rebuildTransport reuses them.
        if (!transportLoopsStarted) {
            transportLoopsStarted = true
            scope.launch { statusLoop() }
            scope.launch { thumbnailLoop() }
        }
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
                val hint = if (settings.transportIntent == TransportSelector.Intent.BROKER) {
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
                    authMode = plan.authMode,
                    keyMode = plan.keyMode,
                    deviceKey = deviceKey,
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
    /** status/thumbnail loops start once; transport rebuild only swaps the link. */
    @Volatile private var transportLoopsStarted = false

    override fun onDestroy() {
        prepareGeneration.cancel()
        prepareWaiter.getAndSet(null)?.cancel()
        cancelLoopBoundarySync("service_destroy")
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

    private fun refreshDeviceIp(): String {
        val ip = AndroidNet.detectLanIp()
        if (ip != deviceIp) {
            deviceIp = ip
            discovery?.updateIp(ip)
        }
        return ip
    }

    // --- §4 hello on (re)connect -------------------------------------
    /** Fired when the coordinator link comes up. In client mode (A/B) this is a
     *  broker (re)connect → send `hello` (§4). In p2p mode the player IS the
     *  coordinator and sends `welcome` from [P2pServer] instead, so this is only
     *  wired for the client path. */
    private fun onCoordinatorConnected() {
        ConnState.set(ConnState.Phase.CONNECTED_BROKER, ConnState.detail)
        val ip = refreshDeviceIp()
        val payload = jsonObj {
            put("role", "player")
            put("device_id", settings.deviceId)
            put("device_name", settings.deviceName)
            put("platform", "android")
            put("app_version", Settings.APP_VERSION)
            put("ip", ip)
            put("screen", screenJson())
            // §27/§28 cache_cleanup_v1 / cache_inventory_v1 advertised ONLY now
            // that this player has live handlers that parse the request, run the
            // proven-safe planner against a real snapshot adapter, and emit a
            // terminal cache_cleanup_result / cache_inventory_result (capability
            // truth, E0001). A player without these handlers must NOT advertise
            // them, so a controller never sends and silently times out.
            put("capabilities", jsonStrArr(listOf("video", "image", "audio",
                "thumbnail", "cache_cleanup_v1", "cache_inventory_v1",
                "runtime_modes_v1", "music_shuffle_v1", "music_playlist_snapshot_v1")))
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
        val ip = refreshDeviceIp()
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
            // §5.1 / §5.2: device_name is part of the status identity set. Without
            // it the controller wall falls back to device_id after configure_device
            // renames the box, so remote rename looks like a no-op.
            put("device_name", settings.deviceName)
            put("online", true)
            put("group_id", settings.groupId)
            put("state", effectiveState())
            put("runtime_mode", runtimeModeState.current.wire)
            put("previous_active_mode", runtimeModeState.previousActive.wire)
            put("mode_generation", modeGeneration.get())
            put("music_playlist_id", musicPlaylist?.playlistId ?: "")
            musicPlaylist?.let { put("music_playlist_revision", it.revision) }
            put("music_playlist_size", musicPlaylist?.items?.size ?: 0)
            put("active_music_playlist", musicPlaylist?.raw ?: Json.Null)
            put("music_current_item_id", musicCurrentItemId)
            put("music_shuffle_cycle", musicShuffle.cycle)
            put("music_play_count", musicPlayCount)
            put("music_failed_item_ids", jsonStrArr(musicFailures.sorted()))
            settings.standbySinceMs.takeIf { it > 0L }?.let { put("standby_since_ms", it) }
            put("current", currentJson)
            put("playlist_id", playlist?.playlistId)
            // Per-replace command identity: unlike playlist_id, this is never
            // reused and therefore proves that this exact job was adopted.
            put("push_id", playlist?.raw?.get("push_id")?.asString())
            put("active_playlist", playlist?.raw ?: Json.Null)
            // §6.3: the current position WITHIN the ordered active playlist, so a
            // controller shows/scrubs the real item instead of guessing. Additive
            // (forward-compat: old controllers ignore unknown fields).
            put("current_index", index)
            playlist?.let { put("playlist_count", it.items.size) }
            put("volume", settings.volume)
            put("muted", settings.muted)
            put("audio_master", audioMaster)
            put("cache", cacheJson())
            // §26 lightweight cache summary (totals/reclaimable/protected) so the
            // device wall shows cache pressure without carrying the full per-item
            // inventory in every 1–2s status. The full list is pulled on demand
            // via §28 cache_inventory. Additive (forward-compat).
            put("cache_summary", cacheSummaryJson())
            // Capabilities travel in status too: P2P has no player hello and
            // broker wall snapshots are rebuilt from status.
            put("capabilities", jsonStrArr(listOf("video", "image", "audio",
                "thumbnail", "cache_cleanup_v1", "cache_inventory_v1",
                "loop_boundary_sync_v1", "runtime_modes_v1", "music_shuffle_v1", "music_playlist_snapshot_v1")))
            activeLoopSync?.let { epoch ->
                put("loop_sync", jsonObj {
                    put("session_id", epoch.sessionId)
                    put("item_id", epoch.itemId)
                    put("play_at", epoch.playAtMasterMs)
                    put("boundary_count", loopBoundaryCount)
                    put("correction_count", loopCorrectionCount)
                    lastLoopDriftMs?.let { put("drift_ms", it) }
                    lastLoopExpectedMs?.let { put("expected_position_ms", it) }
                    put("tolerance_ms", LOOP_BOUNDARY_TOLERANCE_MS)
                    put("mode", "boundary_only")
                })
            }
            put("config_capabilities", configCapabilitiesJson())
            put("config_snapshot", configSnapshotJson())
            put("clock_offset_ms", clock.offsetMs)
            put("app_version", Settings.APP_VERSION)
            put("ip", ip)
            // §5.1: resource telemetry. `cpu` kept for backward-compat with the
            // documented shape; low-end boxes can't read per-app CPU without
            // root, so we report an honest 0 rather than a fabricated value.
            // Memory IS readable everywhere via ActivityManager.MemoryInfo, so
            // we add real mem_* fields (controllers ignore unknown fields, §5.1).
            put("cpu", 0)
            putMemory(this)
            readTempC()?.let { put("temp_c", it) }
            // §backend-ab: which video kernel is live (+ why), so an operator/remote
            // dashboard can see old-vs-native at a glance. Additive field (§5.1
            // forward-compat: controllers ignore unknown fields).
            MainActivity.backendDecisionLabel?.let { put("video_backend", it) }
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

    // --- §26/§27/§28 cache adapter view + wire serialization ---------
    /** Read-only live-state seam handed to [LiveCacheBackend]. Reads current
     *  fields lazily so a long-lived backend always plans against the CURRENT
     *  generation (the fail-closed guard depends on it). */
    private val playerCacheView = object : LiveCacheBackend.PlayerView {
        override fun activePlaylist(): Playlist? {
            val visual = playlist
            val musicItems = musicPlaylist?.items ?: emptyList()
            if (musicItems.isEmpty()) return visual
            if (visual != null) {
                val union = (visual.items + musicItems).distinctBy { it.itemId }
                return visual.withItems(union)
            }
            return musicPlaylist?.let { Playlist.fromJson(it.raw) }
        }
        override fun playState(): String = playState
        override fun currentItem(): MediaItem? = this@PlayerService.currentItem()
        override fun resolvePlaylist(playlistId: String?): Playlist? =
            this@PlayerService.resolvePlaylist(playlistId)
        override fun lastTask(): LastTask? = mediaStore.getLastTask()
        override fun knownPlaylists(): List<Playlist> {
            val out = ArrayList<Playlist>()
            playlist?.let { out.add(it) }
            // history supplies identity only; presence never protects a blob.
            for (pl in mediaStore.pruneAndListReferenced(KEEP_RECENT_PLAYLISTS)) {
                if (out.none { it.playlistId == pl.playlistId }) out.add(pl)
            }
            return out
        }
        // MUST call the outer helper. A same-named call here resolves to THIS
        // override (Kotlin name resolution) and StackOverflows every time
        // cache_cleanup builds summary_after — the observed selected-cleanup crash.
        override fun cacheSummary(): Map<String, Any?> = buildCacheSummaryMap()
    }

    /** §26 lightweight summary map (shared by status + cleanup summary_after). */
    private fun buildCacheSummaryMap(): Map<String, Any?> {
        val backend = LiveCacheBackend(playerCacheView, downloader)
        val snapshot = backend.buildSnapshot()
        var readyItems = 0
        var totalBytes = 0L
        var protectedItems = 0
        var reclaimableItems = 0
        var reclaimableBytes = 0L
        for (it in backend.inventory()) {
            val key = backend.contentKeyOf(it)
            val size = if (key != null) backend.sizeOf(key) else null
            readyItems++
            if (size != null) totalBytes += size
            val c = snapshot.classifyItem(it.itemId)
            if (c.reason != null && c.reason != CacheReferenceSnapshot.NOT_FOUND) {
                protectedItems++
            } else {
                reclaimableItems++
                if (size != null) reclaimableBytes += size
            }
        }
        return linkedMapOf(
            "ready_items" to readyItems,
            "total_bytes" to totalBytes,
            "reclaimable_items" to reclaimableItems,
            "reclaimable_bytes" to reclaimableBytes,
            "protected_items" to protectedItems,
            "inflight_items" to downloader.inflightPaths().size,
            "last_cleanup_at" to lastCleanupAt,
            "last_cleanup_error" to lastCleanupError,
        )
    }

    private fun cacheSummaryJson(): Json = summaryMapJson(buildCacheSummaryMap())

    private fun summaryMapJson(m: Map<String, Any?>): Json = jsonObj {
        for ((k, v) in m) when (v) {
            is Int -> put(k, v)
            is Long -> put(k, v)
            is Boolean -> put(k, v)
            is String -> put(k, v)
            null -> putNull(k)
            else -> put(k, v.toString())
        }
    }

    /** §28 full per-item inventory rows (item_id/content_key/bytes/state/
     *  protection_reasons/last_access_ms). */
    private fun inventoryItems(): List<Json> {
        val backend = LiveCacheBackend(playerCacheView, downloader)
        val snapshot = backend.buildSnapshot()
        val out = ArrayList<Json>()
        for (it in backend.inventory()) {
            val key = backend.contentKeyOf(it)
            val c = snapshot.classifyItem(it.itemId)
            val reasons = ArrayList<String>()
            if (c.reason != null && c.reason != CacheReferenceSnapshot.NOT_FOUND) {
                reasons.add(c.reason)
            }
            out.add(jsonObj {
                put("item_id", it.itemId)
                put("content_key", key)
                (if (key != null) backend.sizeOf(key) else null)
                    ?.let { b -> put("bytes", b) } ?: putNull("bytes")
                put("state", "ready")
                put("protection_reasons", jsonStrArr(reasons))
                put("last_access_ms", 0L)
            })
        }
        return out
    }

    /** §27 terminal cache_cleanup_result payload (wire schema, protocol §27). */
    private fun cleanupResultJson(r: CacheCleanup.CleanupResult): Json = jsonObj {
        put("request_id", r.requestId)
        put("operation_fingerprint", r.operationFingerprint)
        put("device_id", settings.deviceId)
        put("ok", r.ok)
        put("error", r.error)
        put("dry_run", r.dryRun)
        put("mode", r.mode)
        put("reason", r.reason)
        put("expected_push_id", r.expectedPushId)
        put("observed_push_id", r.observedPushId)
        put("deleted", jsonArr(r.deleted.map { d ->
            jsonObj {
                put("item_id", d.itemId)
                put("content_key", d.contentKey)
                put("bytes", d.bytes)
            }
        }))
        put("skipped", jsonArr(r.skipped.map { s ->
            jsonObj { put("item_id", s.itemId); put("reason", s.reason) }
        }))
        put("failed", jsonArr(r.failed.map { f ->
            jsonObj { put("item_id", f.itemId); put("reason", f.reason) }
        }))
        put("freed_bytes", r.freedBytes)
        put("summary_after", summaryMapJson(r.summaryAfter))
        if (r.idempotentReplay) put("idempotent_replay", true)
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
    private fun onBrokerMessage(type: String, payload: Json.Obj, env: Envelope.Parsed,
        generation: Long) {
        when (type) {
            "cache_prefetch" -> hCachePrefetch(payload)
            // §27/§28 destructive/inventory ops. Handled OFF the generic-ack
            // path (below): the player emits ONLY the terminal structured result,
            // never an optimistic ack that could be mistaken for "files deleted".
            "cache_cleanup" -> { hCacheCleanup(payload); return }
            "cache_inventory" -> { hCacheInventory(payload); return }
            "music_playlist" -> { hMusicPlaylist(payload); return }
            "set_runtime_mode" -> { hSetRuntimeMode(payload); return }
            "restore_runtime_mode" -> { hRestoreRuntimeMode(payload); return }
            "playlist" -> hPlaylist(payload)
            "prepare" -> hPrepare(payload)
            "play_at" -> hPlayAt(payload)
            "pause" -> hPause(payload)
            "resume" -> hResume(payload)
            "stop" -> hStop(payload)
            "next" -> hAdvance(payload, +1)
            "prev" -> hAdvance(payload, -1)
            "debug_snapshot" -> hDebugSnapshot(payload)
            "download_logs" -> hDownloadLogs(payload)
            "restart" -> { hRestart(payload, env); return }
            "reboot" -> { hReboot(payload, env); return }
            "set_volume" -> hSetVolume(payload)
            "set_mute" -> hSetMute(payload)
            "set_audio_master" -> hSetAudioMaster(payload)
            "assign_group" -> hAssignGroup(payload)
            "configure_device" -> hConfigureDevice(payload, env)
            "transport_configure" -> hTransportConfigure(payload)
            "rotate_device_key" -> hRotateDeviceKey(payload, env)
            "update_app" -> hUpdateApp(payload, env)
            "resume_last" -> scope.launch { resumeLast() }
            "welcome" -> hWelcome(payload, generation)
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

    private fun hWelcome(payload: Json.Obj, generation: Long) {
        lastBrokerWelcomeGeneration = generation
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

    // --- §27/§28 cache cleanup + inventory (cache_cleanup_v1) --------
    /** Long-lived cleanup transaction (holds the idempotency journal). */
    @Synchronized private fun cleanup(): CacheCleanup {
        var c = cleanupObj
        if (c == null) {
            c = CacheCleanup(LiveCacheBackend(playerCacheView, downloader), cacheGenerationLock)
            cleanupObj = c
        }
        return c
    }

    /**
     * §27: async destructive op. NO optimistic generic ack — the player emits
     * ONLY the terminal cache_cleanup_result (truthfulness, E0001). Scanning /
     * deletion runs on [Dispatchers.IO] so the receive loop, heartbeat and
     * playback transitions never stall (design req. 10).
     */
    private fun hCacheCleanup(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        val requestIdNode = payload.entries["request_id"]
        val modeNode = payload.entries["mode"]
        val dryRunNode = payload.entries["dry_run"] ?: Json.Bool(false)
        val itemIdsNode = payload.entries["item_ids"]
        val requestId = (requestIdNode as? Json.Str)?.value
        val mode = (modeNode as? Json.Str)?.value
        val dryRun = (dryRunNode as? Json.Bool)?.value
        val itemIds = (itemIdsNode as? Json.Arr)?.items?.mapNotNull {
            (it as? Json.Str)?.value
        }
        val selectedValid = mode != "selected" ||
            (itemIdsNode is Json.Arr && itemIds != null &&
                itemIds.size == itemIdsNode.items.size && itemIds.all { it.isNotBlank() } &&
                itemIds.isNotEmpty())
        val expectedPushId = (payload.entries["expected_push_id"] as? Json.Str)?.value
        val destructiveValid = dryRun == true ||
            (mode == "selected" && selectedValid && !expectedPushId.isNullOrBlank())
        if (requestId.isNullOrBlank() || mode !in setOf("selected", "unreferenced") ||
            dryRun == null || !selectedValid || !destructiveValid) {
            return
        }
        val req = CacheCleanup.Request(
            requestId = requestId,
            mode = mode!!,
            itemIds = itemIds,
            dryRun = dryRun,
            expectedPushId = expectedPushId,
            reason = payload["reason"].asString() ?: "manual",
            // §27 fingerprint target is PAYLOAD-derived, byte-identical to the
            // broker + Windows: group:<gid> for a group-addressed request, else
            // device:<did>, else all. Hard-coding device:<settings.deviceId>
            // made group cleanups fail the broker's result-fingerprint gate.
            target = CacheCleanup.targetFor(
                payload["device_id"].asString(), payload["group_id"].asString()),
        )
        scope.launch(Dispatchers.IO) {
            val result = cleanup().run(req)
            if (!req.dryRun) {
                lastCleanupAt = System.currentTimeMillis()
                lastCleanupError = if (result.ok) "" else result.error
            }
            link?.send("cache_cleanup_result",
                cleanupResultJson(result), to = "controller")
        }
    }

    /** §28: on-demand full per-item inventory (never in periodic status). */
    private fun hCacheInventory(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        val requestId = payload["request_id"].asString() ?: ""
        scope.launch(Dispatchers.IO) {
            val items = inventoryItems()
            link?.send("cache_inventory_result", jsonObj {
                put("request_id", requestId)
                put("device_id", settings.deviceId)
                put("items", jsonArr(items))
            }, to = "controller")
        }
    }

    // --- §6.3 playlist -----------------------------------------------
    /**
     * §6.3 replace-vs-append. The inbound frame carries an explicit `mode`
     * (default "replace" = legacy swap-and-restart; "append" = merge onto the
     * current ordered sequence, de-duped by item_id — see [PlaylistOps]). This
     * separates the ORDERED ACTIVE PLAYLIST (what plays, with a current index)
     * from the CACHE INVENTORY (what's on disk) so single-item pushes no longer
     * collapse prev/next to the last item. The merged sequence is persisted
     * verbatim under the frame's playlist_id so restart restores order+index.
     */
    private fun hPlaylist(payload: Json.Obj) {
        synchronized(cacheGenerationLock) {
        val incoming = Playlist.fromJson(payload) ?: return
        val mode = PlaylistOps.Mode.parse(payload["mode"].asString())
        // §6.3a: empty REPLACE means "clear and stop". Persisting an empty
        // playlist alone is insufficient because the old decoder/timer/frame
        // would keep running.
        if (PlaylistOps.isClear(mode, incoming.items)) {
            clearActivePlaylist(incoming.playlistId)
            return
        }
        val prev = playlist
        // APPEND merges onto the current sequence but keeps the current playlist's
        // identity so navigation/persistence stay coherent; REPLACE adopts the
        // incoming playlist wholesale (its id becomes the active session).
        val pl: Playlist
        val newIndex: Int
        if (mode == PlaylistOps.Mode.APPEND && prev != null) {
            val merged = PlaylistOps.merge(prev.items, index, incoming.items, mode)
            pl = prev.withItems(merged.items)
            newIndex = merged.index
        } else {
            val merged = PlaylistOps.merge(
                current = emptyList(), currentIndex = 0,
                incoming = incoming.items, mode = PlaylistOps.Mode.REPLACE,
            )
            pl = incoming.withItems(merged.items)
            newIndex = merged.index
            scheduledStart.getAndSet(null)?.cancel()
            restoreTask.getAndSet(null)?.cancel()
            prepareGeneration.cancel()
            prepareWaiter.getAndSet(null)?.cancel()
            dwellTimer.getAndSet(null)?.cancel()
            cancelLoopBoundarySync("playlist_replace")
        }
        playlist = pl
        index = newIndex
        logEvent("playlist mode=${mode.wire} id=${pl.playlistId} items=${pl.items.size} " +
            "index=$index ids=${pl.items.joinToString(",") { it.itemId }}")
        mediaStore.storePlaylist(pl)
        // Persist the ordered playlist's identity + current index so a restart
        // restores the SAME item within the merged sequence (§6.3/§11). Without
        // this an append would round-trip the order but resume at a stale index.
        persistLastTask(pl.playlistId, newIndex, 0)
        updateCacheProtection(pl)
        // §6 假闪存:投送新内容后、拉新媒体之前,先回收不再被任何近期 playlist 引用的
        // 旧媒体,给真实颗粒腾余量(prefetch 内部还会做配额 LRU + 写前探针)。
        reclaimOrphans(pl)
        if (pl.items.isNotEmpty()) downloader.prefetch(pl.items)
        }
    }

    private fun hMusicPlaylist(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        val requestId = payload["request_id"].asString() ?: ""
        val incoming = MusicPlaylist.fromJson(payload)
        if (incoming == null) {
            sendMusicPlaylistResult(requestId, false, "invalid_audio_playlist", null)
            return
        }
        val current = musicPlaylist
        if (current != null && incoming.revision < current.revision) {
            sendMusicPlaylistResult(requestId, false, "stale_revision", current.revision)
            return
        }
        if (current != null && incoming.revision == current.revision && current != incoming) {
            sendMusicPlaylistResult(requestId, false, "revision_conflict", current.revision)
            return
        }
        if (current != incoming) {
            musicPlaylist = incoming
            mediaStore.storeMusicPlaylist(incoming)
            musicShuffle.reset()
            musicFailures = emptySet()
            musicCurrentItemId = null
            updateCacheProtection(playlist)
            if (incoming.items.isNotEmpty()) downloader.prefetch(incoming.items)
            if (runtimeModeState.current == PlaybackMode.MUSIC) {
                val generation = cancelMediaOwners("music_playlist_replace")
                MainActivity.instance?.showIdle()
                scope.launch { playNextMusic(generation) }
            }
        }
        sendMusicPlaylistResult(requestId, true, "", incoming.revision)
    }

    private fun sendMusicPlaylistResult(requestId: String, ok: Boolean,
                                        error: String, revision: Long?) {
        link?.send("music_playlist_result", jsonObj {
            put("request_id", requestId)
            put("device_id", settings.deviceId)
            put("ok", ok)
            put("playlist_id", musicPlaylist?.playlistId ?: "")
            revision?.let { put("revision", it) }
            put("error", error)
        }, to = "controller")
    }

    private fun hSetRuntimeMode(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        val requestId = payload["request_id"].asString() ?: ""
        val target = PlaybackMode.parse(payload["mode"].asString())
        if (target == null) {
            sendRuntimeModeResult(requestId, false, "invalid_mode")
            return
        }
        applyRuntimeMode(target, restore = false)
        sendRuntimeModeResult(requestId, true, "")
    }

    private fun hRestoreRuntimeMode(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        val requestId = payload["request_id"].asString() ?: ""
        if (runtimeModeState.current != PlaybackMode.STANDBY) {
            sendRuntimeModeResult(requestId, false, "not_in_standby")
            return
        }
        applyRuntimeMode(null, restore = true)
        sendRuntimeModeResult(requestId, true, "")
    }

    private fun sendRuntimeModeResult(requestId: String, ok: Boolean, error: String) {
        link?.send("runtime_mode_result", jsonObj {
            put("request_id", requestId)
            put("device_id", settings.deviceId)
            put("ok", ok)
            put("runtime_mode", runtimeModeState.current.wire)
            put("previous_active_mode", runtimeModeState.previousActive.wire)
            put("error", error)
        }, to = "controller")
    }

    private fun applyRuntimeMode(target: PlaybackMode?, restore: Boolean) {
        val generation = cancelMediaOwners(if (restore) "mode_restore" else "mode_set")
        val actual = if (restore) runtimeModeState.restore()
            else runtimeModeState.setMode(target ?: PlaybackMode.VISUAL)
        settings.runtimeMode = actual.wire
        settings.previousActiveMode = runtimeModeState.previousActive.wire
        if (actual == PlaybackMode.STANDBY) {
            if (settings.standbySinceMs <= 0L) settings.standbySinceMs = System.currentTimeMillis()
        } else {
            settings.standbySinceMs = 0L
        }
        when (actual) {
            PlaybackMode.STANDBY -> MainActivity.instance?.showIdle()
            PlaybackMode.MUSIC -> {
                MainActivity.instance?.showIdle()
                scope.launch { playNextMusic(generation) }
            }
            PlaybackMode.VISUAL -> scope.launch { resumeLast() }
        }
        logEvent("runtime_mode mode=${actual.wire} previous=${runtimeModeState.previousActive.wire} generation=$generation")
    }

    private fun cancelMediaOwners(reason: String): Long {
        val generation = modeGeneration.incrementAndGet()
        scheduledStart.getAndSet(null)?.cancel()
        restoreTask.getAndSet(null)?.cancel()
        prepareGeneration.cancel()
        prepareWaiter.getAndSet(null)?.cancel()
        dwellTimer.getAndSet(null)?.cancel()
        cancelLoopBoundarySync(reason)
        controllerRef?.onVideoEnded = null
        controllerRef?.stop()
        musicCurrentItemId = null
        playState = "idle"
        return generation
    }

    private suspend fun playNextMusic(generation: Long) {
        if (generation != modeGeneration.get() || runtimeModeState.current != PlaybackMode.MUSIC) return
        val pl = musicPlaylist
        val candidates = pl?.items?.filterNot { it.itemId in musicFailures } ?: emptyList()
        val itemId = musicShuffle.next(candidates.map { it.itemId })
        val item = candidates.firstOrNull { it.itemId == itemId }
        val ctl = controllerRef
        if (item == null || ctl == null) {
            musicCurrentItemId = null
            playState = if (pl != null && pl.items.isNotEmpty() && candidates.isEmpty()) "error" else "idle"
            MainActivity.instance?.showIdle()
            return
        }
        val readyFile = downloader.readyPath(item.itemId)
        readyFile?.let { downloader.touch(it) }
        val source = readyFile?.absolutePath ?: item.url
        musicCurrentItemId = item.itemId
        ctl.onVideoEnded = {
            if (generation == modeGeneration.get() && runtimeModeState.current == PlaybackMode.MUSIC) {
                scope.launch { playNextMusic(generation) }
            }
        }
        ctl.loadAndPlay(source, 0L, false)
        ctl.setVolume(settings.volume)
        ctl.setMuted(settings.muted)
        musicPlayCount += 1L
        playState = "playing"
        MainActivity.instance?.showIdle()
        logEvent("music_play item=${item.itemId} revision=${pl?.revision} cycle=${musicShuffle.cycle} count=$musicPlayCount generation=$generation")
    }

    private fun clearActivePlaylist(playlistId: String) {
        val activePlaylistId = playlist?.playlistId
        scheduledStart.getAndSet(null)?.cancel()
        restoreTask.getAndSet(null)?.cancel()
        prepareGeneration.cancel()
        prepareWaiter.getAndSet(null)?.cancel()
        dwellTimer.getAndSet(null)?.cancel()
        cancelLoopBoundarySync("playlist_clear")
        if (runtimeModeState.current == PlaybackMode.VISUAL) controllerRef?.stop()
        // Invalidate the definition too: a delayed prepare/play_at for the same
        // id must not resurrect content after CLEAR.
        activePlaylistId?.let { mediaStore.deletePlaylist(it) }
        if (playlistId != activePlaylistId) mediaStore.deletePlaylist(playlistId)
        playlist = null
        index = 0
        playState = "idle"
        persistLastTaskNull()
        updateCacheProtection(null)
        logEvent("playlist mode=replace id=$playlistId items=0 cleared=true")
        MainActivity.instance?.showIdle()
    }

    /**
     * §6 主动清理孤儿媒体:剪掉过期 playlist 记录,展开"仍被引用的媒体路径集"(最近
     * [KEEP_RECENT_PLAYLISTS] 条 + last_task + 传入的当前 [current]),回收磁盘上不再
     * 被任何一份引用的孤儿文件。protected/.part/探针由 downloader 侧兜底保护。
     */
    private fun reclaimOrphans(current: Playlist?) {
        try {
            val kept = mediaStore.pruneAndListReferenced(KEEP_RECENT_PLAYLISTS)
            val referenced = HashSet<String>()
            (kept + listOfNotNull(current)).forEach { pl ->
                pl.items.forEach { referenced.add(downloader.localPath(it).absolutePath) }
            }
            downloader.reclaimOrphans(referenced)
        } catch (_: Exception) {
            // reclaim is best-effort hygiene; never let it break playback path.
        }
    }

    /**
     * §6: tell the downloader which files back the current playlist so its
     * quota-eviction never deletes media we're about to play (§11), and refresh
     * the operator cap from Settings. Called whenever the active playlist
     * changes (playlist / prepare / resume_last).
     */
    private fun updateCacheProtection(pl: Playlist?) {
        val protectedFiles = buildSet {
            pl?.items?.forEach { add(downloader.localPath(it).absolutePath) }
            musicPlaylist?.items?.forEach { add(downloader.localPath(it).absolutePath) }
        }
        downloader.configureQuota(settings.cacheMaxBytes, protectedFiles)
        // §10/§11 重启恢复:进程重来后 downloader 的 ready 索引是空的,但媒体文件仍在
        // 磁盘。这里(resumeLast/prepare/play_at 都会经过的收口)按当前 playlist 的 items
        // 从磁盘重建 ready 索引,使随后的 readyPath 命中本地文件而非回退到失效的 item.url
        // (黑屏根因)。纯读操作,幂等,已 ready 的不重复登记。
        pl?.items?.let { if (it.isNotEmpty()) downloader.restoreReadyFromDisk(it) }
        // §6.4: drop cached thumbnails for items the active playlist no longer
        // references, so the per-item thumbnail cache can't grow unbounded. Prune
        // the bounded attempt map in lockstep so a re-added item may re-extract.
        pl?.items?.map { it.itemId }?.toSet()?.let {
            controllerRef?.retainThumbnails(it)
            thumbAttempts.keys.retainAll(it)
        }
    }

    // --- §9.1 prepare -------------------------------------------------
    private fun hPrepare(payload: Json.Obj) {
        if (runtimeModeState.current != PlaybackMode.VISUAL) return
        val pid = payload["playlist_id"].asString()
        val groupId = payload["group_id"].asString()
        val prepareId = payload["prepare_id"].asString()
        val pushId = payload["push_id"].asString()
        val startIndex = payload["start_index"].asIntOrNull() ?: 0
        val seekMs = payload["seek_ms"].asLongOrNull() ?: 0L
        // §21 预缓存栅栏:prefetch=true 表示"缓存好再回 ready"。未缓存时不立刻回
        // ready:false,而是后台等下载+校验完成再回 ready:true,让全员统一从头起播。
        val prefetchBarrier = payload["prefetch"].asBoolOrNull() ?: false
        val barrierTimeoutMs = payload["barrier_timeout_ms"].asLongOrNull() ?: 120000L
        val pl = resolvePlaylist(pid)
        if (pl == null || pushId.isNullOrEmpty() || pl.pushId != pushId) return
        var ready = false
        dwellTimer.getAndSet(null)?.cancel() // §6.3: a new session voids any dwell
        cancelLoopBoundarySync("prepare")
        prepareWaiter.getAndSet(null)?.cancel() // stale prepare cannot prime/send ready
        val generation = prepareGeneration.replace()
        if (startIndex in pl.items.indices) {
            val item = pl.items[startIndex]
            synchronized(cacheGenerationLock) {
                playlist = pl
                index = startIndex
                updateCacheProtection(pl)
            }
            if (downloader.isReady(item.itemId)) {
                val readyFile = downloader.readyPath(item.itemId)
                val path = readyFile?.absolutePath
                if (path != null) {
                    prepareGeneration.runIfCurrent(generation) {
                        readyFile.let { downloader.touch(it) }
                        // §6.1: an image has no decoder to prime — it's shown at the
                        // sync instant (play_at → scheduledStart). A video primes
                        // paused so play_at just flips playWhenReady on.
                        if (item.type != "image") {
                            controllerRef?.loadPaused(path, seekMs, singleLoop(pl))
                        }
                        playState = "buffering"
                        ready = true
                        sendReady(pid, groupId, prepareId, true)
                    }
                    if (ready) return
                }
            } else if (prefetchBarrier) {
                // §21 栅栏:后台等缓存完成再回 ready,不阻塞消息循环。
                downloader.prefetchForeground(item)
                val waiter = scope.launch {
                    awaitCacheThenReady(generation, pid, groupId, prepareId, item, seekMs,
                        pl, barrierTimeoutMs)
                }
                prepareWaiter.set(waiter)
                return
            } else {
                downloader.prefetchForeground(item) // promote current item; report not-ready
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
        generation: Long, pid: String?, groupId: String?, prepareId: String?,
        item: MediaItem, seekMs: Long, pl: Playlist, timeoutMs: Long
    ) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (!prepareGeneration.isCurrent(generation)) return
            if (downloader.isReady(item.itemId)) {
                val readyFile = downloader.readyPath(item.itemId)
                val path = readyFile?.absolutePath
                if (path != null && prepareGeneration.runIfCurrent(generation) {
                    readyFile.let { downloader.touch(it) }
                    if (item.type != "image") {
                        controllerRef?.loadPaused(path, seekMs, singleLoop(pl))
                    }
                    playState = "buffering"
                    sendReady(pid, groupId, prepareId, true)
                }) return
            }
            delay(500)
        }
        prepareGeneration.runIfCurrent(generation) {
            sendReady(pid, groupId, prepareId, false)
        }
    }

    // --- §9.2 play_at (sync-critical path) ---------------------------
    private fun hPlayAt(payload: Json.Obj) {
        if (runtimeModeState.current != PlaybackMode.VISUAL) return
        val pid = payload["playlist_id"].asString()
        val pushId = payload["push_id"].asString()
        val startIndex = payload["start_index"].asIntOrNull() ?: index
        val seekMs = payload["seek_ms"].asLongOrNull() ?: 0L
        val playAt = payload["play_at"].asLongOrNull() ?: 0L
        val syncSessionId = payload["sync_session_id"].asString()
            ?.takeIf { it.isNotBlank() }
            ?: "${pushId ?: "unknown"}:$playAt:$startIndex"
        val pl = resolvePlaylist(pid) ?: return
        if (pushId.isNullOrEmpty() || pl.pushId != pushId) return
        if (startIndex !in pl.items.indices) return
        synchronized(cacheGenerationLock) {
            playlist = pl
            index = startIndex
            updateCacheProtection(pl)
        }
        val item = pl.items[startIndex]
        val readyFile = downloader.readyPath(item.itemId)
        readyFile?.let { downloader.touch(it) } // §6 LRU: mark just-used
        val source = readyFile?.absolutePath ?: item.url
        scheduledStart.getAndSet(null)?.cancel()
        cancelLoopBoundarySync("new_play_at")
        dwellTimer.getAndSet(null)?.cancel() // §6.3: new session voids any dwell
        persistLastTask(pid!!, startIndex, seekMs)
        val job = scope.launch {
            scheduledStart(source, seekMs, playAt, pl, item, syncSessionId)
        }
        scheduledStart.set(job)
    }

    private suspend fun scheduledStart(uri: String, seekMs: Long, playAt: Long,
                                       pl: Playlist, item: MediaItem,
                                       syncSessionId: String) {
        val ctl = controllerRef ?: return
        if (item.type == "image") {
            // §6.1/§6.3: nothing to prime — wait for the sync instant, then show
            // the still and start its dwell so the carousel advances.
            awaitLocal(clock.toLocal(playAt))
            ctl.showImage(uri, itemId = item.itemId)
            playState = "playing"
            MainActivity.instance?.hideIdle()
            armDwell(item)
            return
        }
        // video: prime paused at seek (idempotent if prepare already did it),
        // arm end-of-video auto-advance, then unpause at the sync instant.
        ctl.onVideoEnded = { onCurrentEnded() }
        val loop = singleLoop(pl)
        ctl.armLoopOverlay(if (loop) item.itemId else null)
        ctl.loadPaused(uri, seekMs, loop)
        // §6.4: primary thumbnail trigger — one-shot per item, fired on load so a
        // normally-playing video still yields a controller preview (the v1.14.7
        // regression left it blank). Non-blocking: never delays the synced start.
        scope.launch { captureAndSendThumbnail(item) }
        val localTarget = clock.toLocal(playAt) // §8.2 fold master → local (once)
        // §8.2: arm late-start compensation BEFORE the wait, so if prepareAsync
        // finishes after play_at the backend seeks forward by its own lateness
        // and this box lands on the same frame as peers that started on time.
        ctl.armSyncStart(localTarget, seekMs, loop)
        logEvent("sync_schedule item=${item.itemId} play_at=$playAt local_target=$localTarget " +
            "offset_ms=${clock.offsetMs} seek_ms=$seekMs loop=$loop")
        awaitLocal(localTarget)
        ctl.play()
        playState = "playing"
        MainActivity.instance?.hideIdle()
        if (loop) {
            armLoopBoundarySync(
                ActiveLoopSync(
                    sessionId = syncSessionId,
                    itemId = item.itemId,
                    playAtMasterMs = playAt,
                    baseSeekMs = seekMs,
                ),
                durationHintMs = item.durationMs ?: 0L,
            )
        }
    }

    /**
     * Schedule one sample per lap. Broker/P2P keeps [clock] mapped to the shared
     * master time; the Player owns the actual phase correction so network jitter
     * cannot turn into a seek command storm.
     */
    private fun armLoopBoundarySync(epoch: ActiveLoopSync, durationHintMs: Long) {
        cancelLoopBoundarySync("replace")
        activeLoopSync = epoch
        lastLoopDriftMs = null
        lastLoopExpectedMs = null
        loopBoundaryCount = 0L
        loopCorrectionCount = 0L
        val job = scope.launch {
            var durationMs = durationHintMs.takeIf { it > 0L } ?: 0L
            while (isActive && activeLoopSync == epoch && durationMs <= 0L) {
                val snap = controllerRef?.snapshot()
                durationMs = snap?.durationMs?.takeIf { it > 0L } ?: 0L
                if (durationMs <= 0L) delay(250)
            }
            while (isActive && activeLoopSync == epoch && durationMs > 0L) {
                val masterNow = clock.masterNow()
                val boundaryMaster = LoopBoundarySync.nextBoundaryMasterMs(
                    playAtMasterMs = epoch.playAtMasterMs,
                    baseSeekMs = epoch.baseSeekMs,
                    durationMs = durationMs,
                    masterNowMs = masterNow,
                ) ?: return@launch
                awaitLocal(clock.toLocal(boundaryMaster))
                // Let the decoder publish its new loop phase before sampling. The
                // circular drift fold still handles a box that is just before EOS.
                delay(LOOP_BOUNDARY_SAMPLE_SETTLE_MS)
                if (!isActive || activeLoopSync != epoch || playState != "playing") continue
                if (currentItem()?.itemId != epoch.itemId) return@launch
                val snap = controllerRef?.snapshot() ?: continue
                if (snap.durationMs > 0L) durationMs = snap.durationMs
                if (!snap.hasMedia || !snap.isPlaying) continue
                val decision = LoopBoundarySync.decide(
                    playAtMasterMs = epoch.playAtMasterMs,
                    baseSeekMs = epoch.baseSeekMs,
                    masterNowMs = clock.masterNow(),
                    durationMs = durationMs,
                    actualPositionMs = snap.positionMs,
                    toleranceMs = LOOP_BOUNDARY_TOLERANCE_MS,
                )
                loopBoundaryCount += 1L
                lastLoopDriftMs = decision.driftMs
                lastLoopExpectedMs = decision.expectedPositionMs
                val seekTo = decision.seekToMs
                if (seekTo != null) {
                    controllerRef?.seekTo(seekTo)
                    loopCorrectionCount += 1L
                }
                logEvent(
                    "loop_boundary_sync session=${epoch.sessionId} item=${epoch.itemId} " +
                        "boundary=$loopBoundaryCount duration_ms=$durationMs " +
                        "actual_ms=${snap.positionMs} expected_ms=${decision.expectedPositionMs} " +
                        "drift_ms=${decision.driftMs} corrected=${seekTo != null}",
                )
            }
        }
        loopBoundaryJob.set(job)
    }

    private fun cancelLoopBoundarySync(reason: String) {
        val previous = activeLoopSync
        activeLoopSync = null
        loopBoundaryJob.getAndSet(null)?.cancel()
        if (previous != null) {
            logEvent("loop_boundary_sync_cancel session=${previous.sessionId} reason=$reason")
        }
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
        scheduledStart.getAndSet(null)?.cancel()
        cancelLoopBoundarySync("pause")
        controllerRef?.pause()
        playState = "paused"
    }

    private fun hResume(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        val playAt = payload["play_at"].asLongOrNull()
        if (playAt != null && playAt > 0) {
            val localTarget = clock.toLocal(playAt)
            val job = scope.launch {
                val delayMs = (localTarget - System.currentTimeMillis()).coerceAtLeast(0)
                delay(delayMs)
                controllerRef?.play()
                playState = "playing"
                MainActivity.instance?.hideIdle()
            }
            scheduledStart.getAndSet(job)?.cancel()
        } else {
            scheduledStart.getAndSet(null)?.cancel()
            controllerRef?.play()
            playState = "playing"
            MainActivity.instance?.hideIdle()
        }
    }

    private fun hStop(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        scheduledStart.getAndSet(null)?.cancel()
        prepareGeneration.cancel()
        prepareWaiter.getAndSet(null)?.cancel()
        dwellTimer.getAndSet(null)?.cancel()
        cancelLoopBoundarySync("stop")
        controllerRef?.stop()
        playState = "idle"
        persistLastTaskNull()
        MainActivity.instance?.showIdle()
    }

    private fun hAdvance(payload: Json.Obj, delta: Int) {
        if (!targetsMe(payload)) return
        advance(delta, explicit = true)  // §6.3 explicit prev/next navigates even in ONE
    }

    /** §9.4 restart：只重启播放 App，绝不整机 reboot（§restart-semantics）。
     *
     * QZX_C1 上 warm reboot 会丢 Wi-Fi(8822CS SDIO -110,冷启动才恢复),所以普通
     * restart 必须只重启 App。改由 root 守护进程的 RESTART_APP 执行:守护进程是独立
     * root 进程(不在 App 的 uid/进程组),force-stop 掉调用方 App 后仍能把它重新拉起
     * ——这正是旧的 AlarmManager 自拉起不可靠(进程退出杀掉待发 alarm)而改走守护进程的
     * 原因。守护进程不可达/失败时只记录错误并回 ack ok=false,**绝不回退到整机 reboot**。
     * 整机重启是单独的高危 `reboot` 命令(见 [hReboot])。
     */
    private fun hRestart(payload: Json.Obj, env: Envelope.Parsed) {
        if (!targetsMe(payload)) return
        scope.launch {
            val ok = RootInstaller.restartApp()
            if (!ok) errors.add("restart:app-restart-failed")
            link?.send("ack", jsonObj {
                put("ack_of", env.msgId)
                put("ok", ok)
                // Never claims a reboot; a failed app-restart does NOT reboot.
                put("err", if (ok) "" else "app restart failed: root daemon unavailable")
            })
        }
    }

    /** §10 reboot：整机重启——单独的高危动作(不是普通 restart)。
     *
     * QZX_C1 warm reboot 会导致 SDIO Wi-Fi 卡初始化超时(-110)、wlan0 消失且只有冷启动
     * 能恢复,所以这条命令由控制端二次确认后才下发,与 app-only 的 `restart` 严格区分。
     */
    private fun hReboot(payload: Json.Obj, env: Envelope.Parsed) {
        if (!targetsMe(payload)) return
        scope.launch {
            val ok = RootInstaller.rebootDevice()
            if (!ok) errors.add("reboot:failed")
            link?.send("ack", jsonObj {
                put("ack_of", env.msgId)
                put("ok", ok)
                put("err", if (ok) "" else "reboot failed: root daemon unavailable")
            })
        }
    }

    private fun hDebugSnapshot(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        val snapshot = buildDebugSnapshot()
        link?.send("diagnostic_status", jsonObj {
            put("device_id", settings.deviceId)
            put("detail", snapshot)
            put("app_version", BuildConfig.VERSION_NAME)
        })
    }

    /**
     * Append a timestamped line to the rolling in-memory log ring and mirror it
     * to the on-disk player.log so [hDownloadLogs] can hand the controller a
     * persisted copy even across process restarts. Best-effort: disk errors are
     * swallowed (the box may be low on space) but still recorded to [errors].
     */
    private fun logEvent(msg: String) {
        val line = "${System.currentTimeMillis()} $msg"
        logBuffer.addLast(line)
        while (logBuffer.size > 500) logBuffer.pollFirst()
        synchronized(logLock) {
            try {
                if (!logDir.exists()) logDir.mkdirs()
                // Rotate once the file grows past ~256 KB so a long-running box
                // never fills storage with an unbounded log.
                if (logFile.exists() && logFile.length() > 256 * 1024L) {
                    val rotated = File(logDir, "player.log.1")
                    if (rotated.exists()) rotated.delete()
                    logFile.renameTo(rotated)
                }
                logFile.appendText(line + "\n")
            } catch (e: Exception) {
                errors.addLast("log:${e.message}")
                while (errors.size > 10) errors.pollFirst()
            }
        }
    }

    /**
     * Build the one-line structured diagnostic string returned to the controller
     * for a debug_snapshot request. Aggregates the existing debug* accessors so
     * a field added there shows up here without touching the wire format.
     */
    private fun buildDebugSnapshot(): String {
        val item = currentItemForDebug()
        return buildString {
            append("v="); append(BuildConfig.VERSION_NAME)
            append("("); append(BuildConfig.VERSION_CODE); append(")")
            append("; play="); append(debugPlayState())
            append("; idx="); append(debugIndex())
            append("; item="); append(item ?: "none")
            append("; backend="); append(debugBackend())
            append("; vdec="); append(debugVideoDecoder())
            append("; ctrl="); append(debugControllerPresent())
            append("; audio_master="); append(debugAudioMaster())
            append("; cache="); append(debugCacheSummary())
            append("; errors="); append(debugErrorsSummary())
            append("; "); append(debugHealthProbeSummary())
        }
    }

    /**
     * §debug: return a bounded diagnostics bundle, not just player.log. The
     * controller persists it under Downloads so Jay can send one file back for
     * root-cause debugging without re-running adb commands.
     */
    private fun hDownloadLogs(payload: Json.Obj) {
        if (!targetsMe(payload)) return
        val text = buildDiagnosticLogBundle()
        link?.send("download_logs_result", jsonObj {
            put("device_id", settings.deviceId)
            put("text", text)
            put("file_name", "lan-media-wall-player-${settings.deviceId}-${System.currentTimeMillis()}.log")
        })
    }

    private fun buildDiagnosticLogBundle(): String = buildString {
        appendSection("summary") {
            line("time_ms=${System.currentTimeMillis()}")
            line("device_id=${settings.deviceId}")
            line("device_name=${settings.deviceName}")
            line("group_id=${settings.groupId}")
            line("app_version=${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
            line("android_sdk=${Build.VERSION.SDK_INT}")
            line("ip=$deviceIp")
            line("transport=${link?.javaClass?.simpleName ?: "none"} connected=${link?.isConnected ?: false}")
            line("play_state=${debugPlayState()} index=${debugIndex()} controller_present=${debugControllerPresent()}")
            line("video_backend=${debugBackend()}")
            line("backend_metrics=${debugBackendMetrics()}")
            line("video_decoder=${debugVideoDecoder()}")
            line("current_item=${currentItemForDebug() ?: "none"}")
            line("cache=${debugCacheSummary()}")
            line("errors=${debugErrorsSummary()}")
            line(debugHealthProbeSummary())
        }
        appendSection("paths") {
            line("filesDir=${filesDir.absolutePath}")
            line("cacheDir=${cacheDir.absolutePath}")
            line("logDir=${logDir.absolutePath}")
            line("mediaCacheDir=${mediaStore.mediaCacheDir.absolutePath}")
        }
        appendSection("root_daemon") {
            val uid = File("/data/local/tmp/lmw_root_daemon.uid")
            val probe = com.jieoz.lanmediawall.player.update.RootInstaller.probe()
            line("socket=@lmw_root_daemon (abstract AF_UNIX)")
            line("daemon_uid_file=${readTail(uid, 4096).ifBlank { "missing-or-empty" }}")
            line("daemon_probe_ready=${probe.ready} detail=${probe.detail}")
            line("daemon_note=probe is read-only; diagnostic export never invokes install/reboot")
        }
        appendSection("player_log") {
            synchronized(logLock) {
                val rotated = File(logDir, "player.log.1")
                if (rotated.exists()) {
                    line("--- player.log.1 tail ---")
                    line(readTail(rotated, 96 * 1024))
                }
                if (logFile.exists()) {
                    line("--- player.log tail ---")
                    line(readTail(logFile, 160 * 1024))
                }
                if (!rotated.exists() && !logFile.exists()) {
                    line(logBuffer.joinToString("\n").ifBlank { "no player log yet" })
                }
            }
        }
        appendSection("logcat_tail") {
            line(runCommandTail(listOf("logcat", "-d", "-v", "time", "-t", "400"), 192 * 1024))
        }
    }.let { full ->
        val cap = 384 * 1024
        if (full.length > cap) "[TRUNCATED diagnostic bundle: kept last ${cap} chars]\n" + full.substring(full.length - cap) else full
    }

    private fun StringBuilder.appendSection(title: String, body: StringBuilder.() -> Unit) {
        line()
        line("===== $title =====")
        body()
    }

    private fun StringBuilder.line(value: Any? = "") {
        append(value ?: "")
        append('\n')
    }

    private fun readTail(file: File, maxChars: Int): String {
        return try {
            if (!file.exists()) {
                ""
            } else {
                val text = file.readText()
                if (text.length > maxChars) "[TRUNCATED ${file.name}: kept last $maxChars chars]\n" + text.substring(text.length - maxChars) else text
            }
        } catch (e: Exception) {
            "read ${file.absolutePath} failed: ${e.javaClass.simpleName}: ${e.message}"
        }
    }

    private fun runCommandTail(cmd: List<String>, maxChars: Int): String = try {
        val p = ProcessBuilder(cmd).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        val code = p.waitFor()
        val text = "exit=$code cmd=${cmd.joinToString(" ")}\n$out"
        if (text.length > maxChars) "[TRUNCATED command output: kept last $maxChars chars]\n" + text.substring(text.length - maxChars) else text
    } catch (e: Exception) {
        "command ${cmd.joinToString(" ")} failed: ${e.javaClass.simpleName}: ${e.message}"
    }


    /** §6.3 carousel step. Shared by external next/prev and the automatic
     * progressors (image dwell timer, video end-of-media). Moves [index] by
     * [delta] (wrapping when the playlist loops), then plays the new item:
     * an image is shown + its dwell armed; a video is loaded and auto-advances
     * on end. Any pending dwell is cancelled first so timers never stack.
     */
    private fun advance(delta: Int, explicit: Boolean = false) {
        if (runtimeModeState.current != PlaybackMode.VISUAL) return
        val pl = playlist ?: return
        if (pl.items.isEmpty()) return
        cancelLoopBoundarySync("advance")
        val oldItemId = pl.items.getOrNull(index)?.itemId
        dwellTimer.getAndSet(null)?.cancel()
        // §6.3 three-mode progression. ONE on an automatic (EOF/dwell) completion
        // holds the current item — the seamless repeat happens inside the decoder
        // (OEM_CONTINUOUS), so an auto-advance is a no-op re-show. An explicit
        // prev/next in ONE still navigates (with wrap). ALL wraps; NONE clamps.
        var newIndex = if (pl.loopMode == LoopMode.ONE && !explicit) index
                       else index + delta
        if (newIndex < 0 || newIndex >= pl.items.size) {
            val wrap = pl.loopMode == LoopMode.ALL ||
                (pl.loopMode == LoopMode.ONE && explicit)
            if (wrap) newIndex = ((newIndex % pl.items.size) + pl.items.size) % pl.items.size
            else return  // NONE clamps at the boundary
        }
        synchronized(cacheGenerationLock) { index = newIndex }
        val item = pl.items[newIndex]
        val readyFile = downloader.readyPath(item.itemId)
        readyFile?.let { downloader.touch(it) } // §6 LRU: mark just-used
        val source = readyFile?.absolutePath ?: item.url
        val ctl = controllerRef
        if (item.type == "image") {
            ctl?.showImage(source, itemId = item.itemId)
            armDwell(item)
        } else {
            ctl?.onVideoEnded = { onCurrentEnded() }
            // API19 SurfaceView has no PixelCopy. Prefer the near-fullscreen freeze
            // JPEG (not the small controller thumb), then rebuild the ONE MediaPlayer.
            // The backend's real first-frame callback removes it; any error removes it too.
            val strat = TransitionPolicy.transitionStrategy(
                androidSdk = Build.VERSION.SDK_INT, concurrentDecoders = 1)
            val held = oldItemId?.let { ctl?.cachedFreezeFrame(it) }
            val overlay = ctl?.showTransitionFrame(held) == true
            logEvent("transition to=${item.itemId} idx=$newIndex strategy=$strat " +
                "overlay_cached=$overlay loop_strategy=${TransitionPolicy.loopStrategy(pl.items.size, pl.loopMode)}")
            ctl?.loadAndPlay(source, 0, singleLoop(pl), preserveOverlay = overlay)
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
            if (isActive && runtimeModeState.current == PlaybackMode.VISUAL) advance(+1)
        }
        dwellTimer.getAndSet(job)?.cancel()
    }

    /** §6.3: a non-looping video finished (ExoPlayer STATE_ENDED) → step
     *  forward. Fired on the main thread, so hop to a coroutine for the I/O. */
    private fun onCurrentEnded() {
        if (runtimeModeState.current == PlaybackMode.VISUAL) scope.launch { advance(+1) }
    }

    /** §6.3 loop semantics: only a *single-item* looping playlist maps to OEM
     *  continuous looping (setLooping/REPEAT_MODE_ONE) — no completion/reprepare,
     *  so no black seam. A multi-item loop must reach end-of-stream so we can
     *  advance + wrap. Single source of truth: [TransitionPolicy.loopStrategy]. */
    private fun singleLoop(pl: Playlist): Boolean =
        TransitionPolicy.loopStrategy(pl.items.size, pl.loopMode) ==
            TransitionPolicy.LoopStrategy.OEM_CONTINUOUS

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

    // --- §19 remote configuration ------------------------------------
    private fun configCapabilitiesJson() = jsonObj {
        put("safe_fields", jsonStrArr(listOf("device_name", "group_id", "volume", "muted")))
        put("transport_fields", jsonStrArr(listOf("transport_mode", "broker_host", "broker_port", "use_wss")))
        put("transport_configure", true)
        put("rotate_device_key", true)
        put("config_version", 2)
    }

    private fun configSnapshotJson() = jsonObj {
        put("revision", settings.configRevision)
        put("values", jsonObj {
            put("device_name", settings.deviceName); put("group_id", settings.groupId)
            put("volume", settings.volume); put("muted", settings.muted)
            put("psk_configured", settings.psk != Settings.DEFAULT_PSK)
        })
        put("transport", jsonObj {
            put("broker_host", settings.brokerHost); put("broker_port", settings.brokerPort)
            put("use_wss", settings.useWss)
            put("transport_mode", settings.transportIntent.wire)
            put("auto_discovery", settings.transportIntent == TransportSelector.Intent.AUTO)
        })
        put("pending", jsonObj {}); put("requires_restart", false)
    }

    private fun sendConfigResult(requestId: String?, ok: Boolean, applied: Json.Obj = jsonObj {},
        rejected: Json = jsonArr(emptyList<Json>()), conflict: Boolean = false,
        pending: Json.Obj = jsonObj {}) {
        link?.send("config_patch_result", jsonObj {
            requestId?.let { put("request_id", it) }
            put("device_id", settings.deviceId); put("ok", ok); put("conflict", conflict)
            put("revision", settings.configRevision); put("applied", applied); put("rejected", rejected)
            put("pending", pending); put("requires_restart", false)
        })
    }

    /** Safe patch: fields are deliberately limited to name/group/audio. */
    private fun hConfigureDevice(payload: Json.Obj, env: Envelope.Parsed) {
        if (payload["device_id"].asString() != settings.deviceId) return
        val requestId = payload["request_id"].asString()
        val base = payload["base_revision"].asIntOrNull()
        if (requestId != null && base != null && base != settings.configRevision) {
            sendConfigResult(requestId, false, rejected = jsonArr(listOf(jsonObj {
                put("field", "_revision"); put("reason", "conflict")
            })), conflict = true)
            return
        }
        val allowed = setOf("device_id", "request_id", "base_revision", "device_name", "group_id", "volume", "muted")
        val rejected = payload.entries.keys.filter { it !in allowed }.map { key -> jsonObj {
            put("field", key); put("reason", when (key) {
                "transport_mode", "broker_host", "broker_port", "use_wss" -> "high_risk_transport"
                "psk" -> "high_risk_secret"
                else -> "unknown_field"
            })
        } }
        val changed = LinkedHashMap<String, Json>()
        payload["device_name"].asString()?.trim()?.takeIf { it.isNotBlank() }?.let { next ->
            if (next != settings.deviceName) {
                settings.deviceName = next; discovery?.updateName(next); changed["device_name"] = Json.Str(next)
            }
        }
        payload["group_id"].asString()?.trim()?.takeIf { it.isNotBlank() }?.let { next ->
            if (next != settings.groupId) { settings.groupId = next; changed["group_id"] = Json.Str(next) }
        }
        payload["volume"].asIntOrNull()?.let { next ->
            val vol = next.coerceIn(0, 100)
            if (vol != settings.volume) {
                settings.volume = vol; controllerRef?.currentVolumePercent = vol; controllerRef?.setVolume(vol)
                changed["volume"] = Json.Num.of(vol)
            }
        }
        payload["muted"].asBoolOrNull()?.let { next ->
            if (next != settings.muted) { settings.muted = next; controllerRef?.setMuted(next); changed["muted"] = Json.Bool(next) }
        }
        if (changed.isNotEmpty()) settings.bumpConfigRevision()
        if (changed.isNotEmpty()) try { sendStatus() } catch (_: Exception) {}
        if (requestId != null) sendConfigResult(requestId, rejected.isEmpty(), Json.Obj(changed), jsonArr(rejected))
    }

    private fun hTransportConfigure(payload: Json.Obj) {
        if (payload["device_id"].asString() != settings.deviceId) return
        val requestId = payload["request_id"].asString()
        val host = payload["broker_host"].asString()
        if (host == null) {
            sendConfigResult(requestId, false, rejected = jsonArr(listOf(jsonObj {
                put("field", "broker_host"); put("reason", "invalid_value")
            })));
            return
        }
        val previousHost = settings.brokerHost
        val previousPort = settings.brokerPort
        val previousWss = settings.useWss
        val previousIntent = settings.transportIntent
        val next = host.trim()
        val hasIntent = payload.entries.containsKey("transport_mode")
        val rawIntent = payload["transport_mode"].asString()
        val requestedIntent = if (!hasIntent) {
            // Legacy controllers used an empty endpoint to return to discovery;
            // only the new explicit field is allowed to create sticky P2P.
            if (next.isEmpty()) TransportSelector.Intent.AUTO else TransportSelector.Intent.BROKER
        } else TransportSelector.Intent.fromWire(rawIntent)
        val hasPort = payload.entries.containsKey("broker_port")
        val requestedPort = payload["broker_port"].asIntOrNull()
        val hasUseWss = payload.entries.containsKey("use_wss")
        val requestedUseWss = payload["use_wss"].asBoolOrNull()
        if (requestedIntent == null ||
            (requestedIntent == TransportSelector.Intent.BROKER) != next.isNotEmpty() ||
            (hasPort && (requestedPort == null || requestedPort !in 1..65535)) ||
            (hasUseWss && requestedUseWss == null)
        ) {
            sendConfigResult(requestId, false, rejected = jsonArr(listOf(jsonObj {
                put("field", when {
                    requestedIntent == null -> "transport_mode"
                    hasPort && (requestedPort == null || requestedPort !in 1..65535) -> "broker_port"
                    hasUseWss && requestedUseWss == null -> "use_wss"
                    else -> "transport_mode"
                })
                put("reason", "invalid_value")
            })))
            return
        }
        val nextPort = requestedPort ?: settings.brokerPort
        val nextWss = requestedUseWss ?: settings.useWss
        val appliedRevision = try {
            settings.commitTransport(requestedIntent, next, nextPort, nextWss)
        } catch (t: Throwable) {
            sendConfigResult(requestId, false, rejected = jsonArr(listOf(jsonObj {
                put("field", "transport_mode"); put("reason", "persist_failed")
            })))
            return
        }
        val rollbackTimeoutMs = (payload["rollback_timeout_ms"].asLongOrNull()
            ?: TRANSPORT_ROLLBACK_TIMEOUT_MS).coerceIn(10_000L, 120_000L)
        // Return the durable readback while the old link is still alive. Only
        // after this terminal result is on the wire do we tear down P2P/current
        // broker and try the new endpoint.
        try {
            sendConfigResult(requestId, true, jsonObj {
                put("broker_host", settings.brokerHost); put("broker_port", settings.brokerPort)
                put("use_wss", settings.useWss); put("transport_mode", settings.transportIntent.wire)
                put("auto_discovery", settings.transportIntent == TransportSelector.Intent.AUTO)
            }, pending = jsonObj { put("transport", "reconnecting") })
        } catch (t: Throwable) {
            settings.commitTransport(previousIntent, previousHost, previousPort, previousWss)
            logEvent("transport_configure_ack_failed restored=${previousIntent.wire}")
            return
        }
        scope.launch {
            // Publish the committed snapshot over the still-live old route before
            // tearing it down; the Controller uses this as phase-1 readback.
            try {
                sendStatus()
            } catch (t: Throwable) {
                if (settings.configRevision == appliedRevision) {
                    settings.commitTransport(previousIntent, previousHost, previousPort, previousWss)
                }
                logEvent("transport_configure_status_failed restored=${previousIntent.wire}")
                return@launch
            }
            delay(150)
            try {
                rebuildTransport()
            } catch (t: Throwable) {
                ConnState.set(ConnState.Phase.START_FAILED, t.message ?: "transport rebuild failed")
            }
            val expectedGeneration = transportGeneration
            // Clearing a broker intentionally returns to P2P and needs no broker
            // welcome. A later config revision supersedes this rollback owner.
            if (requestedIntent != TransportSelector.Intent.BROKER) return@launch
            val deadline = System.currentTimeMillis() + rollbackTimeoutMs
            while (isActive && System.currentTimeMillis() < deadline &&
                settings.configRevision == appliedRevision) {
                if (lastBrokerWelcomeGeneration == expectedGeneration) {
                    logEvent("transport_configure_committed revision=$appliedRevision")
                    return@launch
                }
                delay(250)
            }
            if (!isActive || settings.configRevision != appliedRevision ||
                lastBrokerWelcomeGeneration == expectedGeneration) return@launch
            // New endpoint never completed the authenticated welcome. Restore the
            // exact prior transport and rebuild it, so an incorrect host/PSK cannot
            // strand a whole batch beyond remote recovery.
            settings.commitTransport(previousIntent, previousHost, previousPort, previousWss)
            logEvent("transport_configure_rollback failed_revision=$appliedRevision " +
                "restored=${if (previousHost.isBlank()) "p2p" else "$previousHost:$previousPort"}")
            try {
                rebuildTransport()
            } catch (t: Throwable) {
                ConnState.set(ConnState.Phase.START_FAILED,
                    t.message ?: "transport rollback failed")
            }
        }
    }

    private fun hRotateDeviceKey(payload: Json.Obj, env: Envelope.Parsed) {
        if (payload["device_id"].asString() != settings.deviceId) return
        val requestId = payload["request_id"].asString()
        val psk = payload["psk"].asString()
        if (!env.authed || psk.isNullOrBlank()) {
            sendConfigResult(requestId, false, rejected = jsonArr(listOf(jsonObj {
                put("field", "psk"); put("reason", if (!env.authed) "unsigned_frame" else "invalid_value")
            })))
            return
        }
        settings.psk = psk.trim(); settings.keyMode = KeyMode.GLOBAL.wire
        settings.deviceKeyHex = ""; settings.brokerKeyHex = ""
        settings.bumpConfigRevision()
        scope.launch { try { rebuildTransport() } catch (_: Throwable) {} }
        sendConfigResult(requestId, true, jsonObj { put("psk_configured", true) },
            pending = jsonObj { put("transport", "reconnecting") })
    }

    /**
     * Tear down the live coordinator link + discovery, then re-run
     * [selectAndStartTransport] against the just-persisted Settings. Used by
     * §19 remote broker configure so the box switches host without a process
     * restart. status/thumbnail loops keep running; only the link is replaced.
     */
    private val transportMutex = Mutex()
    @Volatile private var transportGeneration = 0L

    private suspend fun rebuildTransport() = transportMutex.withLock {
        val generation = ++transportGeneration
        try { discovery?.stop() } catch (_: Exception) {}
        discovery = null
        try { link?.stop() } catch (_: Exception) {}
        link = null
        controllerPresent = false
        ConnState.set(ConnState.Phase.CONNECTING_BROKER,
            if (settings.hasBroker) "${settings.brokerHost}:${settings.brokerPort}" else "auto")
        selectAndStartTransport(generation)
    }

    // --- §22 update_app (remote self-update, root install) -----------
    /**
     * §22: remotely update this box's own APK. FOUR guardrails (see UpdateGuard
     * + RootInstaller): (1) the frame MUST be authenticated (env.authed) — an
     * `open`/unsigned box refuses; (2) target versionCode MUST be strictly
     * newer (no downgrade/replay); (3) url + 64-hex sha256 required and the
     * downloaded bytes are re-verified before install; (4) the Android platform
     * enforces same-signer at PackageManager install time. Only after all pass do
     * we root-install via the daemon (`pm install -r` + app restart — NO
     * whole-device reboot; §restart-semantics). Runs off-thread; reports back.
     */
    private fun hUpdateApp(payload: Json.Obj, env: Envelope.Parsed) {
        if (!targetsMe(payload)) {
            // Previously a fully silent drop — now truthfully recorded so a
            // mis-addressed push doesn't look like "the update never arrived".
            logEvent("update_app ignored reason=not-addressed-to-me " +
                "dev=${payload["device_id"].asString()} grp=${payload["group_id"].asString()}")
            return
        }
        val targetCode = payload["version_code"].asIntOrNull()
        val url = payload["url"].asString()
        val sha = payload["sha256"].asString()
        val p2pLocal = link is com.jieoz.lanmediawall.player.net.P2pServer
        logEvent("update_app recv authed=${env.authed} p2pLocal=$p2pLocal " +
            "target=$targetCode current=${BuildConfig.VERSION_CODE} " +
            "url=${url ?: "null"} sha_len=${sha?.length ?: 0}")
        logEvent("UPDATE_STAGE=recv authed=${env.authed} p2pLocal=$p2pLocal " +
            "target=$targetCode current=${BuildConfig.VERSION_CODE}")
        val decision = com.jieoz.lanmediawall.player.update.UpdateGuard.decide(
            authed = env.authed,
            p2pLocal = p2pLocal,
            currentVersionCode = BuildConfig.VERSION_CODE,
            targetVersionCode = targetCode,
            url = url,
            sha256 = sha,
        )
        if (decision is com.jieoz.lanmediawall.player.update.UpdateGuard.Decision.Reject) {
            logEvent("update_app rejected reason=${decision.reason}")
            logEvent("UPDATE_STAGE=guard reject reason=${decision.reason}")
            reportUpdate("rejected", "UPDATE_STAGE=guard reason=${decision.reason}")
            pushError("update:${decision.reason}")
            return
        }
        // Proceed on a background thread — download can be large; must not block
        // the link. url/sha are non-null here (guard passed).
        logEvent("update_app proceed → download+verify+install")
        logEvent("UPDATE_STAGE=download start")
        reportUpdate("downloading", "UPDATE_STAGE=download start")
        scope.launch(Dispatchers.IO) {
            val updater = com.jieoz.lanmediawall.player.update.AppUpdater(
                cacheDir,
                daemonAssetProvider = {
                    assets.open(com.jieoz.lanmediawall.player.update.AppUpdater.DAEMON_ASSET_ENTRY)
                },
            )
            when (val r = updater.downloadVerifyInstall(
                packageName, url!!, sha!!, log = { logEvent(it) },
            )) {
                is com.jieoz.lanmediawall.player.update.AppUpdater.Result.Installing -> {
                    logEvent("update_app installing (daemon activated pm install -r)")
                    logEvent("UPDATE_STAGE=restart_app app-restart")
                    reportUpdate("installing", "UPDATE_STAGE=restart_app app-restart")
                }
                is com.jieoz.lanmediawall.player.update.AppUpdater.Result.ActivationDispatched -> {
                    logEvent("update_app legacy_activation_dispatched reboot_required=${r.rebootRequired}")
                    logEvent("UPDATE_STAGE=legacy_stage reboot_required=${r.rebootRequired} detail=${r.detail}")
                    reportUpdate("legacy_activation_dispatched",
                        "UPDATE_STAGE=legacy_stage ${r.detail}", r.rebootRequired)
                }
                is com.jieoz.lanmediawall.player.update.AppUpdater.Result.Failed -> {
                    val st = com.jieoz.lanmediawall.player.update.AppUpdater.stageForReason(r.reason)
                    logEvent("update_app failed reason=${r.reason}")
                    logEvent("UPDATE_STAGE=$st reason=${r.reason}")
                    reportUpdate("failed", "UPDATE_STAGE=$st reason=${r.reason}")
                    pushError("update:${r.reason}")
                }
            }
        }
    }

    /** Report §22 update progress/outcome back to the coordinator (best-effort). */
    private fun reportUpdate(state: String, detail: String, rebootRequired: Boolean = false) {
        link?.send("update_status", jsonObj {
            put("device_id", settings.deviceId)
            put("state", state)      // downloading | installing | legacy_activation_dispatched | rejected | failed
            put("detail", detail)
            put("reboot_required", rebootRequired)
            put("version_code", BuildConfig.VERSION_CODE)
        })
    }

    // --- §6.4 thumbnail loop -----------------------------------------
    private suspend fun thumbnailLoop() {
        while (scope.isActive) {
            val item = currentItem()
            val expectedItemId = item?.itemId
            delay(ThumbnailPolicy.intervalMs(
                androidSdk = Build.VERSION.SDK_INT,
                playingVideo = playState == "playing" && item?.type == "video",
            ))
            if (!ThumbnailPolicy.canCapture(expectedItemId, currentItem()?.itemId)) continue
            // The loop is now a FALLBACK/refresh path: the primary capture is
            // one-shot on load (captureThumbnailOnLoad). It re-sends the cached
            // thumb (so a controller that connects mid-item still gets a preview)
            // and, if the on-load capture was skipped because the file wasn't
            // ready yet, gets one more chance to extract once.
            captureAndSendThumbnail(item)
        }
    }

    /**
     * §6.4 bounded-per-item thumbnail. Decides via [ThumbnailPolicy.decide]:
     * re-send a cached thumb, retry extraction a small bounded number of times, or
     * suppress. Safe to call on load AND from the refresh loop.
     */
    private suspend fun captureAndSendThumbnail(item: MediaItem?) {
        val coordinator = link ?: return
        if (!coordinator.isConnected) return
        if (!(settings.alwaysCollectThumbnails || controllerPresent)) return
        val ctl = controllerRef ?: return
        if (item == null || (item.type != "video" && item.type != "image")) return
        val itemId = item.itemId
        val action = ThumbnailPolicy.decide(
            isVideo = item.type == "video",
            isImage = item.type == "image",
            hasCachedThumbnail = ctl.cachedThumbnail(itemId) != null,
            attemptCount = thumbAttempts[itemId] ?: 0,
        )
        val res = when (action) {
            ThumbnailPolicy.ThumbAction.REUSE_CACHED -> ctl.cachedThumbnail(itemId)
            ThumbnailPolicy.ThumbAction.EXTRACT -> {
                // Don't burn an extraction attempt until the bytes are on disk.
                val localMedia = downloader.readyPath(itemId) ?: return
                synchronized(thumbAttempts) {
                    thumbAttempts[itemId] = (thumbAttempts[itemId] ?: 0) + 1
                }
                logEvent("thumb_extract item=$itemId type=${item.type} " +
                    "attempt=${thumbAttempts[itemId]}")
                ctl.captureThumbnail(
                    itemId = itemId,
                    mediaType = item.type,
                    sourcePath = localMedia.absolutePath,
                    positionMs = ctl.snapshot().positionMs,
                    maxWidth = 320,
                    quality = 70,
                )
            }
            ThumbnailPolicy.ThumbAction.SUPPRESS -> null
        } ?: return
        val (seq, jpeg) = res
        coordinator.send("thumb_meta", jsonObj {
            put("device_id", settings.deviceId)
            put("item_id", itemId)
            put("runtime_mode", runtimeModeState.current.wire)
            put("mode_generation", modeGeneration.get())
            put("session_id", thumbSession)
            put("seq", seq)
            put("bytes", jpeg.size)
            put("mime", "image/jpeg")
        })
        coordinator.sendBinary(jpeg)
    }

    // --- watchdog (§11) ----------------------------------------------
    private suspend fun watchdogLoop() {
        while (scope.isActive) {
            delay(5000)
            // re-assert kiosk immersive state on the activity (§11)
            MainActivity.instance?.reassertKiosk()
            // recover from a player error: resume last task within ~5s (§11).
            // Two triggers now: (a) playState=="error" — the B1 onPlayerError hook
            // flipped it the instant ExoPlayer failed (fast path); (b) a snapshot
            // error while we still think we're playing — the pre-B1 fallback for
            // any error that slipped past the callback. Either one recovers.
            val err = controllerRef?.snapshot()?.error
            val allMusicFailed = runtimeModeState.current == PlaybackMode.MUSIC &&
                musicPlaylist?.items?.isNotEmpty() == true &&
                musicFailures.containsAll(musicPlaylist?.items?.map { it.itemId } ?: emptyList())
            if (runtimeModeState.current != PlaybackMode.STANDBY && !allMusicFailed &&
                (playState == "error" || (err != null && playState == "playing"))) {
                logEvent("watchdog_recover playState=$playState snapErr=${err ?: "none"}")
                pushError("player:${err ?: "state-error"}")
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
        return if (pid != null) mediaStore.loadPlaylist(pid) else null
    }

    private fun currentItem(): MediaItem? {
        return when (runtimeModeState.current) {
            PlaybackMode.STANDBY -> null
            PlaybackMode.MUSIC -> musicPlaylist?.items?.firstOrNull { it.itemId == musicCurrentItemId }
            PlaybackMode.VISUAL -> playlist?.items?.getOrNull(index)
        }
    }

    fun currentItemForDebug(): MediaItem? = currentItem()
    fun debugPlayState(): String = playState
    fun debugIndex(): Int = index
    fun debugControllerPresent(): Boolean = controllerPresent
    fun debugAudioMaster(): Boolean = audioMaster
    /** §backend-ab: the active video kernel + selection source (e.g.
     *  `mediaplayer(override)`), for the settings screen + diagnostic exports. */
    fun debugBackend(): String = MainActivity.backendDecisionLabel ?: "none"
    /** §backend-ab: the active kernel's A/B metrics line, or a placeholder when
     *  no controller is foregrounded. */
    fun debugBackendMetrics(): String = controllerRef?.metrics?.summary() ?: "no-controller"
    /** §hardware-decode: selected video decoder + hw/sw classification for export. */
    fun debugVideoDecoder(): String {
        val name = controllerRef?.lastVideoDecoderName ?: return "none-initialized"
        val cls = com.jieoz.lanmediawall.player.media.VideoCodecPolicy.classify(name, null)
        return "$name ($cls)"
    }
    fun debugErrorsSummary(): String = errors.toList().takeLast(5).joinToString(" | ").ifBlank { "none" }
    fun debugCacheSummary(): String = downloader.cacheStatus().entries
        .joinToString(", ") { (k, v) -> "$k=$v" }
        .ifBlank { "empty" }
    fun debugHealthProbeSummary(): String {
        val uidFile = java.io.File("/data/local/tmp/lmw_root_daemon.uid")
        val uidState = if (uidFile.exists()) "uid_file:${uidFile.length()}B" else "uid_file:missing"
        val probe = com.jieoz.lanmediawall.player.update.RootInstaller.probe()
        val bridge = if (probe.ready) "ready" else "blocked:${probe.detail}"
        return "daemon=@lmw_root_daemon($uidState); root_bridge=$bridge; restart=$bridge; update=$bridge; version=${BuildConfig.VERSION_CODE}"
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
        if (ctl == null) {
            // BootReceiver starts PlayerService and MainActivity almost together.
            // On 4.4/YunOS the service can win that race: if we return after
            // reading last_task but before MainActivity creates PlayerController,
            // resume is lost until a manual command arrives. Leave the task
            // intact and let MainActivity call onPlayerUiReady() once its surface
            // is attached.
            return
        }
        when (runtimeModeState.current) {
            PlaybackMode.STANDBY -> {
                playState = "idle"
                MainActivity.instance?.showIdle()
                return
            }
            PlaybackMode.MUSIC -> {
                updateCacheProtection(playlist)
                MainActivity.instance?.showIdle()
                playNextMusic(modeGeneration.get())
                return
            }
            PlaybackMode.VISUAL -> Unit
        }
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
        synchronized(cacheGenerationLock) {
            playlist = pl
            index = task.index
            updateCacheProtection(pl)
        }
        dwellTimer.getAndSet(null)?.cancel()
        val item = pl.items[task.index]
        val readyFile = downloader.readyPath(item.itemId)
        readyFile?.let { downloader.touch(it) } // §6 LRU: mark just-used
        val source = readyFile?.absolutePath ?: item.url
        settings.volume = task.volume
        settings.muted = task.muted
        ctl.currentVolumePercent = task.volume
        if (item.type == "image") {
            ctl.showImage(source, itemId = item.itemId)
            armDwell(item)
        } else {
            ctl.onVideoEnded = { onCurrentEnded() }
            ctl.loadAndPlay(source, task.seekMs, singleLoop(pl))
        }
        ctl.setVolume(task.volume)
        ctl.setMuted(task.muted)
        playState = "playing"
        MainActivity.instance?.hideIdle()
    }

    /** Called by MainActivity after PlayerController + surfaces are ready. */
    fun onPlayerUiReady() {
        wireController()
        restoreTask.getAndSet(null)?.cancel()
        val job = scope.launch { resumeLast() }
        restoreTask.set(job)
    }

    /**
     * B1 根因修复 + 诊断接线(幂等):把 PlayerController 的诊断事件接进导出的
     * player.log,并**主动订阅** onPlayerError —— 过去从没订阅,ExoPlayer 报解码
     * 错误(如 OMX_ErrorStreamCorrupt)时 playState 仍停在 "playing",控制端看到
     * 的是「假成功」,黑屏无从感知。这里错误一发生就:①即时写 player.log(不再等
     * watchdog 5s 后才记一条泛化 player:X);②推进 errors deque;③把 playState 翻成
     * "error",让 §5 status 如实上报。watchdogLoop 的 5s 恢复逻辑保持不变作为兜底。
     */
    @Volatile private var wiredController: PlayerController? = null
    private fun wireController() {
        val ctl = controllerRef ?: return
        // Track by instance identity: MainActivity builds a NEW PlayerController on
        // every onCreate (activity recreation), so a plain boolean would leave the
        // fresh controller un-wired. Re-wire whenever the instance changes.
        if (wiredController === ctl) return
        wiredController = ctl
        ctl.logSink = { msg -> logEvent("video_backend=${ctl.backend.id} $msg") }
        ctl.onPlayerError = { code ->
            val failedMusicId = musicCurrentItemId
            logEvent("player_error code=$code prevState=$playState item=${currentItem()?.itemId ?: "none"}")
            pushError("player:$code")
            playState = "error"
            if (runtimeModeState.current == PlaybackMode.MUSIC && failedMusicId != null) {
                musicFailures = musicFailures + failedMusicId
                val generation = modeGeneration.get()
                scope.launch {
                    delay(250)
                    playNextMusic(generation)
                }
            }
        }
        logEvent("controller_wired")
    }

    companion object {
        const val ACTION_START = "com.jieoz.lanmediawall.player.START"
        private const val CHANNEL_ID = "lmw_player"
        private const val NOTIF_ID = 1001

        private val VALID_STATES = setOf("playing", "paused", "idle", "buffering", "downloading")
        /** §6.3: default per-image dwell when a playlist item omits duration_ms. */
        private const val DEFAULT_IMAGE_DWELL_MS = 5000L
        /** Boundary-only policy: tolerate normal decoder/status jitter, correct at lap seams. */
        private const val LOOP_BOUNDARY_TOLERANCE_MS = 80L
        /** Give OEM MediaPlayer a moment to publish its wrapped currentPosition. */
        private const val LOOP_BOUNDARY_SAMPLE_SETTLE_MS = 40L
        /** Failed bulk Broker migration returns to the exact previous transport. */
        private const val TRANSPORT_ROLLBACK_TIMEOUT_MS = 30_000L
        /** §6 孤儿回收:保留最近 N 条 playlist 的媒体(+ last_task),其余视为孤儿。 */
        private const val KEEP_RECENT_PLAYLISTS = 3
        private val ACKABLE = setOf(
            "prepare", "pause", "resume", "stop", "next", "prev", "restart", "reboot",
            "set_volume", "set_mute", "set_audio_master", "assign_group",
            "configure_device", "transport_configure", "rotate_device_key",
            "cache_prefetch", "playlist", "update_app",
            "debug_snapshot", "download_logs",
        )

        @Volatile
        var instance: PlayerService? = null
            private set
    }
}
