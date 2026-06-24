package com.jieoz.lanmediawall.player.pair

import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.EncodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.MultiFormatReader
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeWriter

/**
 * QR decode/encode entry points built on ZXing `core` (Apache-2.0) — §15.2.
 *
 * This is the **pure, dependency-light** seam between the camera and the
 * [PairUri] parser. The on-device scanner ([CameraPairingScanner]) feeds raw
 * luminance frames here; this class turns a frame (or a synthetic test grid)
 * into the decoded text, which the caller hands to [PairUri.parse]. No Android
 * types are referenced, so the decode path is unit-testable on the JVM via the
 * [encodeToLuminance] round-trip helper.
 */
object QrDecoder {

    /**
     * Decode a single QR/barcode from a grayscale luminance buffer.
     *
     * @param luminance one byte per pixel, row-major, length == width*height.
     * @return the decoded text, or null if no code was found in the frame.
     */
    fun decodeLuminance(luminance: ByteArray, width: Int, height: Int): String? {
        if (width <= 0 || height <= 0) return null
        if (luminance.size < width * height) return null
        val source: LuminanceSource = object : LuminanceSource(width, height) {
            override fun getRow(y: Int, row: ByteArray?): ByteArray {
                val out = if (row != null && row.size >= width) row else ByteArray(width)
                System.arraycopy(luminance, y * width, out, 0, width)
                return out
            }

            override fun getMatrix(): ByteArray = luminance
        }
        return decodeSource(source)
    }

    /**
     * Decode from packed 32-bit ARGB pixels (e.g. a Bitmap's getPixels output).
     * Uses ZXing's [RGBLuminanceSource], which derives luminance internally.
     */
    fun decodeArgb(pixels: IntArray, width: Int, height: Int): String? {
        if (width <= 0 || height <= 0 || pixels.size < width * height) return null
        return decodeSource(RGBLuminanceSource(width, height, pixels))
    }

    private fun decodeSource(source: LuminanceSource): String? {
        val bitmap = BinaryBitmap(HybridBinarizer(source))
        val reader = MultiFormatReader()
        val hints = mapOf(
            DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
            DecodeHintType.TRY_HARDER to true,
        )
        return try {
            reader.decode(bitmap, hints).text
        } catch (e: Exception) {
            null // NotFoundException / ChecksumException / FormatException
        } finally {
            reader.reset()
        }
    }

    /**
     * Encode [text] as a QR code rendered into a luminance buffer (0x00 = black
     * module, 0xFF = white). Primarily a test helper so [decodeLuminance] can be
     * exercised end-to-end on the JVM without a camera; also usable to render a
     * pairing QR on-device if the player ever needs to *show* one.
     *
     * @return Triple(luminance, width, height).
     */
    fun encodeToLuminance(text: String, size: Int = 256): Triple<ByteArray, Int, Int> {
        val hints = mapOf(EncodeHintType.MARGIN to 2)
        val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, hints)
        val w = matrix.width
        val h = matrix.height
        val lum = ByteArray(w * h)
        for (y in 0 until h) {
            val base = y * w
            for (x in 0 until w) {
                // matrix.get == true → dark module → luminance 0; else white 255
                lum[base + x] = if (matrix.get(x, y)) 0x00 else 0xFF.toByte()
            }
        }
        return Triple(lum, w, h)
    }
}
