package com.jieoz.lanmediawall.player.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * §hardware-decode: pure classification policy for ExoPlayer video decoder
 * selection on the QZX_C1 / HiSilicon boxes. Android MediaCodecInfo is awkward to
 * instantiate in a JVM unit test, so the DECISION lives in [VideoCodecPolicy]
 * (pure name/flag helpers) and MediaCodecSelector just feeds it real codec data.
 *
 * Requirement: NEVER silently fall back to a software video decoder on the
 * target. Known software codecs (OMX.google.*, c2.android.*) and API-reported
 * software-only codecs are excluded; if nothing hardware remains, selection
 * fails explicitly rather than quietly using software.
 */
class VideoCodecPolicyTest {

    @Test
    fun google_omx_is_software() {
        assertFalse(VideoCodecPolicy.isHardware("OMX.google.h264.decoder", softwareOnlyFlag = null))
    }

    @Test
    fun c2_android_is_software() {
        assertFalse(VideoCodecPolicy.isHardware("c2.android.avc.decoder", softwareOnlyFlag = null))
        assertFalse(VideoCodecPolicy.isHardware("C2.Android.Avc.Decoder", softwareOnlyFlag = null))
    }

    @Test
    fun api_software_only_flag_wins_even_for_vendor_name() {
        // If the platform (API 29+) says softwareOnly, trust it regardless of name.
        assertFalse(VideoCodecPolicy.isHardware("OMX.hisi.video.decoder", softwareOnlyFlag = true))
    }

    @Test
    fun hisi_vendor_decoder_is_hardware() {
        assertTrue(VideoCodecPolicy.isHardware("OMX.hisi.video.decoder.avc", softwareOnlyFlag = null))
        assertTrue(VideoCodecPolicy.isHardware("OMX.hisi.video.decoder.avc", softwareOnlyFlag = false))
    }

    @Test
    fun other_vendor_decoder_is_hardware_when_not_flagged_software() {
        assertTrue(VideoCodecPolicy.isHardware("OMX.qcom.video.decoder.avc", softwareOnlyFlag = null))
    }

    @Test
    fun classify_label_matches_decision() {
        assertEquals("hardware", VideoCodecPolicy.classify("OMX.hisi.video.decoder.avc", null))
        assertEquals("software", VideoCodecPolicy.classify("OMX.google.h264.decoder", null))
        assertEquals("software", VideoCodecPolicy.classify("c2.android.hevc.decoder", null))
    }

    @Test
    fun filter_keeps_only_hardware_and_reports_when_none() {
        val all = listOf(
            "OMX.google.h264.decoder" to null,
            "c2.android.avc.decoder" to null,
            "OMX.hisi.video.decoder.avc" to null,
        )
        val hw = VideoCodecPolicy.hardwareOnly(all)
        assertEquals(listOf("OMX.hisi.video.decoder.avc"), hw)

        val noneHw = listOf(
            "OMX.google.h264.decoder" to null,
            "c2.android.avc.decoder" to null,
        )
        assertTrue(VideoCodecPolicy.hardwareOnly(noneHw).isEmpty())
    }
}
