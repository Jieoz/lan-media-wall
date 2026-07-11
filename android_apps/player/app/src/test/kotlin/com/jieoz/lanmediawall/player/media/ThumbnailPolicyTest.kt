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

    // --- root-performance addendum: no live extraction during active playback ---

    @Test fun `active video playback can never trigger live frame extraction`() {
        // The decisive invariant: for a video that is actively playing, the loop
        // must NEVER extract (which would open a second HiSilicon decoder). It may
        // only reuse a cached thumbnail or suppress the refresh.
        assertEquals(
            ThumbnailPolicy.ThumbAction.SUPPRESS,
            ThumbnailPolicy.decide(isVideo = true, videoActivePlayback = true, hasCachedThumbnail = false),
        )
        assertEquals(
            ThumbnailPolicy.ThumbAction.REUSE_CACHED,
            ThumbnailPolicy.decide(isVideo = true, videoActivePlayback = true, hasCachedThumbnail = true),
        )
    }

    @Test fun `exhaustive - decide never yields EXTRACT while video is actively playing`() {
        for (hasCached in listOf(false, true)) {
            val action = ThumbnailPolicy.decide(
                isVideo = true, videoActivePlayback = true, hasCachedThumbnail = hasCached,
            )
            assertTrue(
                "video playback must not extract (hasCached=$hasCached)",
                action != ThumbnailPolicy.ThumbAction.EXTRACT,
            )
        }
    }

    @Test fun `a paused or not-yet-playing video may extract once`() {
        assertEquals(
            ThumbnailPolicy.ThumbAction.EXTRACT,
            ThumbnailPolicy.decide(isVideo = true, videoActivePlayback = false, hasCachedThumbnail = false),
        )
    }

    @Test fun `a cached thumbnail is always reused regardless of state`() {
        assertEquals(
            ThumbnailPolicy.ThumbAction.REUSE_CACHED,
            ThumbnailPolicy.decide(isVideo = true, videoActivePlayback = false, hasCachedThumbnail = true),
        )
    }
}
