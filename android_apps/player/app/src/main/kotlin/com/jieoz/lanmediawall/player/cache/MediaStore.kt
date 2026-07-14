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
        // §6: also record recency (most-recent-first, de-duped) so we can prune
        // stale playlist records and compute the "still referenced" media set for
        // orphan reclaim without a full-disk scan.
        val order = recentIds().toMutableList()
        order.remove(playlist.playlistId)
        order.add(0, playlist.playlistId)
        prefs.edit()
            .putString(playlistKey(playlist.playlistId),
                CanonicalJson.encode(playlist.raw))
            .putString(KEY_RECENT_PLAYLISTS, order.joinToString(SEP))
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

    /** Empty REPLACE invalidates this playlist identity as well as active state. */
    fun deletePlaylist(playlistId: String) {
        val order = recentIds().filterNot { it == playlistId }
        prefs.edit()
            .remove(playlistKey(playlistId))
            .putString(KEY_RECENT_PLAYLISTS, order.joinToString(SEP))
            .apply()
    }

    private fun playlistKey(id: String) = "playlist:$id"

    /** Recorded playlist ids, most-recent-first. Empty when none stored yet. */
    private fun recentIds(): List<String> =
        prefs.getString(KEY_RECENT_PLAYLISTS, null)
            ?.split(SEP)?.filter { it.isNotBlank() } ?: emptyList()

    /**
     * §6 主动清理:返回**仍需保留**的 playlist(最近 [keepRecent] 条 + last_task
     * 指向的),供 service 展开成"仍被引用的媒体路径集"喂给孤儿回收。同时把 lmw_media.xml
     * 里堆积的过期 playlist 记录**剪掉**(删 prefs 条目 + 从 recent 列表移除),避免历史
     * pl-default-xxx 无限膨胀。纯 prefs 读写,低频(仅新 playlist/prepare 时触发)。
     */
    fun pruneAndListReferenced(keepRecent: Int): List<Playlist> {
        val lastId = getLastTask()?.playlistId
        val order = recentIds()
        // keep set = most-recent N ∪ last_task's playlist (never drop what
        // resume_last points at — black-screen red line).
        val keep = LinkedHashSet<String>()
        order.take(keepRecent.coerceAtLeast(1)).forEach { keep.add(it) }
        lastId?.let { keep.add(it) }

        val editor = prefs.edit()
        var changed = false
        for (id in order) {
            if (id !in keep) {
                editor.remove(playlistKey(id))
                changed = true
            }
        }
        // rewrite the recency list to only the kept ids (preserve their order).
        val newOrder = order.filter { it in keep }
        if (changed || newOrder.size != order.size) {
            editor.putString(KEY_RECENT_PLAYLISTS, newOrder.joinToString(SEP))
            editor.apply()
        }
        return newOrder.mapNotNull { loadPlaylist(it) }
    }

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
        private const val KEY_RECENT_PLAYLISTS = "recent_playlists"
        private const val SEP = "\n"
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
