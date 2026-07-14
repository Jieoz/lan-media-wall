package com.jieoz.lanmediawall.player.cache

import com.jieoz.lanmediawall.player.net.Json
import com.jieoz.lanmediawall.player.net.asArrayOrNull
import com.jieoz.lanmediawall.player.net.asBoolOrNull
import com.jieoz.lanmediawall.player.net.asLongOrNull
import com.jieoz.lanmediawall.player.net.asString
import com.jieoz.lanmediawall.player.net.get
import java.security.MessageDigest

/**
 * Canonical semantic playlist hash — `group_playlist_hash_v1` (protocol §3.1).
 *
 * Byte-for-byte mirror of the Windows player's `cache_hash.py`. Two playlists
 * hash equal iff their *playback semantics* match: ordered items (url / sha256 /
 * duration_ms / per-item loop), plus playlist-level `sync` and `loop_mode`. It
 * EXCLUDES `playlist_id` and `push_id` so a controller can tell "same content,
 * different generation" from "divergent".
 *
 * The canonical string is a version-tagged, newline-delimited text form (no JSON
 * library dependence, so Python and Kotlin agree without number/key-order
 * footguns). `CacheHashTest.kt` pins the SAME hex as `test_cache_hash.py` against
 * the SAME fixture — that identity is the cross-language contract.
 */
object CacheHash {

    const val CANONICAL_VERSION = "lmw-playlist-hash-v1"

    private fun normBool(v: Boolean): String = if (v) "true" else "false"

    private fun normSha(v: String?): String =
        v?.trim()?.lowercase() ?: ""

    private fun normDuration(v: Long?): String =
        v?.toString() ?: ""

    private fun itemRecord(item: Json?): String {
        val url = item?.get("url").asString() ?: ""
        val sha = normSha(item?.get("sha256").asString())
        val dur = normDuration(item?.get("duration_ms").asLongOrNull())
        val loop = normBool(item?.get("loop").asBoolOrNull() ?: false)
        return "item\turl=$url\tsha256=$sha\tdur=$dur\tloop=$loop"
    }

    /** Build the canonical, cross-language-stable string for [playlist]. */
    fun canonicalString(playlist: Json?): String {
        val mode = LoopMode.resolve(playlist).wire
        val sync = normBool(playlist?.get("sync").asBoolOrNull() ?: true)
        val items = playlist?.get("items").asArrayOrNull() ?: emptyList()
        val sb = StringBuilder()
        sb.append(CANONICAL_VERSION).append('\n')
        sb.append("loop_mode=").append(mode).append('\n')
        sb.append("sync=").append(sync).append('\n')
        sb.append("count=").append(items.size).append('\n')
        for (it in items) {
            sb.append(itemRecord(it)).append('\n')
        }
        return sb.toString()
    }

    /** Lowercase sha256 hex of the canonical playlist string. */
    fun canonicalHash(playlist: Json?): String {
        val bytes = canonicalString(playlist).toByteArray(Charsets.UTF_8)
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) sb.append(String.format("%02x", b.toInt() and 0xff))
        return sb.toString()
    }
}
