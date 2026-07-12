package com.jieoz.lanmediawall.player.media

/**
 * §backend-ab: PURE decision of which [PlayerBackend] to run and WHY, so the choice
 * is unit-testable off-device and observable in diagnostics. No Android imports.
 *
 * Precedence (highest first) — an explicit signal always beats "auto":
 *   1. [override] — a test affordance (a `/data/local/tmp/lmw_video_backend` file
 *      read by the Android glue). Lets the one-action A/B script (see
 *      `scripts/qzx_ab_backend.sh`) flip the kernel + restart with NO settings UI
 *      surgery. Source = `override`.
 *   2. [configured] — the operator's Settings choice (a concrete backend id).
 *      Source = `config`.
 *   3. AUTO fallback — neither above is a concrete backend. Real QZX_C1 A/B
 *      evidence showed ExoPlayer visibly dropping frames while the OEM native
 *      MediaPlayer path was smooth, so AUTO resolves to MediaPlayer.
 *
 * The default lives in exactly one place; there is no device-name branch. Explicit
 * operator configuration and the temporary diagnostic override still take priority.
 */
object BackendSelector {

    /** The concrete backend chosen + a terse machine-greppable reason. */
    data class Decision(val backend: PlayerBackend, val source: String) {
        /** e.g. `mediaplayer(override)` — for logs + status. */
        fun label(): String = "${backend.id}($source)"
    }

    /** Backend used when nothing explicit is set. Single place to flip the fleet
     *  default once real-device A/B evidence lands. */
    val AUTO_DEFAULT: PlayerBackend = PlayerBackend.MEDIAPLAYER

    /**
     * @param override raw contents of the test-override file (null if absent).
     * @param configured the persisted Settings value ("auto" / a backend id / blank).
     */
    fun decide(override: String?, configured: String?): Decision {
        PlayerBackend.fromId(override)?.let { return Decision(it, "override") }
        PlayerBackend.fromId(configured)?.let { return Decision(it, "config") }
        return Decision(AUTO_DEFAULT, "auto-default")
    }
}
