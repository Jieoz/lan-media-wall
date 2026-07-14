package com.jieoz.lanmediawall.player.cache

import com.jieoz.lanmediawall.player.net.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest

/**
 * Cross-language canonical playlist hash contract (protocol §3.1).
 *
 * The [FIXTURE_JSON] below is byte-identical to
 * `windows_player/tests/fixtures/playlist_canonical.json`; [EXPECTED_HEX] is the
 * SAME pinned value asserted by `test_cache_hash.py`. If the canonical rule
 * changes, BOTH suites must change together — that is the whole contract.
 */
class CacheHashTest {

    private fun parse(s: String): Json = Json.parse(s)

    @Test
    fun canonical_string_shape() {
        val canon = CacheHash.canonicalString(parse(FIXTURE_JSON))
        assertTrue(canon.startsWith("lmw-playlist-hash-v1\n"))
        assertTrue(canon.contains("loop_mode=all"))
        assertTrue(canon.contains("sync=true"))
        // playlist_id / push_id never leak into the canonical form
        assertTrue(!canon.contains("pl-frozen-001"))
        assertTrue(!canon.contains("push-should-not-count"))
    }

    @Test
    fun hash_is_sha256_of_canonical() {
        val pl = parse(FIXTURE_JSON)
        val canon = CacheHash.canonicalString(pl)
        val d = MessageDigest.getInstance("SHA-256")
            .digest(canon.toByteArray(Charsets.UTF_8))
        val hex = d.joinToString("") { String.format("%02x", it.toInt() and 0xff) }
        assertEquals(hex, CacheHash.canonicalHash(pl))
    }

    @Test
    fun hash_matches_pinned_cross_language_value() {
        assertEquals(EXPECTED_HEX, CacheHash.canonicalHash(parse(FIXTURE_JSON)))
    }

    @Test
    fun playlist_id_and_push_id_do_not_affect_hash() {
        val base = CacheHash.canonicalHash(parse(FIXTURE_JSON))
        val mutated = FIXTURE_JSON
            .replace("pl-frozen-001", "totally-different-id")
            .replace("push-should-not-count", "another-push")
        assertEquals(base, CacheHash.canonicalHash(parse(mutated)))
    }

    @Test
    fun item_order_changes_hash() {
        val base = CacheHash.canonicalHash(parse(FIXTURE_JSON))
        val reversed = parse(FIXTURE_JSON) as Json.Obj
        val items = (reversed.entries["items"] as Json.Arr).items.reversed()
        val rebuilt = LinkedHashMap(reversed.entries)
        rebuilt["items"] = Json.Arr(items)
        assertNotEquals(base, CacheHash.canonicalHash(Json.Obj(rebuilt)))
    }

    @Test
    fun loop_mode_change_changes_hash() {
        val base = CacheHash.canonicalHash(parse(FIXTURE_JSON))
        val changed = FIXTURE_JSON.replace("\"loop_mode\": \"all\"",
            "\"loop_mode\": \"none\"")
        assertNotEquals(base, CacheHash.canonicalHash(parse(changed)))
    }

    @Test
    fun legacy_loop_bool_folds_into_loop_mode() {
        val a = parse("""{"sync":true,"loop":true,"items":[
            {"url":"http://h/x.mp4","sha256":"AA","duration_ms":1000}]}""")
        val b = parse("""{"sync":true,"loop_mode":"all","items":[
            {"url":"http://h/x.mp4","sha256":"aa","duration_ms":1000}]}""")
        assertEquals(CacheHash.canonicalHash(a), CacheHash.canonicalHash(b))
    }

    @Test
    fun missing_duration_and_sha_normalize() {
        val pl = parse("""{"sync":false,"loop_mode":"none","items":[
            {"url":"http://h/y.mp4"}]}""")
        assertEquals(64, CacheHash.canonicalHash(pl).length)
    }

    @Test
    fun empty_playlist_is_stable() {
        val pl = parse("""{"sync":true,"loop_mode":"none","items":[]}""")
        assertEquals(64, CacheHash.canonicalHash(pl).length)
    }

    companion object {
        const val EXPECTED_HEX =
            "9a5fe39de03984139f34a1127fb7ba9edfbdd6fce582d3417e3e550a1ffec072"

        // byte-identical to windows_player/tests/fixtures/playlist_canonical.json
        val FIXTURE_JSON = """
{
  "type": "playlist",
  "playlist_id": "pl-frozen-001",
  "push_id": "push-should-not-count",
  "group_id": "lobby",
  "sync": true,
  "loop": true,
  "loop_mode": "all",
  "items": [
    {
      "item_id": "item-a",
      "type": "video",
      "name": "opening.mp4",
      "url": "http://media.example/opening.mp4",
      "size": 10485760,
      "sha256": "AA11BB22CC33DD44EE55FF6600112233445566778899AABBCCDDEEFF0011AABB",
      "duration_ms": 30000,
      "loop": false
    },
    {
      "item_id": "item-b",
      "type": "image",
      "name": "poster.png",
      "url": "http://media.example/poster.png",
      "size": 204800,
      "sha256": "ff00ee11dd22cc33bb44aa5566778899001122334455667788990011223344ff",
      "duration_ms": 8000,
      "loop": true
    }
  ]
}
""".trimIndent()
    }
}
