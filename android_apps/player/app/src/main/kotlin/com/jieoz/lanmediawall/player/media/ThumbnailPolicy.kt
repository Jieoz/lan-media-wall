package com.jieoz.lanmediawall.player.media

/** Pure allocation policy for TextureView thumbnail capture. */
object ThumbnailPolicy {
    data class Size(val width: Int, val height: Int) {
        val argbBytes: Long get() = width.toLong() * height * 4
    }

    fun captureSize(sourceWidth: Int, sourceHeight: Int, maxWidth: Int): Size? {
        if (sourceWidth <= 0 || sourceHeight <= 0 || maxWidth <= 0) return null
        val width = minOf(sourceWidth, maxWidth)
        val height = (sourceHeight.toLong() * width / sourceWidth).toInt().coerceAtLeast(1)
        return Size(width, height)
    }
}