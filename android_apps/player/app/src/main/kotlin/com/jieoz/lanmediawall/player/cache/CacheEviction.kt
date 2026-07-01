package com.jieoz.lanmediawall.player.cache

/**
 * Pure cache quota + eviction math (protocol_spec §6) — no Android/File deps so
 * it is fully unit-testable on the JVM. The [Downloader] scans its cache dir,
 * turns each file into a [CacheFile], and asks [selectEvictions] which entries
 * to delete to get back under quota.
 *
 * Policy: **LRU** — evict the least-recently-accessed files first (by
 * [CacheFile.lastAccessMs], a mtime proxy the Downloader touches on playback).
 * Files that back the currently-referenced playlist are marked
 * [CacheFile.protected] and are **never** evicted, even if that means staying
 * over quota (correctness over disk hygiene: we must not delete media we are
 * about to play — the §11 black-screen guard depends on it).
 *
 * This mirrors the intent of windows_player's OS-reclaimable cache dir; Android
 * app cache can be reclaimed by the OS too, but a 4–8GB 山寨盒 fills faster than
 * the OS reclaims, hence an explicit in-app quota to prevent `Storage Full`.
 */
object CacheEviction {

    /** Default absolute cap when the operator hasn't overridden it: 2 GiB. */
    const val DEFAULT_MAX_BYTES: Long = 2L * 1024 * 1024 * 1024

    /** Fraction (percent) of currently-available space the cache may occupy. */
    const val DEFAULT_SPACE_PERCENT: Int = 50

    /** One file in the media cache, reduced to what eviction needs. */
    data class CacheFile(
        val id: String,          // stable key (absolute path or item id)
        val sizeBytes: Long,
        val lastAccessMs: Long,  // mtime proxy; smaller = older = evict first
        val protected: Boolean,  // backs the current playlist → never evict
    )

    /** Result of an eviction pass — the ids to delete + before/after sizes. */
    data class Plan(
        val evict: List<String>,
        val freedBytes: Long,
        val totalBefore: Long,
        val totalAfter: Long,
    )

    /**
     * Effective quota = the *smaller* of the configured absolute cap and a
     * percentage of what's physically available (current cache + free disk).
     * Keeps headroom on a nearly-full small disk so we never fill it to 100%.
     *
     * @param configuredMaxBytes operator cap (Settings.cacheMaxBytes).
     * @param usableSpaceBytes free bytes on the cache volume right now
     *        (File.usableSpace — excludes what the cache already occupies).
     * @param currentCacheBytes bytes the cache currently occupies.
     */
    fun effectiveQuota(
        configuredMaxBytes: Long,
        usableSpaceBytes: Long,
        currentCacheBytes: Long,
        spacePercent: Int = DEFAULT_SPACE_PERCENT,
    ): Long {
        val available = (usableSpaceBytes + currentCacheBytes).coerceAtLeast(0)
        val pct = spacePercent.coerceIn(1, 100)
        val spaceCap = available / 100 * pct
        val cap = minOf(configuredMaxBytes.coerceAtLeast(0), spaceCap)
        // never return a negative/zero-only-because-of-math quota
        return cap.coerceAtLeast(0)
    }

    /**
     * Decide which files to evict so the *unprotected* footprint fits under
     * [maxBytes]. Protected files always count toward the total but are never
     * chosen for eviction. Unprotected candidates are removed oldest-first
     * (ascending [CacheFile.lastAccessMs]) until the total is within quota or
     * no unprotected candidates remain.
     */
    fun selectEvictions(files: List<CacheFile>, maxBytes: Long): Plan {
        val totalBefore = files.sumOf { it.sizeBytes }
        if (totalBefore <= maxBytes) {
            return Plan(emptyList(), 0, totalBefore, totalBefore)
        }
        // LRU order among evictable (unprotected) files. Ties broken by larger
        // file first (frees quota faster), then id for determinism.
        val candidates = files.asSequence()
            .filter { !it.protected }
            .sortedWith(
                compareBy<CacheFile> { it.lastAccessMs }
                    .thenByDescending { it.sizeBytes }
                    .thenBy { it.id },
            )
            .toList()

        var total = totalBefore
        var freed = 0L
        val evict = ArrayList<String>()
        for (f in candidates) {
            if (total <= maxBytes) break
            evict.add(f.id)
            total -= f.sizeBytes
            freed += f.sizeBytes
        }
        return Plan(evict, freed, totalBefore, total)
    }
}
