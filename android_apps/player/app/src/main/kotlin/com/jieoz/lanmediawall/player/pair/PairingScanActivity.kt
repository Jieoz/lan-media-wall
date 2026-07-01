package com.jieoz.lanmediawall.player.pair

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import com.jieoz.lanmediawall.player.R
import com.jieoz.lanmediawall.player.databinding.ActivityPairingScanBinding
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * §15 scan-to-pair camera screen. Opens the back camera with CameraX
 * ([Preview] + [ImageAnalysis]), feeds each frame's luminance plane to
 * [QrDecoder], and hands any decoded text to [PairUri.parse]. On the first
 * frame that yields a well-formed `lmw://pair?…` URI it returns that raw URI to
 * the caller ([EXTRA_PAIR_URI] under `RESULT_OK`) and finishes; malformed or
 * non-pairing codes are ignored so scanning continues.
 *
 * The operator types NOTHING — this is the headline免手输 feature (§15). The
 * caller ([com.jieoz.lanmediawall.player.SettingsActivity]) applies the URI to
 * [com.jieoz.lanmediawall.player.Settings.applyPairing] and re-fills its form.
 */
class PairingScanActivity : AppCompatActivity() {

    private lateinit var binding: ActivityPairingScanBinding
    private lateinit var analysisExecutor: ExecutorService

    /** Latches on the first accepted result so we finish exactly once. */
    private val done = AtomicBoolean(false)

    private val requestCamera =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) {
                startCamera()
            } else {
                Toast.makeText(this, R.string.scan_pair_denied, Toast.LENGTH_SHORT).show()
                finish()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityPairingScanBinding.inflate(layoutInflater)
        setContentView(binding.root)
        analysisExecutor = Executors.newSingleThreadExecutor()

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            == PackageManager.PERMISSION_GRANTED
        ) {
            startCamera()
        } else {
            requestCamera.launch(Manifest.permission.CAMERA)
        }
    }

    private fun startCamera() {
        val providerFuture = ProcessCameraProvider.getInstance(this)
        providerFuture.addListener({
            val provider = try {
                providerFuture.get()
            } catch (e: Exception) {
                Log.e(TAG, "CameraProvider unavailable", e)
                finish()
                return@addListener
            }

            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(binding.previewView.surfaceProvider)
            }

            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { it.setAnalyzer(analysisExecutor, ::analyze) }

            try {
                provider.unbindAll()
                provider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview,
                    analysis,
                )
            } catch (e: Exception) {
                Log.e(TAG, "bindToLifecycle failed", e)
                finish()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    /**
     * ImageAnalysis callback. Copies the Y (luma) plane into a tight grayscale
     * buffer (row-stride may exceed the image width) and hands it to
     * [QrDecoder.decodeLuminance]. A decoded string is only accepted if
     * [PairUri.parse] recognises it as a pairing URI.
     */
    private fun analyze(image: ImageProxy) {
        try {
            if (done.get()) return
            val luminance = extractLuminance(image) ?: return
            val text = QrDecoder.decodeLuminance(luminance, image.width, image.height)
                ?: return
            val pairUri = PairUri.parse(text) ?: return
            if (done.compareAndSet(false, true)) {
                // Return the original scanned URI text; the caller re-parses +
                // applies it (single source of truth = PairUri.parse).
                runOnUiThread { finishWithResult(text) }
            }
        } finally {
            image.close()
        }
    }

    private fun finishWithResult(rawUri: String) {
        val data = android.content.Intent().putExtra(EXTRA_PAIR_URI, rawUri)
        setResult(RESULT_OK, data)
        finish()
    }

    /** Pack the Y plane into a width*height byte array, stripping row padding. */
    private fun extractLuminance(image: ImageProxy): ByteArray? {
        val plane = image.planes.getOrNull(0) ?: return null
        val width = image.width
        val height = image.height
        if (width <= 0 || height <= 0) return null
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val out = ByteArray(width * height)
        if (pixelStride == 1 && rowStride == width) {
            // Fast path: tightly packed — copy the whole plane in one shot.
            buffer.get(out, 0, minOf(out.size, buffer.remaining()))
            return out
        }
        val rowBytes = ByteArray(rowStride)
        var outPos = 0
        for (row in 0 until height) {
            val remaining = buffer.remaining()
            if (remaining <= 0) break
            val toRead = minOf(rowStride, remaining)
            buffer.get(rowBytes, 0, toRead)
            var col = 0
            var i = 0
            while (col < width && i < toRead) {
                out[outPos++] = rowBytes[i]
                i += pixelStride
                col++
            }
        }
        return out
    }

    override fun onDestroy() {
        super.onDestroy()
        if (::analysisExecutor.isInitialized) analysisExecutor.shutdown()
    }

    companion object {
        private const val TAG = "PairingScanActivity"

        /** RESULT_OK extra: the raw scanned `lmw://pair?…` URI string. */
        const val EXTRA_PAIR_URI = "pair_uri"
    }
}
