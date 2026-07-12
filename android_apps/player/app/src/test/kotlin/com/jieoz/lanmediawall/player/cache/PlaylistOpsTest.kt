package com.jieoz.lanmediawall.player.cache

import com.jieoz.lanmediawall.player.net.Json
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * §6.3 replace-vs-append contract. Locks the separation of the ordered active
 * playlist from the cache inventory: the field bug was that single-item pushes
 * collapsed the sequence and prev/next both landed on the last item.
 */
class PlaylistOpsTest {

    private fun item(id: String, url: String = "http://x/$id.mp4"): MediaItem =
        MediaItem.fromJson(Json.parse("""{"item_id":"$id","url":"$url","type":"video"}"""))!!

    private fun playlist(id: String, items: List<MediaItem>): Playlist =
        Playlist(
            playlistId = id, groupId = null, sync = true, loop = false,
            items = items,
            raw = Json.parse("""{"playlist_id":"$id","items":[]}"""),
        ).withItems(items)

    @Test fun `push A then append B yields A,B`() {
        val a = item("a")
        val b = item("b")
        val step1 = PlaylistOps.merge(emptyList(), 0, listOf(a), PlaylistOps.Mode.REPLACE)
        assertEquals(listOf("a"), step1.items.map { it.itemId })
        val step2 = PlaylistOps.merge(step1.items, step1.index, listOf(b), PlaylistOps.Mode.APPEND)
        assertEquals(listOf("a", "b"), step2.items.map { it.itemId })
    }

    @Test fun `append dedupes by item_id and updates in place`() {
        val a = item("a")
        val b = item("b")
        val a2 = item("a", url = "http://x/a-v2.mp4")
        val merged = PlaylistOps.merge(listOf(a, b), 0, listOf(a2), PlaylistOps.Mode.APPEND)
        assertEquals(listOf("a", "b"), merged.items.map { it.itemId }) // no dupe row
        assertEquals("http://x/a-v2.mp4", merged.items[0].url)          // updated in place
    }

    @Test fun `replace restarts sequence at head`() {
        val a = item("a")
        val b = item("b")
        val c = item("c")
        val merged = PlaylistOps.merge(listOf(a, b), 1, listOf(c), PlaylistOps.Mode.REPLACE)
        assertEquals(listOf("c"), merged.items.map { it.itemId })
        assertEquals(0, merged.index)
    }

    @Test fun `append preserves the current index on the same item`() {
        val a = item("a")
        val b = item("b")
        val c = item("c")
        // currently on b (index 1); append c
        val merged = PlaylistOps.merge(listOf(a, b), 1, listOf(c), PlaylistOps.Mode.APPEND)
        assertEquals(listOf("a", "b", "c"), merged.items.map { it.itemId })
        assertEquals(1, merged.index) // still pointing at b
    }

    @Test fun `append onto empty behaves like replace`() {
        val a = item("a")
        val merged = PlaylistOps.merge(emptyList(), 0, listOf(a), PlaylistOps.Mode.APPEND)
        assertEquals(listOf("a"), merged.items.map { it.itemId })
        assertEquals(0, merged.index)
    }

    @Test fun `withItems rebuilds raw so it round-trips through fromJson`() {
        val a = item("a")
        val b = item("b")
        val pl = playlist("pl-1", listOf(a))
        val appended = pl.withItems(listOf(a, b))
        val reparsed = Playlist.fromJson(appended.raw)!!
        assertEquals(listOf("a", "b"), reparsed.items.map { it.itemId })
        assertEquals("pl-1", reparsed.playlistId)
    }

    @Test fun `mode parse defaults to replace for unknown or absent`() {
        assertEquals(PlaylistOps.Mode.REPLACE, PlaylistOps.Mode.parse(null))
        assertEquals(PlaylistOps.Mode.REPLACE, PlaylistOps.Mode.parse(""))
        assertEquals(PlaylistOps.Mode.REPLACE, PlaylistOps.Mode.parse("bogus"))
        assertEquals(PlaylistOps.Mode.APPEND, PlaylistOps.Mode.parse("append"))
        assertEquals(PlaylistOps.Mode.APPEND, PlaylistOps.Mode.parse("APPEND"))
    }

    @Test fun `two distinct items make prev-next reach distinct targets`() {
        // Regression for "cache 2/2 ready but prev/next both play last item":
        // after A + append B, index wrapping must reach two DIFFERENT ids.
        val a = item("a")
        val b = item("b")
        val merged = PlaylistOps.merge(listOf(a), 0, listOf(b), PlaylistOps.Mode.APPEND)
        val size = merged.items.size
        assertEquals(2, size)
        val next = ((0 + 1) % size + size) % size
        val prev = ((0 - 1) % size + size) % size
        assertEquals("b", merged.items[next].itemId)
        assertEquals("b", merged.items[prev].itemId) // wraps to b from a either way
        // and from b, next/prev reach a — distinct, not collapsed.
        assertEquals("a", merged.items[((1 + 1) % size + size) % size].itemId)
    }
}
