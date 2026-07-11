package com.jieoz.lanmediawall.player.media

/**
 * §hardware-decode: pure policy deciding whether a video decoder is a **hardware**
 * decoder, so ExoPlayer's MediaCodecSelector can exclude software video codecs on
 * the QZX_C1 / HiSilicon boxes. On these boxes a software (OMX.google.* /
 * c2.android.*) fallback either black-screens or overloads the little cores; we
 * MUST fail loudly instead of silently decoding in software (see PlayerController).
 *
 * Kept name/flag-only so it is unit-testable without a real MediaCodecInfo (which
 * is impractical to construct in a JVM test). The Android glue passes the codec
 * name and, where the API exposes it (29+ `isSoftwareOnly`), the flag.
 */
object VideoCodecPolicy {

    /** Name prefixes the platform uses for its bundled SOFTWARE video codecs. */
    private val SOFTWARE_NAME_PREFIXES = listOf("omx.google.", "c2.android.")

    /**
     * @param softwareOnlyFlag MediaCodecInfo.isSoftwareOnly() when available
     *   (API 29+), else null. When present it is authoritative.
     * @return true only if the decoder is hardware-backed.
     */
    fun isHardware(codecName: String, softwareOnlyFlag: Boolean?): Boolean {
        if (softwareOnlyFlag == true) return false
        val lower = codecName.lowercase()
        if (SOFTWARE_NAME_PREFIXES.any { lower.startsWith(it) }) return false
        return true
    }

    /** Human/log label for diagnostics export. */
    fun classify(codecName: String, softwareOnlyFlag: Boolean?): String =
        if (isHardware(codecName, softwareOnlyFlag)) "hardware" else "software"

    /**
     * Filter a list of (codecName, softwareOnlyFlag) to the hardware decoders,
     * preserving order. An empty result means NO hardware decoder exists — the
     * caller must fail explicitly, never fall back to software.
     */
    fun hardwareOnly(codecs: List<Pair<String, Boolean?>>): List<String> =
        codecs.filter { isHardware(it.first, it.second) }.map { it.first }
}
