package com.jieoz.lanmediawall.player.cache

import com.jieoz.lanmediawall.player.net.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MusicPlaylistTest {
    @Test fun `music playlist accepts only audio items and preserves revision`() {
        val playlist = MusicPlaylist.fromJson(Json.parse("""
            {"playlist_id":"music-dev1","revision":7,"items":[
              {"item_id":"song-a","type":"audio","name":"A.mp3","url":"http://x/a.mp3"},
              {"item_id":"song-b","type":"audio","name":"B.mp3","url":"http://x/b.mp3"}
            ]}
        """))
        assertEquals("music-dev1", playlist?.playlistId)
        assertEquals(7L, playlist?.revision)
        assertEquals(listOf("song-a", "song-b"), playlist?.items?.map { it.itemId })
    }

    @Test fun `visual media cannot enter the music playlist`() {
        assertNull(MusicPlaylist.fromJson(Json.parse("""
            {"playlist_id":"music-dev1","revision":1,"items":[
              {"item_id":"video-a","type":"video","url":"http://x/a.mp4"}
            ]}
        """)))
    }

    @Test fun `empty music playlist is a valid editable clear`() {
        val playlist = MusicPlaylist.fromJson(Json.parse(
            "{\"playlist_id\":\"music-dev1\",\"revision\":8,\"items\":[]}"))
        assertEquals(0, playlist?.items?.size)
    }
}
