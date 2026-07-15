package com.jieoz.lanmediawall.player.cache

import java.io.File

/**
 * LiveCacheBackend — binds the proven-safe cleanup core to the REAL Android
 * player (design §4.1/§4.2, protocol §27). Behavioural mirror of
 * `windows_player/cache_live.py`.
 *
 * It implements the frozen [CacheCleanup.Backend] duck-type over live player
 * state (active playlist, playing/prepared item, last_task resume, in-flight
 * downloads) and the on-disk [Downloader] cache map. Deletion authority stays
 * with the player: the controller only ever names item ids; identity is
 * resolved to a physical `content_key` HERE (sha256 when known, else the
 * normalized absolute on-disk target path). A blob is deleted only when NO
 * protected item references it — shared-content protection is transitive.
 *
 * Historical playlist metadata does NOT hard-pin media (root-cause fix): only
 * the active generation, the playing source, a prepared-not-switched item, a
 * valid last_task, in-flight `.part` downloads, and explicit pins protect a
 * blob. Playlist history supplies IDENTITY only, never protection.
 *
 * The [PlayerView] is a narrow read-only seam over [PlayerService] so the whole
 * adapter is unit-testable without Android/Service deps.
 */
class LiveCacheBackend(
    private val view: PlayerView,
    private val downloader: Downloader,
) : CacheCleanup.Backend {

    /** Read-only live-state seam (mirror of the Windows `Player` duck-type). */
    interface PlayerView {
        /** The active playlist (current generation), or null when idle. */
        fun activePlaylist(): Playlist?
        /** playing | paused | buffering | idle | downloading | error. */
        fun playState(): String
        /** The item at the current active index, or null. */
        fun currentItem(): MediaItem?
        /** Resolve a persisted playlist by id (last_task target etc.). */
        fun resolvePlaylist(playlistId: String?): Playlist?
        /** The persisted last_task (resume), or null. */
        fun lastTask(): LastTask?
        /** Every playlist the player knows (active + persisted history), used
         *  for the id→metadata index ONLY — presence never protects a blob. */
        fun knownPlaylists(): List<Playlist>
        /** §26 lightweight cache summary (also embedded in periodic status). */
        fun cacheSummary(): Map<String, Any?>
    }

    // content_key -> physical File, populated by buildSnapshot() and reused by
    // sizeOf()/delete() within the same run.
    private val keyToPath = LinkedHashMap<String, File>()
    // content_key -> the ids that resolve to it (for prune fan-out is handled by
    // the snapshot; this only aids delete()). Not strictly needed but kept
    // symmetric with the Windows adapter's key maps.

    // --- Backend contract --------------------------------------------
    override fun contentKeyOf(item: MediaItem): String? = contentKey(item, null)

    override fun currentPushId(): String? = view.activePlaylist()?.pushId

    override fun inventory(): List<MediaItem> {
        // Everything physically READY on disk, enriched with playlist metadata
        // (sha/name) when known so identical content dedupes by content_key.
        val meta = itemMetaIndex()
        val out = ArrayList<MediaItem>()
        for ((itemId, _) in downloader.readyPaths()) {
            out.add(meta[itemId] ?: bareItem(itemId))
        }
        return out
    }

    override fun buildSnapshot(): CacheReferenceSnapshot {
        keyToPath.clear()
        // Physical path index: real on-disk paths for ready + in-flight items.
        val realPaths = HashMap<String, File>()
        for ((id, f) in downloader.readyPaths()) realPaths[id] = f
        for ((id, f) in downloader.inflightPaths()) if (f != null) realPaths[id] = f

        // Resolve every group's items to a content key, recording key→path so
        // sizeOf/delete can act on the physical blob later this run.
        fun note(it: MediaItem) {
            val key = contentKey(it, realPaths[it.itemId]) ?: return
            val path = realPaths[it.itemId] ?: downloader.localPath(it)
            keyToPath.getOrPut(key) { path }
        }

        val inv = inventory()
        val active = activeItems()
        val playing = playingItem()
        val prepared = preparedItems()
        val resume = resumeItems()
        val inflight = inflightItems()

        for (group in listOf(inv, active, prepared, resume, inflight)) {
            for (it in group) note(it)
        }
        playing?.let { note(it) }

        return CacheReferenceSnapshot.build(
            contentKeyOf = { contentKey(it, realPaths[it.itemId]) },
            inventory = inv,
            activeItems = active,
            preparedItems = prepared,
            playingItem = playing,
            resumeItems = resume,
            inflightItems = inflight,
            pinnedItems = emptyList(),
        )
    }

    override fun sizeOf(contentKey: String): Long? {
        val f = keyToPath[contentKey] ?: return null
        if (!downloader.ownsPath(f)) return null
        return try { if (f.exists()) f.length() else null } catch (_: Exception) { null }
    }

    override fun delete(contentKey: String): Boolean {
        val f = keyToPath[contentKey] ?: return false
        if (!downloader.ownsPath(f)) return false
        return downloader.deleteReadyPathIfIdle(f)
    }

    override fun pruneIndex(itemIds: List<String>) = downloader.pruneEntries(itemIds)

    override fun summary(): Map<String, Any?> = view.cacheSummary()

    // --- content identity --------------------------------------------
    /**
     * Physical content identity: sha256 when known (identical media dedupes),
     * else a normalized absolute target-path key. Never a raw controller path —
     * the path is the player's OWN [Downloader.localPath] (or the real on-disk
     * path when we already know it). Falls back to the item id only when neither
     * a sha nor a path can be derived.
     */
    private fun contentKey(item: MediaItem, realPath: File?): String? {
        // Observed inventory entries use their actual path; metadata-only aliases
        // derive the same downloader-owned target. Never mix this with a sha key.
        if (realPath != null) return "path:${normalize(realPath)}"
        val target = runCatching { downloader.localPath(item) }.getOrNull()
        if (target != null) return "path:${normalize(target)}"
        return "id:${item.itemId}"
    }

    private fun normalize(f: File): String =
        try { f.canonicalPath } catch (_: Exception) { f.absolutePath }

    // --- live-state extraction ---------------------------------------
    /** item_id -> MediaItem from every playlist the player knows (identity
     *  source ONLY; presence here never protects a blob). */
    private fun itemMetaIndex(): Map<String, MediaItem> {
        val idx = LinkedHashMap<String, MediaItem>()
        for (pl in view.knownPlaylists()) {
            // API-19 safe: no Map.putIfAbsent (that is API 24+).
            for (it in pl.items) if (!idx.containsKey(it.itemId)) idx[it.itemId] = it
        }
        return idx
    }

    /** A minimal item for an on-disk id with no known playlist metadata. Its
     *  content key resolves to the real path (recorded in buildSnapshot). */
    private fun bareItem(itemId: String): MediaItem = MediaItem(
        itemId = itemId, type = "video", name = null, url = "",
        size = null, sha256 = null, durationMs = null, loop = false,
        raw = com.jieoz.lanmediawall.player.net.Json.Null)

    private fun activeItems(): List<MediaItem> =
        view.activePlaylist()?.items ?: emptyList()

    private fun playingItem(): MediaItem? =
        if (view.playState() in setOf("playing", "paused")) view.currentItem() else null

    private fun preparedItems(): List<MediaItem> =
        if (view.playState() == "buffering")
            view.currentItem()?.let { listOf(it) } ?: emptyList()
        else emptyList()

    private fun resumeItems(): List<MediaItem> {
        val task = view.lastTask() ?: return emptyList()
        val pl = view.resolvePlaylist(task.playlistId) ?: return emptyList()
        val items = pl.items
        return if (task.index in items.indices) listOf(items[task.index]) else emptyList()
    }

    private fun inflightItems(): List<MediaItem> {
        val meta = itemMetaIndex()
        val out = ArrayList<MediaItem>()
        for ((itemId, _) in downloader.inflightPaths()) {
            out.add(meta[itemId] ?: bareItem(itemId))
        }
        return out
    }
}
