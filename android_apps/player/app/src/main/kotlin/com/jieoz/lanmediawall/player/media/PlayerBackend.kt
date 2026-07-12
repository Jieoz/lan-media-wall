package com.jieoz.lanmediawall.player.media

/**
 * §backend-ab: which video playback kernel drives the SurfaceView.
 *
 * The QZX_C1 / HiSilicon / YunOS 4.4.2 boxes have historically dropped frames or
 * black-screened under the hardware-only ExoPlayer (Media3) path. This project
 * therefore ships TWO first-class video kernels behind one [VideoBackend] contract
 * so they can be A/B compared on the SAME box + media sample without a re-flash:
 *
 *  - [EXOPLAYER]   — Media3/ExoPlayer 2.19 with a hardware-only MediaCodecSelector
 *                    (the v1.14.0 path). Rich diagnostics; strict "no software
 *                    video decoder" policy.
 *  - [MEDIAPLAYER] — the platform `android.media.MediaPlayer`, i.e. the OEM's own
 *                    Stagefright/AwesomePlayer + OMX pipeline on 4.4. On these
 *                    HiSilicon boxes that is the pipeline the vendor firmware is
 *                    actually tuned for, so it can succeed where the generic
 *                    ExoPlayer codec plumbing stalls.
 *
 * The wire/config value is the lowercase [id]; unknown/blank strings resolve to
 * [AUTO] (see [BackendSelector]).
 */
enum class PlayerBackend(val id: String) {
    EXOPLAYER("exoplayer"),
    MEDIAPLAYER("mediaplayer");

    companion object {
        /** Parse a persisted/config id to a concrete backend, or null if it is
         *  not a concrete backend id (blank / "auto" / unknown). */
        fun fromId(value: String?): PlayerBackend? =
            values().firstOrNull { it.id.equals(value?.trim(), ignoreCase = true) }
    }
}
