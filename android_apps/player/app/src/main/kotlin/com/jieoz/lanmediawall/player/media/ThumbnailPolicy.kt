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
     * Root-performance rule (v1.14.8 restoration). The v1.14.7 regression was that
     * this used to return [SUPPRESS] for ANY actively-playing video, so a video
     * that just plays normally (the common case) NEVER produced a thumbnail — the
     * controller preview went permanently blank under MediaPlayer.
     *
     * The real constraint on the HiSilicon boxes is not "never while playing" but
     * "never open a SECOND long-lived / repeated decoder alongside the live one".
     * A [MediaMetadataRetriever] extraction is file-based, decode-independent, and
     * here it is bounded to exactly ONE brief open per item_id by:
     *   - the permanent per-item thumbnail cache ([hasCachedThumbnail] → REUSE), and
     *   - [alreadyAttempted] — we mark an item once we've opened the retriever for
     *     it (whether or not bytes came back), so a still-playing video is probed
     *     at most once, not every tick.
     * That one-shot-per-item bound is what upstream approved as safe. So:
     *   - cached thumbnail → always just re-sent ([REUSE_CACHED]);
     *   - video, no cache, not yet attempted → [EXTRACT] once;
     *   - video, no cache, already attempted this session → [SUPPRESS] (no repeat open);
     *   - non-video items never extract here (image stills are drawn by the controller).
     */
    fun decide(isVideo: Boolean, hasCachedThumbnail: Boolean, alreadyAttempted: Boolean): ThumbAction {
        if (hasCachedThumbnail) return ThumbAction.REUSE_CACHED
        if (!isVideo) return ThumbAction.SUPPRESS
        if (alreadyAttempted) return ThumbAction.SUPPRESS
        return ThumbAction.EXTRACT
    }
}