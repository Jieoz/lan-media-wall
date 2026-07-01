package com.jieoz.lanmediawall.player

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.jieoz.lanmediawall.player.net.AuthMode
import com.jieoz.lanmediawall.player.net.KeyMode
import java.util.UUID

/**
 * Persistent device identity + connection settings (protocol_spec §4, §10).
 *
 * Two backing stores:
 *  - regular SharedPreferences for non-secret identity/config (device_id,
 *    device_name, group_id, broker host/port, intervals, flags);
 *  - EncryptedSharedPreferences (AES-256) for the PSK only — the §3 preshared
 *    key must not sit in plaintext on a kiosk device that could be picked up.
 *
 * device_id is generated once ("and-" + 10 hex) and persisted forever (§4.1).
 * device_name is settable on first boot (SettingsActivity) and persisted.
 */
class Settings(context: Context) {

    private val appContext = context.applicationContext
    private val prefs: SharedPreferences =
        appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private val securePrefs: SharedPreferences by lazy {
        try {
            val masterKey = MasterKey.Builder(appContext)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                appContext,
                SECURE_PREFS,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        } catch (e: Exception) {
            // Keystore unavailable (rare; e.g. corrupted) — degrade to plain
            // prefs so the player still runs. Logged by caller.
            appContext.getSharedPreferences(SECURE_FALLBACK, Context.MODE_PRIVATE)
        }
    }

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

    var brokerHost: String
        get() = prefs.getString(KEY_BROKER_HOST, "192.168.1.10") ?: "192.168.1.10"
        set(value) { prefs.edit().putString(KEY_BROKER_HOST, value).apply() }

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
     * paired in derived mode. Secret → EncryptedSharedPreferences.
     */
    var deviceKeyHex: String
        get() = securePrefs.getString(KEY_DEVICE_KEY, "") ?: ""
        set(value) { securePrefs.edit().putString(KEY_DEVICE_KEY, value).apply() }

    /**
     * §17.4 derived mode (forward-compat): the broker's `device_key` (hex),
     * received via the pairing QR's optional `bk`. Lets a dk-only end verify
     * broker downlink without the PSK. Empty when absent (today's QR omits it —
     * see NOTES_TO_UPSTREAM §4). Secret → EncryptedSharedPreferences.
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

    var alwaysCollectThumbnails: Boolean
        get() = prefs.getBoolean(KEY_ALWAYS_THUMBS, false)
        set(value) { prefs.edit().putBoolean(KEY_ALWAYS_THUMBS, value).apply() }

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

    /**
     * PIN that unlocks the hidden kiosk-exit backdoor (on-device debugging, see
     * [ExitGestureDetector] + MainActivity). Plain prefs by design: this only
     * gates *local* egress from the kiosk (stopLockTask + jump to Settings) — it
     * carries no network-auth weight, so encrypting it would add cost for no
     * threat-model benefit. Default [DEFAULT_KIOSK_EXIT_PIN]; change it here or
     * via prefs before shipping a wall. See README §kiosk-exit.
     */
    var kioskExitPin: String
        get() = prefs.getString(KEY_KIOSK_EXIT_PIN, DEFAULT_KIOSK_EXIT_PIN)
            ?: DEFAULT_KIOSK_EXIT_PIN
        set(value) { prefs.edit().putString(KEY_KIOSK_EXIT_PIN, value).apply() }

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

    companion object {
        private const val PREFS = "lmw_settings"
        private const val SECURE_PREFS = "lmw_secure"
        private const val SECURE_FALLBACK = "lmw_secure_fallback"

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
        private const val KEY_ALWAYS_THUMBS = "always_thumbs"
        private const val KEY_CACHE_MAX_BYTES = "cache_max_bytes"
        private const val KEY_KIOSK_EXIT_PIN = "kiosk_exit_pin"

        const val DEFAULT_PSK = "CHANGE_ME_32_BYTE_RANDOM_PRESHARED_KEY"

        /**
         * App version reported in §4 `hello.app_version`. Sourced from
         * `BuildConfig.VERSION_NAME` (gradle `versionName`) so it never drifts
         * from the shipped build — no hand-edited constant to forget (was
         * hard-coded "1.0.0"). BuildConfig is generated (buildConfig=true).
         */
        val APP_VERSION: String = com.jieoz.lanmediawall.player.BuildConfig.VERSION_NAME

        /** Default PIN for the kiosk-exit backdoor (see [kioskExitPin]). */
        const val DEFAULT_KIOSK_EXIT_PIN = "246813"
    }
}
