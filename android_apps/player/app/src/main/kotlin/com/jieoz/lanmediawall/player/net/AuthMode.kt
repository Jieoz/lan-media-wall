package com.jieoz.lanmediawall.player.net

/**
 * Authentication mode — protocol_spec §13 (the v1.2 optionalization of §3 HMAC).
 *
 * The coordinator (broker / cohost / p2p controller) is authoritative for the
 * mode and declares it in `welcome.payload.auth_mode` and UDP
 * `announce.payload.auth_mode`. End-points (player here) read it and adapt how
 * they sign outbound frames and verify inbound ones:
 *
 * | mode      | outbound `sig`           | inbound verify           | ts/dedup |
 * |-----------|--------------------------|--------------------------|----------|
 * | open      | "" (empty)               | not verified             | still on |
 * | optional  | sign iff PSK present     | verify iff `sig` non-""  | still on |
 * | required  | mandatory valid sig      | strict verify, else drop | still on |
 *
 * The §3 freshness window + 5-minute replay dedup run in **every** mode — they
 * are replay hygiene that needs no key. The auth-failure counter / cooldown
 * (§3 末) is only meaningful under `required` (enforced broker-side).
 *
 * Pure logic, no Android dependencies — fully unit-testable on the JVM.
 */
enum class AuthMode(val wire: String) {
    OPEN("open"),
    OPTIONAL("optional"),
    REQUIRED("required");

    companion object {
        /**
         * Parse the wire string. Per §15.3 the factory default is `open`, so an
         * unknown/missing value resolves to [OPEN] (the zero-config default)
         * rather than failing — forward-compatible with future modes.
         */
        fun parse(raw: String?): AuthMode = when (raw?.trim()?.lowercase()) {
            "required" -> REQUIRED
            "optional" -> OPTIONAL
            "open" -> OPEN
            else -> OPEN
        }
    }
}
