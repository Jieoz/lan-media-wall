package com.jieoz.lanmediawall.player.media

/** Pure allocation policy for TextureView thumbnail capture. */
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
}