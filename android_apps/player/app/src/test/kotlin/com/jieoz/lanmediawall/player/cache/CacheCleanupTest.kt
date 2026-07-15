package com.jieoz.lanmediawall.player.cache

import com.jieoz.lanmediawall.player.net.Json
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
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

    private fun run(be: CacheCleanup.Backend, request: CacheCleanup.Request): CacheCleanup.CleanupResult {
        val valid = if (!request.dryRun) {
            val ids = if (request.mode == "unreferenced")
                be.inventory().map { it.itemId } else request.itemIds
            request.copy(mode = "selected", itemIds = ids,
                expectedPushId = request.expectedPushId ?: be.currentPushId())
        } else request
        return CacheCleanup(be).run(valid)
    }

    @Test fun direct_broad_commit_is_rejected() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a))
        val result = CacheCleanup(be).run(req(mode = "unreferenced"))
        assertFalse(result.ok)
        assertEquals(CacheCleanup.INVALID_REQUEST, result.error)
        assertTrue(be.deletedKeys.isEmpty())
    }

    @Test fun selected_commit_requires_ids_and_generation() {
        val a = item("a", "AA")
        for (request in listOf(
            req(mode = "selected", itemIds = emptyList(), expected = "push-1"),
            req(mode = "selected", itemIds = listOf("a"), expected = null))) {
            val be = FakeBackend(listOf(a))
            val result = CacheCleanup(be).run(request)
            assertFalse(result.ok)
            assertEquals(CacheCleanup.INVALID_REQUEST, result.error)
            assertTrue(be.deletedKeys.isEmpty())
        }
    }

    @Test fun active_cannot_be_deleted() {
        val a = item("a", "AA"); val h = item("h", "HH")
        val be = FakeBackend(listOf(a, h), active = listOf(a))
        val res = run(be, req())
        assertEquals(listOf(keyOf(h)), be.deletedKeys)
        assertEquals(CacheReferenceSnapshot.ACTIVE,
            res.skipped.first { it.itemId == "a" }.reason)
        assertTrue(res.deleted.any { it.itemId == "h" })
    }

    @Test fun prepared_cannot_be_deleted() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), prepared = listOf(a))
        val res = run(be, req())
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.PREPARED, res.skipped[0].reason)
    }

    @Test fun playing_cannot_be_deleted() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), playing = a)
        val res = run(be, req())
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.PLAYING, res.skipped[0].reason)
    }

    @Test fun last_task_cannot_be_deleted() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), resume = listOf(a))
        val res = run(be, req())
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.LAST_TASK, res.skipped[0].reason)
    }

    @Test fun inflight_cannot_be_deleted() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), inflight = listOf(a))
        val res = run(be, req())
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.INFLIGHT, res.skipped[0].reason)
    }

    @Test fun pinned_cannot_be_deleted() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), pinned = listOf(a))
        val res = run(be, req())
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.PINNED, res.skipped[0].reason)
    }

    @Test fun shared_blob_not_deleted_while_any_ref_protected() {
        val a = item("a", "DEAD"); val b = item("b", "dead")
        val be = FakeBackend(listOf(a, b), active = listOf(a))
        val res = run(be, req())
        assertTrue(be.deletedKeys.isEmpty())
        val reasons = res.skipped.associate { it.itemId to it.reason }
        assertEquals(CacheReferenceSnapshot.ACTIVE, reasons["a"])
        assertEquals(CacheReferenceSnapshot.SHARED_CONTENT, reasons["b"])
    }

    @Test fun playlist_history_alone_is_reclaimable() {
        val old = item("old", "0LD")
        val be = FakeBackend(listOf(old))
        val res = run(be, req())
        assertEquals(listOf(keyOf(old)), be.deletedKeys)
        assertEquals("old", res.deleted[0].itemId)
        assertEquals(1000L, res.freedBytes)
    }

    @Test fun dry_run_reports_candidates_without_mutating() {
        val a = item("a", "AA"); val h = item("h", "HH")
        val be = FakeBackend(listOf(a, h), active = listOf(a))
        val res = run(be, req(dryRun = true))
        assertTrue(res.dryRun)
        assertTrue(be.deletedKeys.isEmpty() && be.prunedIndex.isEmpty())
        assertTrue(res.deleted.any { it.itemId == "h" })
        assertEquals(1000L, res.freedBytes)
        assertEquals(2, res.summaryAfter["ready_items"])
    }

    @Test fun selected_mode_targets_only_given_ids() {
        val a = item("a", "AA"); val b = item("b", "BB"); val c = item("c", "CC")
        val be = FakeBackend(listOf(a, b, c))
        val res = run(be, req(mode = "selected", itemIds = listOf("b")))
        assertEquals(listOf(keyOf(b)), be.deletedKeys)
        assertEquals(listOf("b"), res.deleted.map { it.itemId })
    }

    @Test fun selected_unknown_id_is_not_found() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a))
        val res = run(be, req(mode = "selected", itemIds = listOf("ghost")))
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.NOT_FOUND, res.skipped[0].reason)
    }

    @Test fun missing_file_reports_not_found() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), missing = listOf(keyOf(item("a", "AA"))))
        val res = run(be, req())
        assertTrue(be.deletedKeys.isEmpty())
        assertEquals(CacheReferenceSnapshot.NOT_FOUND, res.skipped[0].reason)
        assertTrue(res.failed.isEmpty())
    }

    @Test fun delete_failure_reports_delete_failed() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), deleteFail = listOf(keyOf(item("a", "AA"))))
        val res = run(be, req())
        assertEquals("a", res.failed[0].itemId)
        assertEquals(CacheCleanup.DELETE_FAILED, res.failed[0].reason)
        assertTrue(res.deleted.isEmpty())
    }

    @Test fun expected_push_mismatch_fails_closed() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a), pushId = "push-current")
        val res = run(be, req(expected = "push-STALE"))
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
        val res = run(be, req(expected = "push-1"))
        assertFalse(res.ok)
        assertEquals(CacheCleanup.GENERATION_CHANGED, res.error)
        assertTrue(be.deletedKeys.isEmpty())
    }

    @Test fun idle_device_destructive_commit_is_forbidden_fail_closed() {
        // Phase B limitation, made EXPLICIT (mirror of the Windows test): an IDLE
        // device has NO adopted generation — currentPushId() is null. A
        // destructive commit requires a NON-EMPTY expectedPushId (else
        // invalid_request); that token can never equal the idle null, so the
        // pre-plan guard fails closed with generation_mismatch and deletes
        // nothing. No sentinel, no weakening: destructive cleanup on an idle
        // device is simply not possible in Phase B.
        val a = item("a", "AA")

        // (1) omitting the generation on a destructive commit → invalid_request.
        val beMissing = FakeBackend(listOf(a), pushId = null)
        val resMissing = CacheCleanup(beMissing).run(
            req(mode = "selected", itemIds = listOf("a"), expected = null))
        assertFalse(resMissing.ok)
        assertEquals(CacheCleanup.INVALID_REQUEST, resMissing.error)
        assertTrue(beMissing.deletedKeys.isEmpty())

        // (2) any non-empty generation on an idle device fails closed:
        // non-empty token != idle null → generation_mismatch, nothing deleted.
        val beSupplied = FakeBackend(listOf(a), pushId = null)
        val resSupplied = CacheCleanup(beSupplied).run(
            req(mode = "selected", itemIds = listOf("a"), expected = "push-anything"))
        assertFalse(resSupplied.ok)
        assertEquals(CacheCleanup.GENERATION_MISMATCH, resSupplied.error)
        assertEquals(null, resSupplied.observedPushId)
        assertTrue(beSupplied.deletedKeys.isEmpty())

        // (3) a dry-run is still fine on idle (non-destructive, no generation).
        val beDry = FakeBackend(listOf(a), pushId = null)
        val resDry = CacheCleanup(beDry).run(
            req(mode = "selected", itemIds = listOf("a"), dryRun = true))
        assertTrue(resDry.ok && resDry.dryRun)
        assertTrue(beDry.deletedKeys.isEmpty())
    }

    @Test fun repeated_request_id_does_not_delete_twice() {
        val h = item("h", "HH")
        val be = FakeBackend(listOf(h))
        val cl = CacheCleanup(be)
        val request = req(id = "dup", mode = "selected", itemIds = listOf("h"),
            expected = "push-1")
        val first = cl.run(request)
        assertEquals(listOf(keyOf(h)), be.deletedKeys)
        val second = cl.run(request)
        assertEquals(listOf(keyOf(h)), be.deletedKeys) // still one delete
        assertTrue(second.idempotentReplay)
        assertEquals(first.copy(), second.copy(idempotentReplay = false))
    }

    @Test fun dry_run_is_not_journaled_as_terminal() {
        val h = item("h", "HH")
        val be = FakeBackend(listOf(h))
        val cl = CacheCleanup(be)
        cl.run(req(id = "dr", dryRun = true))
        cl.run(req(id = "commit1", mode = "selected", itemIds = listOf("h"),
            expected = "push-1"))
        assertEquals(listOf(keyOf(h)), be.deletedKeys)
    }

    @Test fun success_prunes_index_and_updates_summary() {
        val a = item("a", "AA"); val h = item("h", "HH")
        val be = FakeBackend(listOf(a, h), active = listOf(a))
        val res = run(be, req())
        assertTrue(be.prunedIndex.contains("h"))
        assertEquals(1, res.summaryAfter["ready_items"])
        assertEquals("push-1", res.observedPushId)
    }

    // --- dangling-alias invariant (selected mode, shared blob) ----------
    @Test fun selected_one_alias_prunes_all_aliases_of_shared_blob() {
        // a1 and a2 are two DIFFERENT ids resolving to the SAME physical blob;
        // neither protected. A selected cleanup names only a1.
        val a1 = item("a1", "DEAD"); val a2 = item("a2", "dead")
        val be = FakeBackend(listOf(a1, a2))
        val res = run(be, req(mode = "selected", itemIds = listOf("a1")))
        // (2) blob deleted exactly once
        assertEquals(listOf(keyOf(a1)), be.deletedKeys)
        // (3) BOTH aliases pruned — no dangling row for a2
        assertEquals(listOf("a1", "a2"), be.prunedIndex.sorted())
        // (4) response honestly reports only the requested candidate id
        assertEquals(listOf("a1"), res.deleted.map { it.itemId })
        assertEquals(1000L, res.freedBytes)  // one-byte-count-per-blob
    }

    @Test fun selected_duplicate_id_deletes_and_prunes_once() {
        val a = item("a", "AA")
        val be = FakeBackend(listOf(a))
        val res = run(be,
            req(mode = "selected", itemIds = listOf("a", "a", "a")))
        assertEquals(listOf(keyOf(a)), be.deletedKeys)
        assertEquals(listOf("a"), be.prunedIndex)
        assertEquals(listOf("a"), res.deleted.map { it.itemId })
        assertEquals(1000L, res.freedBytes)
    }

    @Test fun unreferenced_mode_prunes_every_alias_of_reclaimed_blob() {
        val a1 = item("a1", "F00D"); val a2 = item("a2", "f00d")
        val be = FakeBackend(listOf(a1, a2))
        val res = run(be, req())  // unreferenced sweep
        assertEquals(listOf(keyOf(a1)), be.deletedKeys)      // one physical delete
        assertEquals(listOf("a1", "a2"), be.prunedIndex.sorted())  // both pruned
        assertEquals(1000L, res.freedBytes)                  // counted once
    }

    @Test fun dry_run_shared_alias_prunes_nothing() {
        val a1 = item("a1", "DEAD"); val a2 = item("a2", "dead")
        val be = FakeBackend(listOf(a1, a2))
        val res = CacheCleanup(be).run(
            req(mode = "selected", itemIds = listOf("a1"), dryRun = true))
        assertTrue(be.deletedKeys.isEmpty() && be.prunedIndex.isEmpty())
        assertEquals(listOf("a1"), res.deleted.map { it.itemId })
    }

    @Test fun delete_failure_shared_alias_prunes_nothing() {
        val a1 = item("a1", "DEAD"); val a2 = item("a2", "dead")
        val be = FakeBackend(listOf(a1, a2),
            deleteFail = listOf("sha256:dead"))
        val res = run(be, req(mode = "selected", itemIds = listOf("a1")))
        assertTrue(be.deletedKeys.isEmpty())   // physical delete failed
        assertTrue(be.prunedIndex.isEmpty())   // so NO alias pruned
        assertEquals("a1", res.failed[0].itemId)
        assertEquals(CacheCleanup.DELETE_FAILED, res.failed[0].reason)
    }

    // --- payload-derived fingerprint target (Broker/Windows parity) ------
    // The broker derives the fingerprint target FROM THE PAYLOAD:
    //   device:<device_id> when device-addressed, else group:<group_id> when
    //   group-addressed, else "all". Windows mirrors this. Android MUST derive
    //   the request target the same way — hard-coding device:<settings.deviceId>
    //   makes a GROUP-addressed request produce a device: fingerprint that the
    //   broker's operation_fingerprint verification (§27 result gate) rejects.

    /** Broker/Windows canonical fingerprint for a cache_cleanup payload — the
     *  exact byte stream both the Python broker (`_cleanup_fingerprint`) and the
     *  Windows player (`operation_fingerprint`) hash. Used here as the reference
     *  the Android request MUST match. */
    private fun brokerFingerprint(target: String, mode: String, dryRun: Boolean,
                                  itemIds: List<String>, expectedPushId: String,
                                  reason: String): String {
        val fields = ArrayList<String>()
        fields.add("cache_cleanup"); fields.add(target); fields.add(mode)
        fields.add(if (dryRun) "true" else "false")
        fields.addAll(itemIds); fields.add(expectedPushId); fields.add(reason)
        val canonical = fields.joinToString("") {
            "${it.toByteArray(Charsets.UTF_8).size}:$it"
        }
        return java.security.MessageDigest.getInstance("SHA-256")
            .digest(canonical.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    @Test fun target_derives_from_payload_like_broker() {
        // device-addressed → device:<device_id>
        assertEquals("device:dev-1", CacheCleanup.targetFor("dev-1", "g"))
        // group-addressed (no device_id) → group:<group_id>
        assertEquals("group:g", CacheCleanup.targetFor(null, "g"))
        // empty device_id is falsy (matches Python truthiness) → group
        assertEquals("group:g", CacheCleanup.targetFor("", "g"))
        // neither → all (broadcast)
        assertEquals("all", CacheCleanup.targetFor(null, null))
        assertEquals("all", CacheCleanup.targetFor("", ""))
    }

    // --- receive-loop latency: scan must not hold the generation lock ----
    @Test fun scan_does_not_hold_generation_lock_for_its_whole_duration() {
        // Design req. 10 + fail-closed §4.2: the SHARED generation lock (also
        // held by PlayerService playlist handlers) must NOT be occupied for the
        // whole O(N) scan/plan — only for the pre-delete re-check + delete
        // hand-off. Observed via a probe thread that takes the SAME lock while a
        // cleanup is parked mid-scan; with the old whole-run lock it blocks.
        val genLock = Any()
        val scanning = CountDownLatch(1)
        val releaseScan = CountDownLatch(1)
        val probeGotLock = CountDownLatch(1)

        val a = item("a", "AA"); val h = item("h", "HH")
        val be = object : CacheCleanup.Backend {
            val sizes = linkedMapOf(keyOf(a) to 1000L, keyOf(h) to 1000L)
            val deletedKeys = ArrayList<String>()
            override fun contentKeyOf(item: MediaItem) = keyOf(item)
            override fun buildSnapshot(): CacheReferenceSnapshot {
                scanning.countDown()
                releaseScan.await(2, TimeUnit.SECONDS) // slow scan
                return CacheReferenceSnapshot.build(::keyOf, listOf(a, h))
            }
            override fun inventory() = listOf(a, h)
            override fun sizeOf(contentKey: String) = sizes[contentKey]
            override fun currentPushId() = "push-1"
            override fun delete(contentKey: String): Boolean {
                sizes.remove(contentKey); deletedKeys.add(contentKey); return true
            }
            override fun pruneIndex(itemIds: List<String>) {}
            override fun summary(): Map<String, Any?> = emptyMap()
        }
        val core = CacheCleanup(be, genLock)

        val worker = Thread {
            core.run(CacheCleanup.Request("rL", "selected", listOf("a", "h"),
                false, "push-1", "manual"))
        }
        worker.start()
        assertTrue("scan never started", scanning.await(2, TimeUnit.SECONDS))

        // A playlist-handler-equivalent takes the generation lock while the
        // cleanup is parked mid-scan. If the scan holds it, this never fires.
        val probe = Thread {
            synchronized(genLock) { probeGotLock.countDown() }
        }
        probe.start()
        val got = probeGotLock.await(1, TimeUnit.SECONDS)
        releaseScan.countDown()
        worker.join(3000)
        probe.join(1000)
        assertTrue("generation lock was held for the entire scan " +
            "(receive-loop stall)", got)
        // fail-closed semantics intact: unprotected blobs still delete on commit.
        assertEquals(listOf(keyOf(a), keyOf(h)).sorted(), be.deletedKeys.sorted())
    }

    @Test fun group_request_fingerprint_matches_broker_not_device() {
        // A GROUP-addressed cleanup: payload has group_id="g", no device_id.
        // The player is dev-1, but the fingerprint target must be group:g so it
        // matches what the broker recorded and will verify the result against.
        val target = CacheCleanup.targetFor(null, "g")
        val request = CacheCleanup.Request(
            requestId = "rG", mode = "selected", itemIds = listOf("x"),
            dryRun = false, expectedPushId = "push-1", reason = "manual",
            target = target)
        val fp = CacheCleanup.operationFingerprint(request)
        // matches the broker/Windows canonical hash for group:g …
        assertEquals(
            brokerFingerprint("group:g", "selected", false, listOf("x"),
                "push-1", "manual"),
            fp)
        // … and is DISTINCT from the wrong device:dev-1 target a hard-coded
        // settings.deviceId would have produced.
        val wrong = CacheCleanup.operationFingerprint(
            request.copy(target = "device:dev-1"))
        assertFalse(fp == wrong)
    }
}
