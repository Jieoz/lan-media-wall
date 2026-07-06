package com.jieoz.lanmediawall.player.update

/**
 * §22 self-update decision logic — PURE, unit-testable, no Android / no I/O.
 *
 * All four release-line guardrails funnel through [decide] so the security
 * contract lives in one place with tests:
 *
 *   1. AUTHORIZED        — either the frame's HMAC signature was recomputed +
 *      matched (`env.authed`) OR it arrived over the local P2P controller link.
 *   2. MONOTONIC VERSION — target versionCode must be strictly greater than the
 *      running one (blocks downgrade + replay of an old update_app).
 *   3. WELL-FORMED       — url + a 64-hex sha256 must be present (the sha256 is
 *      re-verified against the downloaded bytes before install).
 *   4. SAME-SIGNER       — enforced by the Android platform at boot-scan time,
 *      not here; noted so the guarantee is explicit.
 */
object UpdateGuard {

    sealed class Decision {
        object Proceed : Decision()
        data class Reject(val reason: String) : Decision()
    }

    private val SHA256_RE = Regex("^[0-9a-fA-F]{64}$")

    /**
     * @param authed          env.authed — was the frame's signature verified?
     * @param p2pLocal        frame came over the accepted local P2P controller link.
     * @param currentVersionCode  BuildConfig.VERSION_CODE of the running app.
     * @param targetVersionCode   payload `version_code` (null if absent).
     * @param url             payload `url` of the APK on the broker media store.
     * @param sha256          payload `sha256` of the APK (64 hex chars).
     */
    fun decide(
        authed: Boolean,
        p2pLocal: Boolean = false,
        currentVersionCode: Int,
        targetVersionCode: Int?,
        url: String?,
        sha256: String?,
    ): Decision {
        // 1. authorized frame only. Broker mode requires HMAC auth; local P2P direct
        // control is treated as an explicit operator channel for bootstrap updates.
        if (!authed && !p2pLocal) return Decision.Reject("unauthorized")
        // 3a. url required
        if (url.isNullOrBlank()) return Decision.Reject("missing-url")
        // 3b. sha256 required + shape-checked (integrity gate before install)
        if (sha256.isNullOrBlank() || !SHA256_RE.matches(sha256)) {
            return Decision.Reject("bad-sha256")
        }
        // 2. monotonic versionCode — strictly newer, else block downgrade/replay
        if (targetVersionCode == null) return Decision.Reject("missing-version-code")
        if (targetVersionCode <= currentVersionCode) {
            return Decision.Reject("not-newer($targetVersionCode<=$currentVersionCode)")
        }
        return Decision.Proceed
    }
}
