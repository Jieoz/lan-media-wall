package com.jieoz.lanmediawall.player.cache

/**
 * §6.3 playlist composition — the PURE (device-free, unit-tested) rules for
 * turning an inbound `playlist` message into the player's ordered active
 * playlist. This is the separation the field bug (v1.14.7: "cache 2/2 ready but
 * prev/next both play the last pushed item") demanded:
 *
 *   - CACHE INVENTORY (Downloader.entries) = every media file ever downloaded,
 *     keyed by item_id, unordered. It answers "is this file on disk?".
 *   - ORDERED ACTIVE PLAYLIST (this) = the sequence the wall actually plays,
 *     with a stable order + a current index. It answers "what plays next?".
 *
 * The old code conflated them: every `playlist` frame REPLACED the active list
 * with whatever the message carried and reset index=0, so a controller that
 * pushed items one-at-a-time (each a length-1 playlist) collapsed the sequence
 * to the single last item — prev/next then wrapped 1%1==0 back to it, even
 * though the cache had accumulated N ready files.
 *
 * Fix: the `playlist` message now carries an explicit [Mode]. `REPLACE`
 * (default, byte-for-byte the old behavior) swaps the sequence; `APPEND` merges
 * the incoming items onto the end of the current sequence, de-duped by
 * `item_id`, so "push A then append B" yields [A, B]. Identity is `item_id`
 * (an append that repeats an existing id updates that slot in place, never
 * duplicates the row).
 */
object PlaylistOps {

    enum class Mode {
        /** Swap the active sequence for the incoming items (legacy default). */
        REPLACE,

        /** Merge incoming items onto the end, de-duped by item_id. */
        APPEND,
        ;

        companion object {
            /** Wire value → Mode. Unknown/empty ⇒ REPLACE (forward-compat: an old
             *  controller that never sends `mode` keeps today's replace semantics). */
            fun parse(wire: String?): Mode = when (wire?.trim()?.lowercase()) {
                "append" -> APPEND
                else -> REPLACE
            }
        }

        val wire: String get() = name.lowercase()
    }

    /** Result of merging: the new ordered items + the index the caller should
     *  now treat as current. */
    data class Merged(val items: List<MediaItem>, val index: Int)

    /**
     * Compute the new ordered playlist and current index.
     *
     * @param current   the items currently active (empty if none yet)
     * @param currentIndex the index currently playing within [current]
     * @param incoming  the items from the inbound message (already parsed)
     * @param mode      REPLACE or APPEND
     *
     * REPLACE → items = incoming; index resets to 0 (clamped to a valid slot).
     * APPEND  → items = current ++ (incoming not already present by item_id);
     *           an incoming item whose id already exists updates that slot in
     *           place (keeps its position). The current index is preserved to
     *           keep pointing at the SAME item_id it pointed at before (so an
     *           append never yanks the wall off what it is showing); if the
     *           current item vanished it clamps into range.
     */
    fun merge(
        current: List<MediaItem>,
        currentIndex: Int,
        incoming: List<MediaItem>,
        mode: Mode,
    ): Merged {
        if (mode == Mode.REPLACE) {
            // Replace always restarts the sequence at the head (the barrier-play
            // contract): a fresh push means "play this from the top".
            return Merged(incoming, 0)
        }
        // APPEND: preserve order, de-dupe by item_id, update-in-place on repeat.
        val byId = LinkedHashMap<String, MediaItem>()
        for (it in current) byId[it.itemId] = it
        for (it in incoming) byId[it.itemId] = it // update-in-place or append
        val mergedItems = byId.values.toList()
        // Keep pointing at the same item_id we were on, if it survived.
        val currentId = current.getOrNull(currentIndex)?.itemId
        val newIndex = currentId
            ?.let { id -> mergedItems.indexOfFirst { it.itemId == id } }
            ?.takeIf { it >= 0 }
            ?: currentIndex.coerceIn(0, (mergedItems.size - 1).coerceAtLeast(0))
        return Merged(mergedItems, newIndex)
    }
}
