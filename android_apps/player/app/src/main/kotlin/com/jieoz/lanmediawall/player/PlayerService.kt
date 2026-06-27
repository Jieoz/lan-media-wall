package com.jieoz.lanmediawall.player

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
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
import com.jieoz.lanmediawall.player.net.Discovery
import com.jieoz.lanmediawall.player.net.Envelope
import com.jieoz.lanmediawall.player.net.Json
import com.jieoz.lanmediawall.player.net.KeyMode
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
@androidx.media3.common.util.UnstableApi
class PlayerService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private lateinit var settings: Settings
    private lateinit var clock: ClockSync
    private lateinit var mediaStore: MediaStore
    private lateinit var downloader: Downloader
    private lateinit var broker: BrokerClient
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

        broker = BrokerClient(
            url = settings.brokerWsUrl,
            psk = settings.psk,
            deviceId = settings.deviceId,
            clock = clock,
            onConnect = { onBrokerConnected() },
            onMessage = { type, payload, env -> onBrokerMessage(type, payload, env) },
            initialKeyMode = KeyMode.parse(settings.keyMode),
            deviceKey = settings.deviceKeyHex.takeIf { it.isNotBlank() }
                ?.let { Envelope.hexToBytes(it) },
            brokerKey = settings.brokerKeyHex.takeIf { it.isNotBlank() }
                ?.let { Envelope.hexToBytes(it) },
        )
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
        broker.start()
        if (settings.isConfigured) {
            discovery = Discovery(
                psk = settings.psk,
                deviceId = settings.deviceId,
                deviceName = settings.deviceName,
                ip = deviceIp,
                brokerHint = "${settings.brokerHost}:${settings.brokerPort}",
            ).also { it.start() }
        }
        scope.launch { statusLoop() }
        scope.launch { thumbnailLoop() }
        scope.launch { watchdogLoop() }
        // resume_last on (re)start so the screen is the player, not the desktop
        scope.launch { resumeLast() }
    }

    @Volatile private var started = false

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
        try { broker.stop() } catch (_: Exception) {}
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
    private fun onBrokerConnected() {
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
        broker.send("hello", payload)
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
                sendStatus()
            } catch (_: Exception) {
            }
            delay(1500) // §5: every 1–2s
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
            put("cpu", 0)
            put("errors", jsonStrArr(errors.toList().takeLast(5)))
        }
        broker.send("status", payload)
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
            "resume_last" -> scope.launch { resumeLast() }
            "welcome" -> hWelcome(payload)
            "controller_presence" -> hControllerPresence(payload)
            else -> return
        }
        // ack commands that carry a msg_id (§10)
        if (type in ACKABLE) {
            broker.send("ack", jsonObj {
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
        payload["auth_mode"].asString()?.let { broker.setAuthMode(AuthMode.parse(it)) }
        payload["key_mode"].asString()?.let {
            val km = KeyMode.parse(it)
            broker.setKeyMode(km)
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
        if (pl.items.isNotEmpty()) downloader.prefetch(pl.items)
    }

    // --- §9.1 prepare -------------------------------------------------
    private fun hPrepare(payload: Json.Obj) {
        val pid = payload["playlist_id"].asString()
        val groupId = payload["group_id"].asString()
        val prepareId = payload["prepare_id"].asString()
        val startIndex = payload["start_index"].asIntOrNull() ?: 0
        val seekMs = payload["seek_ms"].asLongOrNull() ?: 0L
        val pl = resolvePlaylist(pid)
        var ready = false
        if (pl != null && startIndex in pl.items.indices) {
            val item = pl.items[startIndex]
            playlist = pl
            index = startIndex
            if (downloader.isReady(item.itemId)) {
                val path = downloader.readyPath(item.itemId)?.absolutePath
                if (path != null) {
                    controllerRef?.loadPaused(path, seekMs, pl.loop)
                    playState = "buffering"
                    ready = true
                }
            } else {
                downloader.prefetch(listOf(item)) // kick a fetch; report not-ready
            }
        }
        // §9.1: echo prepare_id + group_id back so broker matches the session.
        broker.send("ready", jsonObj {
            put("device_id", settings.deviceId)
            put("playlist_id", pid)
            put("group_id", groupId)
            put("prepare_id", prepareId)
            put("ready", ready)
        })
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
        val item = pl.items[startIndex]
        val source = downloader.readyPath(item.itemId)?.absolutePath ?: item.url
        scheduledStart.getAndSet(null)?.cancel()
        persistLastTask(pid!!, startIndex, seekMs)
        val job = scope.launch { scheduledStart(source, seekMs, playAt, pl.loop) }
        scheduledStart.set(job)
    }

    private suspend fun scheduledStart(uri: String, seekMs: Long, playAt: Long, loop: Boolean) {
        val ctl = controllerRef ?: return
        // prime paused at seek (idempotent if prepare already did it)
        ctl.loadPaused(uri, seekMs, loop)
        val localTarget = clock.toLocal(playAt) // §8.2 fold master → local
        // coarse sleep, then tight spin the last few ms for ±50–100ms accuracy
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
        ctl.play()
        playState = "playing"
        MainActivity.instance?.hideIdle()
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
        controllerRef?.stop()
        playState = "idle"
        persistLastTaskNull()
        MainActivity.instance?.showIdle()
    }

    private fun hAdvance(payload: Json.Obj, delta: Int) {
        if (!targetsMe(payload)) return
        val pl = playlist ?: return
        if (pl.items.isEmpty()) return
        var newIndex = index + delta
        if (newIndex < 0 || newIndex >= pl.items.size) {
            if (pl.loop) newIndex = ((newIndex % pl.items.size) + pl.items.size) % pl.items.size
            else return
        }
        index = newIndex
        val item = pl.items[newIndex]
        val source = downloader.readyPath(item.itemId)?.absolutePath ?: item.url
        controllerRef?.loadAndPlay(source, 0, pl.loop)
        playState = "playing"
        persistLastTask(pl.playlistId, newIndex, 0)
        MainActivity.instance?.hideIdle()
    }

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

    // --- §6.4 thumbnail loop -----------------------------------------
    private suspend fun thumbnailLoop() {
        while (scope.isActive) {
            delay(5000) // §6.4 ~5s
            if (!broker.isConnected) continue
            if (!(settings.alwaysCollectThumbnails || controllerPresent)) continue
            val ctl = controllerRef ?: continue
            val res = ctl.captureThumbnail(maxWidth = 320, quality = 70) ?: continue
            val (seq, jpeg) = res
            broker.send("thumb_meta", jsonObj {
                put("device_id", settings.deviceId)
                put("seq", seq)
                put("bytes", jpeg.size)
                put("mime", "image/jpeg")
            })
            broker.sendBinary(jpeg)
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
        val item = pl.items[task.index]
        val source = downloader.readyPath(item.itemId)?.absolutePath ?: item.url
        settings.volume = task.volume
        settings.muted = task.muted
        ctl?.currentVolumePercent = task.volume
        ctl?.loadAndPlay(source, task.seekMs, pl.loop)
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
        private val ACKABLE = setOf(
            "prepare", "pause", "resume", "stop", "next", "prev",
            "set_volume", "set_mute", "set_audio_master", "assign_group",
            "cache_prefetch", "playlist",
        )

        @Volatile
        var instance: PlayerService? = null
            private set
    }
}
