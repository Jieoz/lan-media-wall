package com.jieoz.lanmediawall.player.cache

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * §6 cache quota + LRU eviction math. Pure logic — no File/Android deps.
 */
class CacheEvictionTest {

    private fun f(id: String, size: Long, access: Long, prot: Boolean = false) =
        CacheEviction.CacheFile(id, size, access, prot)

    @Test
    fun under_quota_evicts_nothing() {
        val files = listOf(f("a", 100, 1), f("b", 100, 2))
        val plan = CacheEviction.selectEvictions(files, maxBytes = 1000)
        assertTrue(plan.evict.isEmpty())
        assertEquals(0L, plan.freedBytes)
        assertEquals(200L, plan.totalBefore)
        assertEquals(200L, plan.totalAfter)
    }

    @Test
    fun evicts_least_recently_used_first() {
        // total 300, quota 150 → must drop 150+. Oldest (access=1) goes first.
        val files = listOf(
            f("old", 100, 1),
            f("mid", 100, 5),
            f("new", 100, 9),
        )
        val plan = CacheEviction.selectEvictions(files, maxBytes = 150)
        // dropping "old" (100) leaves 200 > 150; drop "mid" too → 100 ≤ 150.
        assertEquals(listOf("old", "mid"), plan.evict)
        assertEquals(200L, plan.freedBytes)
        assertEquals(100L, plan.totalAfter)
    }

    @Test
    fun stops_as_soon_as_under_quota() {
        val files = listOf(
            f("old", 100, 1),
            f("new", 100, 9),
        )
        val plan = CacheEviction.selectEvictions(files, maxBytes = 150)
        assertEquals(listOf("old"), plan.evict) // one is enough
        assertEquals(100L, plan.totalAfter)
    }

    @Test
    fun never_evicts_protected_even_if_over_quota() {
        // both protected, total 300 > quota 100 → cannot evict anything.
        val files = listOf(
            f("p1", 150, 1, prot = true),
            f("p2", 150, 2, prot = true),
        )
        val plan = CacheEviction.selectEvictions(files, maxBytes = 100)
        assertTrue(plan.evict.isEmpty())
        assertEquals(300L, plan.totalAfter) // stays over quota by design
    }

    @Test
    fun protected_counts_toward_total_but_unprotected_is_evicted() {
        // protected 200 + unprotected 200 = 400, quota 350. Protected can't go;
        // evict unprotected oldest until total ≤ 350: drop u_old → 300 ≤ 350.
        val files = listOf(
            f("keep", 200, 100, prot = true),
            f("u_old", 100, 1),
            f("u_new", 100, 9),
        )
        val plan = CacheEviction.selectEvictions(files, maxBytes = 350)
        assertEquals(listOf("u_old"), plan.evict)
        assertEquals(300L, plan.totalAfter)
    }

    @Test
    fun evicts_all_unprotected_when_still_over() {
        val files = listOf(
            f("keep", 200, 100, prot = true),
            f("u_old", 100, 1),
            f("u_new", 100, 9),
        )
        val plan = CacheEviction.selectEvictions(files, maxBytes = 150)
        // 400 → drop u_old (300) → drop u_new (200) → no more unprotected; 200>150
        assertEquals(listOf("u_old", "u_new"), plan.evict)
        assertEquals(200L, plan.totalAfter)
    }

    @Test
    fun larger_file_breaks_access_time_tie() {
        val files = listOf(
            f("small", 50, 5),
            f("big", 200, 5), // same access time; bigger frees quota faster
        )
        val plan = CacheEviction.selectEvictions(files, maxBytes = 100)
        assertEquals("big", plan.evict.first())
    }

    @Test
    fun effective_quota_is_min_of_cap_and_space_percent() {
        // cap 2GB, but only 1GB available → space cap (50% of 1GB) wins = 512MB
        val gb = 1024L * 1024 * 1024
        val q = CacheEviction.effectiveQuota(
            configuredMaxBytes = 2 * gb,
            usableSpaceBytes = gb,
            currentCacheBytes = 0,
        )
        assertEquals(gb / 2, q)
    }

    @Test
    fun effective_quota_cap_wins_when_disk_is_roomy() {
        val gb = 1024L * 1024 * 1024
        val q = CacheEviction.effectiveQuota(
            configuredMaxBytes = 2 * gb,
            usableSpaceBytes = 100 * gb, // tons of room → 50% huge; cap wins
            currentCacheBytes = 0,
        )
        assertEquals(2 * gb, q)
    }

    @Test
    fun effective_quota_includes_current_cache_in_available() {
        val gb = 1024L * 1024 * 1024
        // 0 free but 4GB already cached → available=4GB, 50% = 2GB, cap 2GB → 2GB
        val q = CacheEviction.effectiveQuota(
            configuredMaxBytes = 2 * gb,
            usableSpaceBytes = 0,
            currentCacheBytes = 4 * gb,
        )
        assertEquals(2 * gb, q)
    }

    // --- 山寨假容量红线 (G) ------------------------------------------------

    @Test
    fun fake_capacity_never_raises_quota_above_absolute_ceiling() {
        val gb = 1024L * 1024 * 1024
        // A fake box reports 103G usable AND the operator was tricked into a huge
        // 50G cap. The old code trusted usableSpace → 50% of 103G = 51G → cap 50G
        // wins → writes straight through the real颗粒. New: clamped to the 2 GiB
        // absolute ceiling regardless.
        val q = CacheEviction.effectiveQuota(
            configuredMaxBytes = 50 * gb,
            usableSpaceBytes = 103 * gb,
            currentCacheBytes = 0,
        )
        assertEquals(CacheEviction.ABSOLUTE_MAX_BYTES, q)
        assertTrue(q <= CacheEviction.ABSOLUTE_MAX_BYTES)
    }

    @Test
    fun space_percent_can_only_tighten_not_grow() {
        val gb = 1024L * 1024 * 1024
        // genuinely tiny real disk (256MB free) → space term pulls quota BELOW
        // the 2GiB ceiling for headroom.
        val small = CacheEviction.effectiveQuota(
            configuredMaxBytes = 2 * gb,
            usableSpaceBytes = 256L * 1024 * 1024,
            currentCacheBytes = 0,
        )
        assertEquals(128L * 1024 * 1024, small) // 50% of 256MB
        assertTrue(small < CacheEviction.ABSOLUTE_MAX_BYTES)
    }

    @Test
    fun operator_can_only_tighten_below_ceiling() {
        val mb = 1024L * 1024
        // operator sets a smaller 512MB cap on a roomy (fake) disk → honored.
        val q = CacheEviction.effectiveQuota(
            configuredMaxBytes = 512 * mb,
            usableSpaceBytes = 999L * 1024 * mb,
            currentCacheBytes = 0,
        )
        assertEquals(512 * mb, q)
    }

    @Test
    fun zero_configured_falls_back_to_absolute_ceiling() {
        val gb = 1024L * 1024 * 1024
        // 0 = operator didn't tighten → use the absolute ceiling, not unlimited.
        val q = CacheEviction.effectiveQuota(
            configuredMaxBytes = 0,
            usableSpaceBytes = 500 * gb,
            currentCacheBytes = 0,
        )
        assertEquals(CacheEviction.ABSOLUTE_MAX_BYTES, q)
    }

    // --- 孤儿媒体回收 (G) --------------------------------------------------

    @Test
    fun orphans_are_unreferenced_and_unprotected() {
        val files = listOf(
            f("current", 100, 1, prot = true),  // current playlist media
            f("part", 50, 2, prot = true),      // .part in flight
            f("referenced", 100, 3),            // still in a recent playlist
            f("orphan1", 100, 4),               // nobody references it
            f("orphan2", 100, 5),
        )
        val orphans = CacheEviction.selectOrphans(
            files, referencedIds = setOf("referenced"),
        )
        assertEquals(listOf("orphan1", "orphan2"), orphans)
    }

    @Test
    fun protected_is_never_an_orphan_even_if_unreferenced() {
        // last_task media that dropped out of referencedIds must still survive
        // because it's marked protected — the black-screen red line.
        val files = listOf(f("last_task_media", 100, 1, prot = true))
        val orphans = CacheEviction.selectOrphans(files, referencedIds = emptySet())
        assertTrue(orphans.isEmpty())
    }
}
