package com.jieoz.lanmediawall.player.cache

import com.jieoz.lanmediawall.player.net.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Proven-safe cleanup core (design §3.2 / §4.2). Mirrors
 * `windows_player/tests/test_cache_cleanup.py`.
 */
class CacheCleanupTest {

    private fun item(id: String, sha: String? = null) = MediaItem(
        itemId = id, type = "video", name = "$id.mp4",
        url = "http://h/$id.mp4", size = null, sha256 = sha,
        durationMs = null, loop = false, raw = Json.Null)

    private fun keyOf(it: MediaItem): String {
        val sha = it.sha256
        return if (sha != null) "sha256:${sha.lowercase()}" else "path:${it.itemId}"
    }

    /** In-memory backend recording physical effects (mirror of FakeBackend). */
    private inner class FakeBackend(
        val inventoryItems: List<MediaItem>,
        val active: List<MediaItem> = emptyList(),
        val prepared: List<MediaItem> = emptyList(),
        val playing: MediaItem? = null,
        val resume: List<MediaItem> = emptyList(),
        val inflight: List<MediaItem> = emptyList(),
        val pinned: List<MediaItem> = emptyList(),
        var pushId: String? = "push-1",
        missing: List<String> = emptyList(),
        deleteFail: List<String> = emptyList(),
    ) : CacheCleanup.Backend {
        val sizes = LinkedHashMap<String, Long>()
        val deletedKeys = ArrayList<String>()
        val prunedIndex = ArrayList<String>()
        private val failKeys = deleteFail.toHashSet()

        init {
            for (it in inventoryItems) sizes[keyOf(it)] = 1000L
            for (k in missing) sizes.remove(k)
        }

        override fun contentKeyOf(item: MediaItem) = keyOf(item)
        override fun buildSnapshot() = CacheReferenceSnapshot.build(
            ::keyOf, inventoryItems, active, prepared, playing, resume,
            inflight, pinned)
        override fun inventory() = inventoryItems
        override fun sizeOf(contentKey: String) = sizes[contentKey]
        override fun currentPushId() = pushId
        override fun delete(contentKey: String): Boolean {
            if (contentKey in failKeys) return false
            if (!sizes.containsKey(contentKey)) return false
            sizes.remove(contentKey); deletedKeys.add(contentKey); return true
        }
        override fun pruneIndex(itemIds: List<String>) { prunedIndex.addAll(itemIds) }
        override fun summary(): Map<String, Any?> =
            mapOf("ready_items" to sizes.size, "total_bytes" to sizes.values.sum(),
                  "reclaimable_bytes" to 0)
    }

    private fun req(id: String = "r1", mode: String = "unreferenced",
                    itemIds: List<String>? = null, dryRun: Boolean = false,
                    expected: String? = null) =
        CacheCleanup.Request(id, mode, itemIds, dryRun, expected, "manual")

    @Test fun active_cannot_be_deleted() {
        val a = item("a", "AA"); val h = item("h", "HH")
        val be = FakeBackend(listOf(a, h), active = listOf(a))
        val res = CacheCleanup(be).run(req())
        assertEquals(listOf(keyOf(h)), be.deletedKeys)
        assertEquals(CacheReferenceSnapshot.ACTIVE,
            res.skipped.first { it.itemId == "a" }.reason)
        assertTrue(res.deleted.any { it.itemId == "h" })
    }

    @Test fun prepared_cannot_be_deleted() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), prepared = listOf(a))
        val res = CacheCleanup(be).run(req())
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.PREPARED, res.skipped[0].reason)
    }

    @Test fun playing_cannot_be_deleted() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), playing = a)
        val res = CacheCleanup(be).run(req())
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.PLAYING, res.skipped[0].reason)
    }

    @Test fun last_task_cannot_be_deleted() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), resume = listOf(a))
        val res = CacheCleanup(be).run(req())
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.LAST_TASK, res.skipped[0].reason)
    }

    @Test fun inflight_cannot_be_deleted() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), inflight = listOf(a))
        val res = CacheCleanup(be).run(req())
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.INFLIGHT, res.skipped[0].reason)
    }

    @Test fun pinned_cannot_be_deleted() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), pinned = listOf(a))
        val res = CacheCleanup(be).run(req())
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.PINNED, res.skipped[0].reason)
    }

    @Test fun shared_blob_not_deleted_while_any_ref_protected() {
        val a = item("a", "DEAD"); val b = item("b", "dead")
        val be = FakeBackend(listOf(a, b), active = listOf(a))
        val res = CacheCleanup(be).run(req())
        assertTrue(be.deletedKeys.isEmpty())
        val reasons = res.skipped.associate { it.itemId to it.reason }
        assertEquals(CacheReferenceSnapshot.ACTIVE, reasons["a"])
        assertEquals(CacheReferenceSnapshot.SHARED_CONTENT, reasons["b"])
    }

    @Test fun playlist_history_alone_is_reclaimable() {
        val old = item("old", "0LD")
        val be = FakeBackend(listOf(old))
        val res = CacheCleanup(be).run(req())
        assertEquals(listOf(keyOf(old)), be.deletedKeys)
        assertEquals("old", res.deleted[0].itemId)
        assertEquals(1000L, res.freedBytes)
    }

    @Test fun dry_run_reports_candidates_without_mutating() {
        val a = item("a", "AA"); val h = item("h", "HH")
        val be = FakeBackend(listOf(a, h), active = listOf(a))
        val res = CacheCleanup(be).run(req(dryRun = true))
        assertTrue(res.dryRun)
        assertTrue(be.deletedKeys.isEmpty() && be.prunedIndex.isEmpty())
        assertTrue(res.deleted.any { it.itemId == "h" })
        assertEquals(1000L, res.freedBytes)
        assertEquals(2, res.summaryAfter["ready_items"])
    }

    @Test fun selected_mode_targets_only_given_ids() {
        val a = item("a", "AA"); val b = item("b", "BB"); val c = item("c", "CC")
        val be = FakeBackend(listOf(a, b, c))
        val res = CacheCleanup(be).run(req(mode = "selected", itemIds = listOf("b")))
        assertEquals(listOf(keyOf(b)), be.deletedKeys)
        assertEquals(listOf("b"), res.deleted.map { it.itemId })
    }

    @Test fun selected_unknown_id_is_not_found() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a))
        val res = CacheCleanup(be).run(req(mode = "selected", itemIds = listOf("ghost")))
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.NOT_FOUND, res.skipped[0].reason)
    }

    @Test fun missing_file_reports_not_found() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), missing = listOf(keyOf(item("a", "AA"))))
        val res = CacheCleanup(be).run(req())
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.NOT_FOUND, res.skipped[0].reason)
        assertTrue(res.failed.isEmpty())
    }

    @Test fun delete_failure_reports_delete_failed() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), deleteFail = listOf(keyOf(item("a", "AA"))))
        val res = CacheCleanup(be).run(req())
        assertEquals("a", res.failed[0].itemId)
        assertEquals(CacheCleanup.DELETE_FAILED, res.failed[0].reason)
        assertTrue(res.deleted.isEmpty())
    }

    @Test fun expected_push_mismatch_fails_closed() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), pushId = "push-current")
        val res = CacheCleanup(be).run(req(expected = "push-STALE"))
        assertFalse(res.ok)
        assertEquals(CacheCleanup.GENERATION_MISMATCH, res.error)
        assertTrue(be.deletedKeys.isEmpty())
    }

    @Test fun generation_change_between_plan_and_commit_aborts() {
        // A racing generation move is simulated by a backend whose currentPushId
        // returns "push-1" on the pre-plan read, then "push-2" on the commit
        // re-check — exactly the fail-closed window design §4.2 step 4 guards.
        val a = item("a", "AA"); val h = item("h", "HH")
        val be = object : CacheCleanup.Backend {
            var reads = 0
            val sizes = linkedMapOf(keyOf(a) to 1000L, keyOf(h) to 1000L)
            val deletedKeys = ArrayList<String>()
            override fun contentKeyOf(item: MediaItem) = keyOf(item)
            override fun buildSnapshot() = CacheReferenceSnapshot.build(
                ::keyOf, listOf(a, h), listOf(a))
            override fun inventory() = listOf(a, h)
            override fun sizeOf(contentKey: String) = sizes[contentKey]
            override fun currentPushId(): String {
                reads++; return if (reads == 1) "push-1" else "push-2"
            }
            override fun delete(contentKey: String): Boolean {
                deletedKeys.add(contentKey); sizes.remove(contentKey); return true
            }
            override fun pruneIndex(itemIds: List<String>) {}
            override fun summary(): Map<String, Any?> = emptyMap()
        }
        val res = CacheCleanup(be).run(req(expected = "push-1"))
        assertFalse(res.ok)
        assertEquals(CacheCleanup.GENERATION_CHANGED, res.error)
        assertTrue(be.deletedKeys.isEmpty())
    }

    @Test fun repeated_request_id_does_not_delete_twice() {
        val h = item("h", "HH")
        val be = FakeBackend(listOf(h))
        val cl = CacheCleanup(be)
        val first = cl.run(req(id = "dup"))
        assertEquals(listOf(keyOf(h)), be.deletedKeys)
        val second = cl.run(req(id = "dup"))
        assertEquals(listOf(keyOf(h)), be.deletedKeys) // still one delete
        assertTrue(second.idempotentReplay)
        assertEquals(first.copy(), second.copy(idempotentReplay = false))
    }

    @Test fun dry_run_is_not_journaled_as_terminal() {
        val h = item("h", "HH")
        val be = FakeBackend(listOf(h))
        val cl = CacheCleanup(be)
        cl.run(req(id = "dr", dryRun = true))
        cl.run(req(id = "commit1"))
        assertEquals(listOf(keyOf(h)), be.deletedKeys)
    }

    @Test fun success_prunes_index_and_updates_summary() {
        val a = item("a", "AA"); val h = item("h", "HH")
        val be = FakeBackend(listOf(a, h), active = listOf(a))
        val res = CacheCleanup(be).run(req())
        assertTrue(be.prunedIndex.contains("h"))
        assertEquals(1, res.summaryAfter["ready_items"])
        assertEquals("push-1", res.observedPushId)
    }
}
