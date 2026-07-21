package com.jieoz.lanmediawall.player.cache

import com.jieoz.lanmediawall.player.net.Json
import com.jieoz.lanmediawall.player.net.asArrayOrNull
import com.jieoz.lanmediawall.player.net.asBoolOrNull
import com.jieoz.lanmediawall.player.net.asLongOrNull
import com.jieoz.lanmediawall.player.net.asString
import com.jieoz.lanmediawall.player.net.get

/**
 * A media unit (protocol_spec §6.1). Parsed defensively from an inbound JSON
 * object — unknown fields are ignored (§5.1 forward-compat contract).
 */
data class MediaItem(
    val itemId: String,
    val type: String,           // "video" | "image"
    val name: String?,
    val url: String,
    val size: Long?,
    val sha256: String?,
    val durationMs: Long?,      // image: required (dwell); video: optional
    val loop: Boolean,
    val raw: Json,              // original, kept so we can re-store verbatim
) {
    companion object {
        fun fromJson(node: Json): MediaItem? {
            val itemId = node["item_id"].asString() ?: return null
            val url = node["url"].asString() ?: return null
            return MediaItem(
                itemId = itemId,
                type = node["type"].asString() ?: "video",
                name = node["name"].asString(),
                url = url,
                size = node["size"].asLongOrNull(),
                sha256 = node["sha256"].asString(),
                durationMs = node["duration_ms"].asLongOrNull(),
                loop = node["loop"].asBoolOrNull() ?: false,
                raw = node,
            )
        }
    }
}

/**
 * A playlist (protocol_spec §6.3). length 1 = single file; >1 = carousel.
 */
data class Playlist(
    val playlistId: String,
    val groupId: String?,
    val sync: Boolean,
    /** §6.3 canonical loop mode (folds loop_mode + legacy loop). */
    val loopMode: LoopMode,
    val items: List<MediaItem>,
    val raw: Json,
) {
    val pushId: String? get() = raw["push_id"].asString()
    /** Legacy accessor retained for callers still thinking in booleans. */
    val loop: Boolean get() = loopMode.legacyLoopBool
    /**
     * Return a copy whose [items] are [newItems], with [raw] rebuilt so the
     * merged sequence persists verbatim (§6.3 append). Reuses each item's own
     * `raw` node for the `items` array and copies every other top-level field
     * from the original message, so storing + reloading round-trips the merged
     * order (not just the last pushed frame).
     */
    fun withItems(newItems: List<MediaItem>): Playlist {
        val base = (raw as? Json.Obj)?.entries ?: emptyMap()
        val rebuilt = LinkedHashMap<String, Json>(base)
        rebuilt["items"] = Json.Arr(newItems.map { it.raw })
        return copy(items = newItems, raw = Json.Obj(rebuilt))
    }

    companion object {
        fun fromJson(node: Json): Playlist? {
            val pid = node["playlist_id"].asString() ?: return null
            val items = (node["items"].asArrayOrNull() ?: emptyList())
                .mapNotNull { MediaItem.fromJson(it) }
            return Playlist(
                playlistId = pid,
                groupId = node["group_id"].asString(),
                sync = node["sync"].asBoolOrNull() ?: true,
                loopMode = LoopMode.resolve(node), // §6.3 single fold point
                items = items,
                raw = node,
            )
        }
    }
}

/**
 * Device-local music list. It deliberately does not reuse the active visual
 * [Playlist] slot: visual wall timing and music shuffle have different owners.
 * The wire message still reuses [MediaItem] and the proven cache/download path.
 */
data class MusicPlaylist(
    val playlistId: String,
    val revision: Long,
    val items: List<MediaItem>,
    val raw: Json,
) {
    companion object {
        fun fromJson(node: Json): MusicPlaylist? {
            val playlistId = node["playlist_id"].asString()
                ?.takeIf { it.isNotBlank() } ?: return null
            val revision = node["revision"].asLongOrNull()
                ?.takeIf { it >= 0L } ?: return null
            val rawItems = node["items"].asArrayOrNull() ?: return null
            val items = rawItems.mapNotNull { MediaItem.fromJson(it) }
            if (items.size != rawItems.size || items.any { it.type != "audio" }) return null
            return MusicPlaylist(playlistId, revision, items, node)
        }
    }
}
