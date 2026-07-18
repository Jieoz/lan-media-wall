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

    // --- v1.14.8 one-shot-per-item restoration ---------------------------
    // The v1.14.7 regression: decide() returned SUPPRESS for any actively-playing
    // video, so a normally-playing video NEVER produced a thumbnail. The fix is a
    // one-shot bounded by an attempt guard + permanent cache, not a playback ban.

    @Test fun `a video with no cache extracts once when not yet attempted`() {
        assertEquals(
            ThumbnailPolicy.ThumbAction.EXTRACT,
            ThumbnailPolicy.decide(isVideo = true, hasCachedThumbnail = false, alreadyAttempted = false),
        )
    }

    @Test fun `a video already attempted this session is suppressed not re-extracted`() {
        // The one-shot bound: at most one MMR open per item, so a still-playing
        // video is probed once, never every tick.
        assertEquals(
            ThumbnailPolicy.ThumbAction.SUPPRESS,
            ThumbnailPolicy.decide(isVideo = true, hasCachedThumbnail = false, alreadyAttempted = true),
        )
    }

    @Test fun `a cached thumbnail is always reused regardless of attempt state`() {
        assertEquals(
            ThumbnailPolicy.ThumbAction.REUSE_CACHED,
            ThumbnailPolicy.decide(isVideo = true, hasCachedThumbnail = true, alreadyAttempted = false),
        )
        assertEquals(
            ThumbnailPolicy.ThumbAction.REUSE_CACHED,
            ThumbnailPolicy.decide(isVideo = true, hasCachedThumbnail = true, alreadyAttempted = true),
        )
    }

    @Test fun `non-video items never extract`() {
        assertEquals(
            ThumbnailPolicy.ThumbAction.SUPPRESS,
            ThumbnailPolicy.decide(isVideo = false, hasCachedThumbnail = false, alreadyAttempted = false),
        )
    }

    // --- P0 seamless freeze frame size --------------------------------
    // Transition freezes must be near-fullscreen (1280) so centerCrop covers
    // the SurfaceView; the 320 controller thumb is intentionally separate.

    @Test fun `transition freeze capture is near-fullscreen not controller-thumb`() {
        val freeze = ThumbnailPolicy.captureSize(
            1920, 1080, ThumbnailPolicy.TRANSITION_FREEZE_MAX_WIDTH,
        )
        assertNotNull(freeze)
        assertEquals(1280, freeze!!.width)
        assertEquals(720, freeze.height)
        val thumb = ThumbnailPolicy.captureSize(
            1920, 1080, ThumbnailPolicy.CONTROLLER_THUMB_MAX_WIDTH,
        )
        assertNotNull(thumb)
        assertEquals(320, thumb!!.width)
        assertTrue(freeze.width > thumb.width)
    }
}
