package com.jieoz.lanmediawall.player.cache

import com.jieoz.lanmediawall.player.net.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Player-local protection union (design §4.1). Mirrors
 * `windows_player/tests/test_cache_refs.py`.
 */
class CacheReferenceSnapshotTest {

    private fun item(id: String, sha: String? = null) = MediaItem(
        itemId = id, type = "video", name = "$id.mp4",
        url = "http://h/$id.mp4", size = null, sha256 = sha,
        durationMs = null, loop = false, raw = Json.Null)

    private val keyOf: (MediaItem) -> String? = {
        val sha = it.sha256
        if (sha != null) "sha256:${sha.lowercase()}" else "path:${it.itemId}"
    }

    private fun build(
        inventory: List<MediaItem>,
        active: List<MediaItem> = emptyList(),
        prepared: List<MediaItem> = emptyList(),
        playing: MediaItem? = null,
        resume: List<MediaItem> = emptyList(),
        inflight: List<MediaItem> = emptyList(),
        pinned: List<MediaItem> = emptyList(),
    ) = CacheReferenceSnapshot.build(keyOf, inventory, active, prepared,
        playing, resume, inflight, pinned)

    @Test fun active_is_protected() {
        val a = item("a", "AA")
        val s = build(listOf(a), active = listOf(a))
        assertTrue(s.isProtected(s.contentKeyFor("a")))
        val c = s.classifyItem("a")
        assertEquals(CacheReferenceSnapshot.Kind.DIRECT, c.kind)
        assertEquals(CacheReferenceSnapshot.ACTIVE, c.reason)
    }

    @Test fun prepared_is_protected() {
        val a = item("a", "AA")
        assertEquals(CacheReferenceSnapshot.PREPARED,
            build(listOf(a), prepared = listOf(a)).classifyItem("a").reason)
    }

    @Test fun playing_is_protected() {
        val a = item("a", "AA")
        assertEquals(CacheReferenceSnapshot.PLAYING,
            build(listOf(a), playing = a).classifyItem("a").reason)
    }

    @Test fun last_task_is_protected() {
        val a = item("a", "AA")
        assertEquals(CacheReferenceSnapshot.LAST_TASK,
            build(listOf(a), resume = listOf(a)).classifyItem("a").reason)
    }

    @Test fun inflight_is_protected() {
        val a = item("a", "AA")
        assertEquals(CacheReferenceSnapshot.INFLIGHT,
            build(listOf(a), inflight = listOf(a)).classifyItem("a").reason)
    }

    @Test fun pinned_is_protected() {
        val a = item("a", "AA")
        assertEquals(CacheReferenceSnapshot.PINNED,
            build(listOf(a), pinned = listOf(a)).classifyItem("a").reason)
    }

    @Test fun unreferenced_is_deletable() {
        val a = item("a", "AA"); val h = item("h", "HH")
        val s = build(listOf(a, h), active = listOf(a))
        val c = s.classifyItem("h")
        assertEquals(CacheReferenceSnapshot.Kind.NONE, c.kind)
        assertNull(c.reason)
        assertFalse(s.isProtected(s.contentKeyFor("h")))
    }

    @Test fun shared_blob_protects_all_ids() {
        val a = item("a", "DEAD"); val b = item("b", "dead")
        val s = build(listOf(a, b), active = listOf(a))
        assertEquals(s.contentKeyFor("a"), s.contentKeyFor("b"))
        assertEquals(CacheReferenceSnapshot.ACTIVE, s.classifyItem("a").reason)
        val cb = s.classifyItem("b")
        assertEquals(CacheReferenceSnapshot.Kind.SHARED, cb.kind)
        assertEquals(CacheReferenceSnapshot.SHARED_CONTENT, cb.reason)
    }

    @Test fun playlist_history_alone_does_not_protect() {
        val old = item("old", "0LD")
        val c = build(listOf(old)).classifyItem("old")
        assertEquals(CacheReferenceSnapshot.Kind.NONE, c.kind)
        assertNull(c.reason)
    }

    @Test fun playing_takes_precedence_over_active() {
        val a = item("a", "AA")
        assertEquals(CacheReferenceSnapshot.PLAYING,
            build(listOf(a), active = listOf(a), playing = a).classifyItem("a").reason)
    }

    @Test fun unknown_item_is_not_found() {
        val s = build(emptyList())
        val c = s.classifyItem("ghost")
        assertEquals(CacheReferenceSnapshot.Kind.NONE, c.kind)
        assertEquals(CacheReferenceSnapshot.NOT_FOUND, c.reason)
        assertNull(s.contentKeyFor("ghost"))
    }
}
