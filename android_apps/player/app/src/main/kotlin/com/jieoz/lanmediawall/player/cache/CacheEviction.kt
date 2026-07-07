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

    /**
     * 山寨假容量红线:一个**绝对**的保守上限,任何 operator 配额 / 空间百分比都
     * **不得把有效配额抬高到它之上**。这些盒子 `df`/`usableSpace` 上报的容量是假的
     * (真实颗粒可能只有 8G/16G),所以我们永远不信任设备上报的剩余空间去放大配额。
     * 2 GiB 是按最坏情况的真实颗粒设想的保守值;operator 只能在 Settings 里往**更小**调。
     */
    const val ABSOLUTE_MAX_BYTES: Long = 2L * 1024 * 1024 * 1024

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
     * Effective quota under the 山寨假容量红线. The result is the **smaller** of:
     *   1. the configured operator cap, and
     *   2. a conservative [absoluteMaxBytes] hard ceiling (never信任设备上报容量),
     * and the space-percentage may **only tighten** it further — never抬高。
     *
     * Concretely: `min(configuredMax, absoluteMax)` sets the ceiling; the
     * %-of-available term can pull the quota *below* that ceiling when the disk
     * is genuinely small, but it can NEVER raise the quota above the ceiling
     * (which is the old bug: a fake 100G `usableSpace` computed a huge spaceCap
     * that let an inflated operator cap write straight through the real颗粒).
     *
     * @param configuredMaxBytes operator cap (Settings.cacheMaxBytes). 0 → treat
     *        as "use the absolute ceiling" (the operator didn't tighten).
     * @param usableSpaceBytes free bytes on the cache volume right now
     *        (File.usableSpace). **Untrusted** on fake-capacity boxes — used only
     *        to tighten, never to grow, the quota. The write-probe in the
     *        Downloader is the real "can we still write?" check.
     * @param currentCacheBytes bytes the cache currently occupies.
     * @param absoluteMaxBytes the conservative hard ceiling (defaults to
     *        [ABSOLUTE_MAX_BYTES]); the quota can never exceed it.
     */
    fun effectiveQuota(
        configuredMaxBytes: Long,
        usableSpaceBytes: Long,
        currentCacheBytes: Long,
        spacePercent: Int = DEFAULT_SPACE_PERCENT,
        absoluteMaxBytes: Long = ABSOLUTE_MAX_BYTES,
    ): Long {
        val absolute = absoluteMaxBytes.coerceAtLeast(0)
        // 0 = operator didn't set a smaller cap → fall back to the absolute
        // ceiling (which itself is the最 permissive we ever allow).
        val configured = configuredMaxBytes.coerceAtLeast(0)
            .let { if (it == 0L) absolute else it }
        // Ceiling = the smaller of operator cap and the conservative hard cap.
        // The operator can only ever move this *down* (a bigger cap is clamped).
        val ceiling = minOf(configured, absolute)

        // Space-percentage may only *tighten*: compute a %-of-available cap and
        // take the min with the ceiling. On a fake 100G box the spaceCap is
        // huge, so min() just yields the ceiling — the fake space can NEVER
        // raise us above it. On a genuinely tiny disk the spaceCap is small and
        // pulls the quota below the ceiling for headroom.
        // Multiply-before-divide so the %-cap is exact (the old `/100*pct` form
        // double-truncated). Clamp `available` to 1 PiB first so `available*pct`
        // can't overflow Long even when usableSpace is the Long.MAX_VALUE probe
        // fallback — 1 PiB ≫ any real ceiling, so the clamp never changes the
        // min() result on a real box.
        val available = (usableSpaceBytes + currentCacheBytes).coerceAtLeast(0)
            .coerceAtMost(1L shl 50)
        val pct = spacePercent.coerceIn(1, 100)
        val spaceCap = available * pct / 100
        return minOf(ceiling, spaceCap).coerceAtLeast(0)
    }

    /**
     * 孤儿媒体选择(纯函数,便于单测)。回收**不再被任何活跃 playlist 引用**的媒体:
     * 从 [files] 中挑出既不在 [referencedIds] 中、又未被 [CacheFile.protected] 保护
     * 的文件。protected 覆盖当前 playlist 媒体、`.part` 在传文件、last_task 指向的
     * 文件与探针文件(黑屏红线:绝不误删将要播的媒体)。
     *
     * 与 [selectEvictions] 的区别:这里**不看配额/大小**,纯按"是否还被引用"回收,
     * 是新内容投送前给假闪存腾真实余量的主动清理。
     */
    fun selectOrphans(files: List<CacheFile>, referencedIds: Set<String>): List<String> =
        files.asSequence()
            .filter { !it.protected && it.id !in referencedIds }
            .map { it.id }
            .toList()

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
