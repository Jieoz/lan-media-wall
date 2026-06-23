package com.jieoz.lanmediawall.player.cache

import android.content.Context
import com.jieoz.lanmediawall.player.net.CanonicalJson
import com.jieoz.lanmediawall.player.net.Json
import com.jieoz.lanmediawall.player.net.asBoolOrNull
import com.jieoz.lanmediawall.player.net.asIntOrNull
import com.jieoz.lanmediawall.player.net.asLongOrNull
import com.jieoz.lanmediawall.player.net.asString
import com.jieoz.lanmediawall.player.net.get
import com.jieoz.lanmediawall.player.net.jsonObj
import java.io.File

/**
 * Cache directory + playlist/last-task persistence (protocol_spec §6.3, §10).
 *
 * Playlists are stored as their raw wire JSON in SharedPreferences so they
 * survive process death / reboot and feed resume_last. The media cache lives
 * in the app's private cache dir (getCacheDir()/media) — no external storage
 * permission needed, and the OS can reclaim it under pressure.
 */
class MediaStore(context: Context) {

    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("lmw_media", Context.MODE_PRIVATE)

    val mediaCacheDir: File =
        File(appContext.cacheDir, "media").apply { mkdirs() }

    // --- playlists ----------------------------------------------------
    fun storePlaylist(playlist: Playlist) {
        prefs.edit()
            .putString(playlistKey(playlist.playlistId),
                CanonicalJson.encode(playlist.raw))
            .apply()
    }

    fun loadPlaylist(playlistId: String): Playlist? {
        val raw = prefs.getString(playlistKey(playlistId), null) ?: return null
        return try {
            Playlist.fromJson(Json.parse(raw))
        } catch (e: Exception) {
            null
        }
    }

    private fun playlistKey(id: String) = "playlist:$id"

    // --- last task (resume_last, §10/§11) -----------------------------
    fun setLastTask(task: LastTask?) {
        val editor = prefs.edit()
        if (task == null) {
            editor.remove(KEY_LAST_TASK)
        } else {
            editor.putString(KEY_LAST_TASK, task.toJson())
        }
        editor.apply()
    }

    fun getLastTask(): LastTask? {
        val raw = prefs.getString(KEY_LAST_TASK, null) ?: return null
        return try {
            LastTask.fromJson(Json.parse(raw))
        } catch (e: Exception) {
            null
        }
    }

    companion object {
        private const val KEY_LAST_TASK = "last_task"
    }
}

/** Persisted last task for crash/reboot recovery (§10). */
data class LastTask(
    val playlistId: String,
    val index: Int,
    val seekMs: Long,
    val volume: Int,
    val muted: Boolean,
) {
    fun toJson(): String = CanonicalJson.encode(
        jsonObj {
            put("playlist_id", playlistId)
            put("index", index)
            put("seek_ms", seekMs)
            put("volume", volume)
            put("muted", muted)
        }
    )

    companion object {
        fun fromJson(node: Json): LastTask? {
            val pid = node["playlist_id"].asString() ?: return null
            return LastTask(
                playlistId = pid,
                index = node["index"].asIntOrNull() ?: 0,
                seekMs = node["seek_ms"].asLongOrNull() ?: 0L,
                volume = node["volume"].asIntOrNull() ?: 80,
                muted = node["muted"].asBoolOrNull() ?: false,
            )
        }
    }
}
