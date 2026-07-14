package com.jieoz.lanmediawall.player.cache

/**
 * CacheReferenceSnapshot — player-local protection union (design §4.1).
 *
 * Byte-for-behaviour mirror of the Windows player's `cache_refs.py`. Pure model,
 * no Android/File deps, so the whole protection union is JVM-unit-testable.
 *
 * Deletion is keyed by *content* ([contentKeyOf] → sha256 when known, else the
 * normalized target path), never by a remote-supplied path. A blob is protected
 * while ANY item that references it holds a protecting reason. The union covers
 * active / prepared / playing / resume(last_task) / inflight(.part) / pinned, and
 * shared content is protected transitively.
 *
 * Deliberately EXCLUDED from protection: mere presence in historical playlist
 * metadata (root-cause fix for "recent-N lists hard-pin everything").
 *
 * Direct-reason precedence (most urgent first): PLAYING > ACTIVE > PREPARED >
 * INFLIGHT > LAST_TASK > PINNED.
 */
class CacheReferenceSnapshot private constructor(
    private val itemToKey: Map<String, String>,
    private val keyToItems: Map<String, Set<String>>,
    private val direct: Map<String, String>,
) {
    /** Classification of a deletion candidate. */
    enum class Kind { DIRECT, SHARED, NONE }

    data class Classification(val kind: Kind, val reason: String?)

    fun contentKeyFor(itemId: String): String? = itemToKey[itemId]

    fun itemsForKey(contentKey: String): Set<String> =
        keyToItems[contentKey] ?: emptySet()

    /** Strongest reason this exact item id is protected, or null. */
    fun directReason(itemId: String): String? = direct[itemId]

    /** True iff ANY item referencing this blob holds a direct reason. */
    fun isProtected(contentKey: String?): Boolean {
        if (contentKey == null) return false
        val ids = keyToItems[contentKey] ?: return false
        for (id in ids) if (direct.containsKey(id)) return true
        return false
    }

    /** Strongest direct reason protecting this blob across all ids, or null. */
    fun protectingReason(contentKey: String): String? {
        var best: String? = null
        var bestRank = PRECEDENCE.size
        for (id in keyToItems[contentKey] ?: emptySet()) {
            val r = direct[id] ?: continue
            val rank = PRECEDENCE.indexOf(r)
            if (rank in 0 until bestRank) {
                best = r; bestRank = rank
            }
        }
        return best
    }

    /**
     * Classify a candidate:
     *  - (DIRECT, reason)         — this exact item is itself protected;
     *  - (SHARED, SHARED_CONTENT) — deletable-looking, but its blob is protected
     *                               by ANOTHER id (do not physically delete);
     *  - (NONE, NOT_FOUND)        — unknown item id;
     *  - (NONE, null)             — reclaimable.
     */
    fun classifyItem(itemId: String): Classification {
        val key = itemToKey[itemId]
            ?: return Classification(Kind.NONE, NOT_FOUND)
        direct[itemId]?.let { return Classification(Kind.DIRECT, it) }
        if (isProtected(key)) return Classification(Kind.SHARED, SHARED_CONTENT)
        return Classification(Kind.NONE, null)
    }

    companion object {
        // protection / skip reason constants (wire-facing, design §3.2)
        const val PLAYING = "playing"
        const val ACTIVE = "active"
        const val PREPARED = "prepared"
        const val INFLIGHT = "inflight"
        const val LAST_TASK = "last_task"
        const val PINNED = "pinned"
        const val SHARED_CONTENT = "shared_content"
        const val NOT_FOUND = "not_found"

        // most urgent first
        private val PRECEDENCE = listOf(
            PLAYING, ACTIVE, PREPARED, INFLIGHT, LAST_TASK, PINNED)

        /**
         * Build a snapshot. [contentKeyOf] resolves an item to its physical
         * content key (sha256 else normalized path); items yielding null are
         * ignored. Every list contributes to the id<->blob maps so shared-content
         * protection reaches ids that live only in [inventory].
         */
        fun build(
            contentKeyOf: (MediaItem) -> String?,
            inventory: List<MediaItem>,
            activeItems: List<MediaItem> = emptyList(),
            preparedItems: List<MediaItem> = emptyList(),
            playingItem: MediaItem? = null,
            resumeItems: List<MediaItem> = emptyList(),
            inflightItems: List<MediaItem> = emptyList(),
            pinnedItems: List<MediaItem> = emptyList(),
        ): CacheReferenceSnapshot {
            val itemToKey = LinkedHashMap<String, String>()
            val keyToItems = LinkedHashMap<String, MutableSet<String>>()

            fun register(it: MediaItem) {
                val key = contentKeyOf(it) ?: return
                itemToKey[it.itemId] = key
                keyToItems.getOrPut(key) { LinkedHashSet() }.add(it.itemId)
            }

            for (group in listOf(inventory, activeItems, preparedItems,
                    resumeItems, inflightItems, pinnedItems)) {
                for (it in group) register(it)
            }
            playingItem?.let { register(it) }

            // strongest direct reason per id; apply weakest→strongest.
            val direct = LinkedHashMap<String, String>()
            fun mark(items: List<MediaItem>, reason: String) {
                for (it in items) direct[it.itemId] = reason
            }
            mark(pinnedItems, PINNED)
            mark(resumeItems, LAST_TASK)
            mark(inflightItems, INFLIGHT)
            mark(preparedItems, PREPARED)
            mark(activeItems, ACTIVE)
            playingItem?.let { direct[it.itemId] = PLAYING }

            val frozenKeyToItems = LinkedHashMap<String, Set<String>>()
            for ((k, v) in keyToItems) frozenKeyToItems[k] = v
            return CacheReferenceSnapshot(itemToKey, frozenKeyToItems, direct)
        }
    }
}
