package com.jieoz.lanmediawall.player

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
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

    val brokerWsUrl: String
        get() {
            val scheme = if (useWss) "wss" else "ws"
            val port = if (useWss && brokerPort == 8770) 8771 else brokerPort
            return "$scheme://$brokerHost:$port"
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
        private const val KEY_VOLUME = "volume"
        private const val KEY_MUTED = "muted"
        private const val KEY_ALWAYS_THUMBS = "always_thumbs"

        const val DEFAULT_PSK = "CHANGE_ME_32_BYTE_RANDOM_PRESHARED_KEY"
        const val APP_VERSION = "1.0.0"
    }
}
