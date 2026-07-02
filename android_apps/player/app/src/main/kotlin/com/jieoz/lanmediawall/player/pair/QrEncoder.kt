package com.jieoz.lanmediawall.player.pair

import android.graphics.Bitmap
import android.graphics.Color
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter

/**
 * QR **encoder** — protocol_spec §1 (configuration reversal). The被控端 (TV box)
 * has no camera/touch, so it no longer *scans*; instead it **displays** its own
 * enrollment QR on the first-boot / idle screen and the phone遥控端 scans it.
 *
 * Built on ZXing `core` (Apache-2.0, pure Java → compiles + runs on API 19). The
 * old decode path (CameraX + [QrDecoder]) was deleted with the camera stack.
 *
 * The encoded text is an [PairUri] (`lmw://pair?…`) pointing at THIS device as
 * the coordinator (its LAN IP + p2p port + group + device_id), so the existing
 * phone-side [PairUri.parse] consumes it unchanged.
 */
object QrEncoder {

    /**
     * Render [text] as a square QR [Bitmap] of [sizePx]×[sizePx] (ARGB_8888,
     * black modules on white). Returns null if encoding fails (never expected
     * for our short ASCII URIs, but we fail soft so the UI just hides the QR).
     */
    fun encodeBitmap(text: String, sizePx: Int = 512): Bitmap? {
        return try {
            val hints = mapOf(
                EncodeHintType.MARGIN to 1,
                EncodeHintType.CHARACTER_SET to "UTF-8",
            )
            val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, sizePx, sizePx, hints)
            val w = matrix.width
            val h = matrix.height
            val pixels = IntArray(w * h)
            for (y in 0 until h) {
                val base = y * w
                for (x in 0 until w) {
                    pixels[base + x] = if (matrix.get(x, y)) Color.BLACK else Color.WHITE
                }
            }
            Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply {
                setPixels(pixels, 0, w, 0, 0, w, h)
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Build the enrollment URI this device advertises (§1 + §15.1). Points the
     * phone at THIS box as an `open`-mode p2p coordinator: `host=<ip>` `port=<p>`
     * `group=<gid>` `id=<device_id>` `name=<device_name>`. All values are
     * URL-encoded so a Chinese device name survives. Unknown params (`id`,`name`)
     * are ignored by older parsers (forward-compatible, §15.1).
     */
    fun buildEnrollUri(
        ip: String,
        port: Int,
        group: String,
        deviceId: String,
        deviceName: String,
    ): String {
        val q = StringBuilder()
        q.append("host=").append(enc(ip))
        q.append("&port=").append(port)
        q.append("&group=").append(enc(group))
        q.append("&id=").append(enc(deviceId))
        q.append("&name=").append(enc(deviceName))
        q.append("&mode=open")
        return "${PairUri.SCHEME}://${PairUri.PAIR_HOST}?$q"
    }

    private fun enc(s: String): String = try {
        java.net.URLEncoder.encode(s, "UTF-8")
    } catch (_: Exception) {
        s
    }
}
