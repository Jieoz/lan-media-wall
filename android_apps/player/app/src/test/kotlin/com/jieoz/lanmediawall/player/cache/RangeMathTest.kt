package com.jieoz.lanmediawall.player.cache

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Resumable-download Range math (protocol_spec §6), mirroring
 * windows_player/downloader.py. Pure logic — no network.
 */
class RangeMathTest {

    @Test
    fun range_header_fresh_is_null() {
        assertNull(RangeMath.rangeHeader(0))
        assertNull(RangeMath.rangeHeader(-5))
    }

    @Test
    fun range_header_resume() {
        assertEquals("bytes=1024-", RangeMath.rangeHeader(1024))
    }

    @Test
    fun percent_math() {
        assertEquals(0, RangeMath.percent(0, 100))
        assertEquals(45, RangeMath.percent(45, 100))
        assertEquals(100, RangeMath.percent(100, 100))
        assertEquals(0, RangeMath.percent(50, null))
        assertEquals(0, RangeMath.percent(50, 0))
    }

    @Test
    fun expected_total_206_with_content_range() {
        assertEquals(12345L, RangeMath.expectedTotal(100, 206, 99, 12345))
    }

    @Test
    fun expected_total_206_content_length_only() {
        // existing 100 + remaining 200 = 300
        assertEquals(300L, RangeMath.expectedTotal(100, 206, 200, null))
    }

    @Test
    fun expected_total_200_full_body() {
        assertEquals(500L, RangeMath.expectedTotal(100, 200, 500, null))
    }

    @Test
    fun parse_content_range_total() {
        assertEquals(12345L, RangeMath.parseContentRangeTotal("bytes 0-99/12345"))
        assertNull(RangeMath.parseContentRangeTotal("bytes 0-99/*"))
        assertNull(RangeMath.parseContentRangeTotal(null))
        assertNull(RangeMath.parseContentRangeTotal(""))
    }

    @Test
    fun cache_entry_status_rendering() {
        val e = CacheEntry("a1")
        assertEquals("pending", e.statusValue())
        e.state = "downloading"; e.progress = 45
        assertEquals("downloading:45%", e.statusValue())
        e.state = "verifying"
        assertEquals("verifying", e.statusValue())
        e.state = "ready"
        assertEquals("ready", e.statusValue())
        e.state = "error"; e.error = "sha256-mismatch"
        assertEquals("error:sha256-mismatch", e.statusValue())
    }
}
