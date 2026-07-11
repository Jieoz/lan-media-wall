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
}
