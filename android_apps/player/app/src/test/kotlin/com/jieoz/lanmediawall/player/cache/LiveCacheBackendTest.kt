package com.jieoz.lanmediawall.player.cache

import com.jieoz.lanmediawall.player.net.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Android LIVE cache adapter over the REAL [Downloader] + on-disk blobs (TB2).
 * Mirror of `windows_player/tests/test_cache_live.py`: proves the protection
 * union and cleanup semantics hold through the real adapter, not only the
 * FakeBackend core tests.
 */
class LiveCacheBackendTest {

    @get:Rule val tmp = TemporaryFolder()

    private fun item(id: String, sha: String? = null) = MediaItem(
        itemId = id, type = "video", name = "$id.mp4",
        url = "http://h/$id.mp4", size = null, sha256 = sha,
        durationMs = null, loop = false, raw = Json.Null)

    private fun playlist(pid: String, pushId: String, items: List<MediaItem>): Playlist {
        val raw = Json.Obj(linkedMapOf(
            "playlist_id" to Json.Str(pid),
            "push_id" to Json.Str(pushId),
            "items" to Json.Arr(items.map { it.raw }),
        ))
        return Playlist(pid, null, true, LoopMode.NONE, items, raw)
    }

    /** Materialize a ready blob on disk + a ready entry, as a finished download
     *  would leave it, and return the file. */
    private fun cacheFile(dl: Downloader, item: MediaItem): File {
        val path = dl.localPath(item)
        path.writeBytes(ByteArray(1000) { 'x'.code.toByte() })
        // A real download publishes readiness through prefetch/worker; here we
        // drive the same observable state the backend reads via restoreReadyFromDisk.
        dl.restoreReadyFromDisk(listOf(item))
        return path
    }

    private inner class FakeView(
        var active: Playlist? = null,
        var state: String = "idle",
        var currentIdx: Int = 0,
        var task: LastTask? = null,
        val known: MutableList<Playlist> = ArrayList(),
    ) : LiveCacheBackend.PlayerView {
        override fun activePlaylist() = active
        override fun playState() = state
        override fun currentItem() = active?.items?.getOrNull(currentIdx)
        override fun resolvePlaylist(playlistId: String?): Playlist? =
            known.firstOrNull { it.playlistId == playlistId } ?: active
        override fun lastTask() = task
        override fun knownPlaylists(): List<Playlist> {
            val out = ArrayList<Playlist>()
            active?.let { out.add(it) }
            for (pl in known) if (out.none { it.playlistId == pl.playlistId }) out.add(pl)
            return out
        }
        override fun cacheSummary(): Map<String, Any?> = mapOf("ready_items" to 0)
    }

    private fun downloader() = Downloader(tmp.newFolder("cache"))

    private fun commit(id: String, itemIds: List<String>, pushId: String = "push-1") =
        CacheCleanup.Request(id, "selected", itemIds = itemIds,
            expectedPushId = pushId)

    @Test fun commit_deletes_unreferenced_and_prunes_index() {
        val dl = downloader()
        val a = item("a")
        val path = cacheFile(dl, a)
        val view = FakeView(active = playlist("CURRENT", "push-1", emptyList()))
        val be = LiveCacheBackend(view, dl)
        val res = CacheCleanup(be).run(commit("r1", listOf("a")))
        assertTrue(res.ok)
        assertTrue(res.deleted.any { it.itemId == "a" })
        assertEquals(1000L, res.freedBytes)
        assertFalse("commit must delete the reclaimable blob", path.exists())
        assertFalse("index pruned", dl.readyPaths().containsKey("a"))
    }

    @Test fun dry_run_deletes_nothing() {
        val dl = downloader()
        val a = item("a")
        val path = cacheFile(dl, a)
        val be = LiveCacheBackend(FakeView(), dl)
        val res = CacheCleanup(be).run(
            CacheCleanup.Request("r1", "unreferenced", dryRun = true))
        assertTrue(res.dryRun)
        assertTrue(res.deleted.any { it.itemId == "a" })
        assertTrue("dry-run must not delete", path.exists())
    }

    @Test fun downloader_ownership_rejects_paths_outside_cache_root() {
        val dl = downloader()
        val outside = tmp.newFile("outside.bin")
        outside.writeText("do-not-delete")
        assertFalse(dl.ownsPath(outside))
        assertTrue(outside.exists())
    }

    @Test fun active_generation_and_playing_protected_leftover_reclaimed() {
        val dl = downloader()
        val a = item("a"); val b = item("b"); val c = item("c")
        val pa = cacheFile(dl, a); val pb = cacheFile(dl, b); val pc = cacheFile(dl, c)
        val view = FakeView(
            active = playlist("PL", "push-1", listOf(a, b)),
            state = "playing", currentIdx = 0)
        val res = CacheCleanup(LiveCacheBackend(view, dl))
            .run(commit("r1", listOf("c")))
        assertTrue("playing item protected", pa.exists())
        assertTrue("active-generation item protected", pb.exists())
        assertFalse("leftover item reclaimed", pc.exists())
        assertEquals(listOf("c"), res.deleted.map { it.itemId })
    }

    @Test fun last_task_item_is_protected() {
        val dl = downloader()
        val a = item("a")
        val pa = cacheFile(dl, a)
        val pl = playlist("PL", "push-1", listOf(a))
        val view = FakeView(task = LastTask("PL", 0, 0, 80, false),
            active = playlist("CURRENT", "push-1", emptyList()))
        view.known.add(pl)
        val res = CacheCleanup(LiveCacheBackend(view, dl))
            .run(commit("r1", listOf("a")))
        assertTrue("last_task item protected", pa.exists())
        assertEquals(CacheReferenceSnapshot.LAST_TASK,
            res.skipped.first { it.itemId == "a" }.reason)
    }

    @Test fun expected_push_mismatch_deletes_nothing() {
        val dl = downloader()
        val a = item("a")
        val pa = cacheFile(dl, a)
        val view = FakeView(active = playlist("PL", "push-current", listOf(a)),
            state = "idle")
        val res = CacheCleanup(LiveCacheBackend(view, dl)).run(
            CacheCleanup.Request("r1", "selected", itemIds = listOf("a"),
                expectedPushId = "push-STALE"))
        assertFalse(res.ok)
        assertEquals(CacheCleanup.GENERATION_MISMATCH, res.error)
        assertTrue(pa.exists())
    }

    private fun sha256(bytes: ByteArray): String =
        java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    @Test fun shared_content_protected_transitively_through_live_paths() {
        // Two ids with the SAME sha256 => one physical blob. One id is active
        // (protected); deleting the other must NOT remove the shared blob.
        val dl = downloader()
        val payload = ByteArray(1000) { 'x'.code.toByte() }
        val sha = sha256(payload) // real digest so restore-verify accepts it
        val a = item("a", sha); val b = item("b", sha)
        // both resolve to the same on-disk path (sha stem) — one file.
        val path = dl.localPath(a)
        path.writeBytes(payload)
        dl.restoreReadyFromDisk(listOf(a, b))
        val view = FakeView(active = playlist("PL", "push-1", listOf(a)),
            state = "idle")
        val res = CacheCleanup(LiveCacheBackend(view, dl))
            .run(commit("r1", listOf("a", "b")))
        assertTrue("shared blob protected by active alias; deleted=${res.deleted} skipped=${res.skipped} ready=${dl.readyPaths()}", path.exists())
        val reasons = res.skipped.associate { it.itemId to it.reason }
        assertEquals(CacheReferenceSnapshot.ACTIVE, reasons["a"])
        assertEquals(CacheReferenceSnapshot.SHARED_CONTENT, reasons["b"])
    }

    @Test fun shared_content_protected_when_only_unprotected_alias_is_ready() {
        val dl = downloader()
        val payload = ByteArray(1000) { 'y'.code.toByte() }
        val sha = sha256(payload)
        val active = item("active", sha)
        val cachedAlias = item("cached", sha)
        val path = dl.localPath(cachedAlias)
        path.writeBytes(payload)
        // Deliberately restore only the reclaim candidate. The active alias exists
        // solely in playlist metadata and must still protect the physical target.
        dl.restoreReadyFromDisk(listOf(cachedAlias))
        val view = FakeView(active = playlist("PL", "push-1", listOf(active)),
            state = "idle")
        val res = CacheCleanup(LiveCacheBackend(view, dl)).run(
            CacheCleanup.Request("r-meta", "selected", itemIds = listOf("cached"),
                expectedPushId = "push-1"))
        assertTrue(path.exists())
        assertEquals(CacheReferenceSnapshot.SHARED_CONTENT,
            res.skipped.single { it.itemId == "cached" }.reason)
    }

    @Test fun idempotent_replay_never_deletes_twice() {
        val dl = downloader()
        val a = item("a")
        cacheFile(dl, a)
        val view = FakeView(active = playlist("CURRENT", "push-1", emptyList()))
        val core = CacheCleanup(LiveCacheBackend(view, dl))
        val request = commit("r1", listOf("a"))
        val first = core.run(request)
        assertTrue(first.deleted.any { it.itemId == "a" })
        // replay: same request_id returns the terminal result, deletes nothing new.
        val second = core.run(request)
        assertTrue(second.idempotentReplay)
        assertEquals(first.deleted.map { it.itemId }, second.deleted.map { it.itemId })
    }
}
