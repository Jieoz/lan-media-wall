package com.jieoz.lanmediawall.player

import android.content.Context
import android.content.SharedPreferences
import com.jieoz.lanmediawall.player.net.AuthMode
import com.jieoz.lanmediawall.player.net.KeyMode
import java.util.UUID

/**
 * Persistent device identity + connection settings (protocol_spec §4, §10).
 *
 * §6/§7 (minSdk 19): the old EncryptedSharedPreferences (androidx.security-crypto,
 * needs API 23+) is **removed** — it can't run on Android 4.4. Per §7 this is a
 * LAN-only kiosk, so the PSK/device_key are stored in **plain** SharedPreferences.
 * This is a deliberate security downgrade, valid only inside a trusted LAN; the
 * README + first-boot page warn against public-internet use.
 *
 * device_id is generated once ("and-" + 10 hex) and persisted forever (§4.1).
 * device_name is settable on first boot (SettingsActivity) and persisted.
 */
class Settings(context: Context) {

    private val appContext = context.applicationContext
    private val prefs: SharedPreferences =
        appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // §7: single plain store for both config and (LAN-only) secrets. Kept as a
    // named alias so the secret accessors below read as "this is the secret bag".
    private val securePrefs: SharedPreferences get() = prefs

    val deviceId: String
        get() {
            val existing = prefs.getString(KEY_DEVICE_ID, null)
            if (existing != null) return existing
            val generated = "and-" + UUID.randomUUID().toString().replace("-", "").substring(0, 10)
            prefs.edit().putString(KEY_DEVICE_ID, generated).apply()
            return generated
        }

    var deviceName: String
        get() = prefs.getString(KEY_DEVICE_NAME, null) ?: deviceId
        set(value) { prefs.edit().putString(KEY_DEVICE_NAME, value).apply() }

    /** True until the user has completed first-boot setup. */
    val isConfigured: Boolean
        get() = prefs.getBoolean(KEY_CONFIGURED, false)

    fun markConfigured() { prefs.edit().putBoolean(KEY_CONFIGURED, true).apply() }

    var groupId: String
        get() = prefs.getString(KEY_GROUP_ID, "default") ?: "default"
        set(value) { prefs.edit().putString(KEY_GROUP_ID, value).apply() }

    /**
     * Broker address (§2 zero-config). Default is **empty** — a fresh box has no
     * broker and must be free to auto-discover one or fall back to the p2p server
     * (§14.3). The old `"192.168.1.10"` default was a trap: an operator who saved
     * first-boot setup with the (optional) broker field blank kept that phantom
     * host, `markConfigured()` flipped isConfigured=true, and the box then
     * dead-dialed a broker nobody runs — never entering p2p, so the controller's
     * scanned enroll QR (which points at THIS box as a p2p server) got "连接断开".
     * `192.168.1.10` now lives only as the input-field hint. See [hasBroker].
     */
    var brokerHost: String
        get() = prefs.getString(KEY_BROKER_HOST, "") ?: ""
        set(value) { prefs.edit().putString(KEY_BROKER_HOST, value).apply() }

    /**
     * True when a real broker endpoint has been set (non-blank host). Transport
     * selection keys off THIS, not [isConfigured]: a box configured for the
     * zero-config path (blank broker) must still probe/P2P-fallback rather than
     * dial a phantom broker. See [com.jieoz.lanmediawall.player.PlayerService].
     */
    val hasBroker: Boolean get() = brokerHost.isNotBlank()

    var brokerPort: Int
        get() = prefs.getInt(KEY_BROKER_PORT, 8770)
        set(value) { prefs.edit().putInt(KEY_BROKER_PORT, value).apply() }

    var useWss: Boolean
        get() = prefs.getBoolean(KEY_USE_WSS, false)
        set(value) { prefs.edit().putBoolean(KEY_USE_WSS, value).apply() }

    var psk: String
        get() = securePrefs.getString(KEY_PSK, DEFAULT_PSK) ?: DEFAULT_PSK
        set(value) { securePrefs.edit().putString(KEY_PSK, value).apply() }

    /**
     * §17.3 key_mode for HMAC key selection. Stored as the wire string;
     * missing → `global` (= v1.2 behaviour, backward compat). Populated from a
     * §15 pairing URI / coordinator `welcome` — never a per-device UI field
     * (zero-config hard constraint, §17.4).
     */
    var keyMode: String
        get() = prefs.getString(KEY_KEY_MODE, KeyMode.GLOBAL.wire) ?: KeyMode.GLOBAL.wire
        set(value) { prefs.edit().putString(KEY_KEY_MODE, value).apply() }

    /**
     * §17.4 derived mode: this end's own `device_key` (hex), received via the
     * pairing QR's `dk`. The end stores only this — never the PSK. Empty when not
     * paired in derived mode. §7: plain storage (LAN-only downgrade).
     */
    var deviceKeyHex: String
        get() = securePrefs.getString(KEY_DEVICE_KEY, "") ?: ""
        set(value) { securePrefs.edit().putString(KEY_DEVICE_KEY, value).apply() }

    /**
     * §17.4 derived mode (forward-compat): the broker's `device_key` (hex),
     * received via the pairing QR's optional `bk`. Lets a dk-only end verify
     * broker downlink without the PSK. Empty when absent (today's QR omits it —
     * see NOTES_TO_UPSTREAM §4). §7: plain storage (LAN-only downgrade).
     */
    var brokerKeyHex: String
        get() = securePrefs.getString(KEY_BROKER_KEY, "") ?: ""
        set(value) { securePrefs.edit().putString(KEY_BROKER_KEY, value).apply() }

    /** Volume/mute survive reboot so resume_last restores the audio profile. */
    var volume: Int
        get() = prefs.getInt(KEY_VOLUME, 80)
        set(value) { prefs.edit().putInt(KEY_VOLUME, value.coerceIn(0, 100)).apply() }

    var muted: Boolean
        get() = prefs.getBoolean(KEY_MUTED, false)
        set(value) { prefs.edit().putBoolean(KEY_MUTED, value).apply() }

    /** Durable top-level playback mode; standby must survive process/device restart. */
    var runtimeMode: String
        get() = prefs.getString(KEY_RUNTIME_MODE, "visual") ?: "visual"
        set(value) { prefs.edit().putString(KEY_RUNTIME_MODE, value).apply() }

    var previousActiveMode: String
        get() = prefs.getString(KEY_PREVIOUS_ACTIVE_MODE, "visual") ?: "visual"
        set(value) { prefs.edit().putString(KEY_PREVIOUS_ACTIVE_MODE, value).apply() }

    var standbySinceMs: Long
        get() = prefs.getLong(KEY_STANDBY_SINCE_MS, 0L)
        set(value) { prefs.edit().putLong(KEY_STANDBY_SINCE_MS, value.coerceAtLeast(0L)).apply() }

    /** Monotonic §19 remote-config revision for optimistic patch conflicts. */
    var configRevision: Int
        get() = prefs.getInt(KEY_CONFIG_REVISION, 0)
        set(value) { prefs.edit().putInt(KEY_CONFIG_REVISION, value.coerceAtLeast(0)).apply() }

    fun bumpConfigRevision(): Int {
        configRevision += 1
        return configRevision
    }

    var alwaysCollectThumbnails: Boolean
        get() = prefs.getBoolean(KEY_ALWAYS_THUMBS, false)
        set(value) { prefs.edit().putBoolean(KEY_ALWAYS_THUMBS, value).apply() }

    /**
     * §backend-ab: which video kernel drives playback — `auto` (default →
     * ExoPlayer, the legacy-stable path), `exoplayer`, or `mediaplayer` (native
     * android.media.MediaPlayer, for the QZX_C1 / HiSilicon boxes). A concrete id
     * is the operator's explicit A/B choice; `auto`/blank defers to
     * [com.jieoz.lanmediawall.player.media.BackendSelector]. A `/data/local/tmp`
     * override file (test affordance) still beats this. Stored as the wire id.
     */
    var videoBackend: String
        get() = prefs.getString(KEY_VIDEO_BACKEND, VIDEO_BACKEND_AUTO) ?: VIDEO_BACKEND_AUTO
        set(value) { prefs.edit().putString(KEY_VIDEO_BACKEND, value).apply() }

    /**
     * §6 cache quota (bytes). Hard cap on the media cache so a small 4–8GB box
     * never hits `Storage Full` when媒体 churn. The effective quota is the
     * smaller of this and a % of free disk (see [com.jieoz.lanmediawall.player
     * .cache.CacheEviction.effectiveQuota]). Default 2 GiB. Configurable via
     * prefs; no dedicated UI (zero-config default is fine for most walls).
     */
    var cacheMaxBytes: Long
        get() = prefs.getLong(KEY_CACHE_MAX_BYTES,
            com.jieoz.lanmediawall.player.cache.CacheEviction.DEFAULT_MAX_BYTES)
        set(value) { prefs.edit().putLong(KEY_CACHE_MAX_BYTES, value).apply() }

    val brokerWsUrl: String
        get() {
            val scheme = if (useWss) "wss" else "ws"
            val port = if (useWss && brokerPort == 8770) 8771 else brokerPort
            return "$scheme://$brokerHost:$port"
        }

    /**
     * Apply a scanned §15 pairing URI to persistent settings (§15 + §17.4). Fills
     * host/port/group/wss/name and the key material **per key_mode**, with zero
     * per-device UI (the zero-config hard constraint, §17.4):
     *   - `open`:    no key stored.
     *   - `derived`: store the end's own `dk` + `id` + optional broker `bk`;
     *     **clear the PSK** (the end must never hold it).
     *   - `global`:  store the shared `psk` (v1.2); clear any derived material.
     * Returns the resolved [KeyMode] so the caller can log/route. `name` only
     * pre-fills device_name when not already configured (don't clobber a custom
     * name on re-pair).
     */
    fun applyPairing(p: com.jieoz.lanmediawall.player.pair.PairUri) {
        brokerHost = p.host
        brokerPort = p.port
        useWss = p.wss
        p.group?.let { groupId = it }
        if (!isConfigured) p.name?.let { deviceName = it }
        keyMode = p.keyMode.wire
        when {
            p.mode == AuthMode.OPEN -> {
                // open never carries/uses a key.
            }
            p.keyMode == KeyMode.DERIVED && p.deviceKeyHex != null -> {
                deviceKeyHex = p.deviceKeyHex
                brokerKeyHex = p.brokerKeyHex ?: ""
                psk = DEFAULT_PSK // end must not retain a PSK in derived mode (§17.4)
            }
            else -> {
                // global (or derived fallback that only carried a PSK).
                p.psk?.let { psk = it }
                deviceKeyHex = ""
                brokerKeyHex = ""
            }
        }
    }

    /**
     * §9 "重置连接配置": wipe the broker endpoint + config flags so the box
     * returns to the **unconfigured, zero-config** state (auto-discover → p2p
     * fallback → show its enroll QR again). Lets an operator self-recover from a
     * bad/stale broker without adb. Deliberately keeps device identity
     * (device_id / device_name) and media cache — this only resets *how the box
     * connects*, not *who it is* or *what it cached*. Key material is cleared too
     * so a re-pair starts clean (a fresh QR scan re-establishes it).
     */
    fun resetConnection() {
        prefs.edit()
            .remove(KEY_CONFIGURED)
            .remove(KEY_BROKER_HOST)
            .remove(KEY_BROKER_PORT)
            .remove(KEY_USE_WSS)
            .remove(KEY_GROUP_ID)
            .remove(KEY_PSK)
            .remove(KEY_KEY_MODE)
            .remove(KEY_DEVICE_KEY)
            .remove(KEY_BROKER_KEY)
            .apply()
    }

    companion object {
        private const val PREFS = "lmw_settings"

        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_DEVICE_NAME = "device_name"
        private const val KEY_CONFIGURED = "configured"
        private const val KEY_GROUP_ID = "group_id"
        private const val KEY_BROKER_HOST = "broker_host"
        private const val KEY_BROKER_PORT = "broker_port"
        private const val KEY_USE_WSS = "use_wss"
        private const val KEY_PSK = "psk"
        private const val KEY_KEY_MODE = "key_mode"
        private const val KEY_DEVICE_KEY = "device_key"
        private const val KEY_BROKER_KEY = "broker_key"
        private const val KEY_VOLUME = "volume"
        private const val KEY_MUTED = "muted"
        private const val KEY_RUNTIME_MODE = "runtime_mode"
        private const val KEY_PREVIOUS_ACTIVE_MODE = "previous_active_mode"
        private const val KEY_STANDBY_SINCE_MS = "standby_since_ms"
        private const val KEY_CONFIG_REVISION = "config_revision"
        private const val KEY_ALWAYS_THUMBS = "always_thumbs"
        private const val KEY_CACHE_MAX_BYTES = "cache_max_bytes"
        private const val KEY_VIDEO_BACKEND = "video_backend"

        /** §backend-ab: "auto" → BackendSelector picks the legacy-stable default. */
        const val VIDEO_BACKEND_AUTO = "auto"

        const val DEFAULT_PSK = "CHANGE_ME_32_BYTE_RANDOM_PRESHARED_KEY"

        /**
         * App version reported in §4 `hello.app_version`. Sourced from
         * `BuildConfig.VERSION_NAME` (gradle `versionName`) so it never drifts
         * from the shipped build — no hand-edited constant to forget (was
         * hard-coded "1.0.0"). BuildConfig is generated (buildConfig=true).
         */
        val APP_VERSION: String = com.jieoz.lanmediawall.player.BuildConfig.VERSION_NAME
    }
}
