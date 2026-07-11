package com.jieoz.lanmediawall.player.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ThumbnailPolicyTest {
    @Test fun `1080p source captures directly at bounded dimensions`() {
        val size = ThumbnailPolicy.captureSize(1920, 1080, 320)
        assertNotNull(size)
        val captured = size!!
        assertEquals(320, captured.width)
        assertEquals(180, captured.height)
        assertTrue(captured.argbBytes <= 320 * 180 * 4)
    }

    @Test fun `small source is never enlarged`() {
        assertEquals(ThumbnailPolicy.Size(240, 135), ThumbnailPolicy.captureSize(240, 135, 320))
    }

    @Test fun `invalid dimensions suppress capture`() {
        assertEquals(null, ThumbnailPolicy.captureSize(0, 1080, 320))
        assertEquals(null, ThumbnailPolicy.captureSize(1920, 1080, 0))
    }

    @Test fun `legacy video keeps thumbnails but captures at a conservative cadence`() {
        assertEquals(15_000L, ThumbnailPolicy.intervalMs(androidSdk = 19, playingVideo = true))
    }

    @Test fun `modern or non-video playback keeps the normal thumbnail cadence`() {
        assertEquals(5_000L, ThumbnailPolicy.intervalMs(androidSdk = 21, playingVideo = true))
        assertEquals(5_000L, ThumbnailPolicy.intervalMs(androidSdk = 19, playingVideo = false))
    }

    @Test fun `capture is skipped when playback crosses an item boundary`() {
        assertTrue(ThumbnailPolicy.canCapture("item-a", "item-a"))
        assertEquals(false, ThumbnailPolicy.canCapture("item-a", "item-b"))
        assertEquals(false, ThumbnailPolicy.canCapture(null, null))
    }
}
