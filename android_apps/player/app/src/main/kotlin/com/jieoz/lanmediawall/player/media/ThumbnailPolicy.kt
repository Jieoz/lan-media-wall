package com.jieoz.lanmediawall.player.media

/** Pure allocation + scheduling policy for controller thumbnail capture (§6.4). */
object ThumbnailPolicy {
    const val MAX_CAPTURE_ATTEMPTS = 3
    private const val NORMAL_INTERVAL_MS = 5_000L
    private const val LEGACY_VIDEO_INTERVAL_MS = 15_000L

    /**
     * Controller preview thumbs stay small (bandwidth + UI). Transition freeze
     * frames cover the full SurfaceView during single-VDEC rebuild (~200–400ms)
     * and must be near-fullscreen — a 320px fitCenter leaf still shows black.
     */
    const val CONTROLLER_THUMB_MAX_WIDTH = 320
    const val TRANSITION_FREEZE_MAX_WIDTH = 1280

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
     *   - visual item, no cache, below the bounded retry limit → [EXTRACT];
     *   - visual item, no cache, retry limit reached → [SUPPRESS];
     *   - audio/non-visual items never extract here.
     */
    fun decide(
        isVideo: Boolean,
        isImage: Boolean = false,
        hasCachedThumbnail: Boolean,
        attemptCount: Int,
    ): ThumbAction = when {
        hasCachedThumbnail -> ThumbAction.REUSE_CACHED
        !isVideo && !isImage -> ThumbAction.SUPPRESS
        attemptCount >= MAX_CAPTURE_ATTEMPTS -> ThumbAction.SUPPRESS
        else -> ThumbAction.EXTRACT
    }
}