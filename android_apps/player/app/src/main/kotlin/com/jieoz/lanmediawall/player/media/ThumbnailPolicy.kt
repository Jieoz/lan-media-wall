package com.jieoz.lanmediawall.player.media

/** Pure allocation + scheduling policy for controller thumbnail capture (§6.4). */
object ThumbnailPolicy {
    private const val NORMAL_INTERVAL_MS = 5_000L
    private const val LEGACY_VIDEO_INTERVAL_MS = 15_000L

    data class Size(val width: Int, val height: Int) {
        val argbBytes: Long get() = width.toLong() * height * 4
    }

    fun captureSize(sourceWidth: Int, sourceHeight: Int, maxWidth: Int): Size? {
        if (sourceWidth <= 0 || sourceHeight <= 0 || maxWidth <= 0) return null
        val width = minOf(sourceWidth, maxWidth)
        val height = (sourceHeight.toLong() * width / sourceWidth).toInt().coerceAtLeast(1)
        return Size(width, height)
    }

    /** Keep previews on KitKat, but avoid a TextureView readback every five seconds
     * while the legacy video pipeline is presenting a full-HD stream. */
    fun intervalMs(androidSdk: Int, playingVideo: Boolean): Long =
        if (androidSdk <= 19 && playingVideo) LEGACY_VIDEO_INTERVAL_MS else NORMAL_INTERVAL_MS

    fun canCapture(expectedItemId: String?, currentItemId: String?): Boolean =
        expectedItemId != null && expectedItemId == currentItemId

    /** What the thumbnail loop is allowed to do this tick (root-performance addendum). */
    enum class ThumbAction {
        /** Run a one-shot MediaMetadataRetriever extraction (safe: no active decoder). */
        EXTRACT,
        /** Send the already-cached thumbnail bytes; never touch a decoder. */
        REUSE_CACHED,
        /** Do nothing this tick. */
        SUPPRESS,
    }

    /**
     * Root-performance rule (verified addendum): while a video is *actively playing*
     * on these HiSilicon boxes, the loop must NEVER open a MediaMetadataRetriever —
     * that spins up a second VDEC context alongside ExoPlayer's live decoder and
     * black-screens/overloads the box. So:
     *   - a cached thumbnail is always just re-sent ([REUSE_CACHED]);
     *   - live [EXTRACT] is permitted ONLY when the video is not actively playing
     *     (paused / buffering / idle / not-yet-started), i.e. no live decoder to
     *     collide with, and only when nothing is cached yet;
     *   - during active playback with no cache we [SUPPRESS] rather than extract.
     * Non-video items never extract here (image stills are drawn by the controller).
     */
    fun decide(isVideo: Boolean, videoActivePlayback: Boolean, hasCachedThumbnail: Boolean): ThumbAction {
        if (hasCachedThumbnail) return ThumbAction.REUSE_CACHED
        if (!isVideo) return ThumbAction.SUPPRESS
        if (videoActivePlayback) return ThumbAction.SUPPRESS
        return ThumbAction.EXTRACT
    }
}