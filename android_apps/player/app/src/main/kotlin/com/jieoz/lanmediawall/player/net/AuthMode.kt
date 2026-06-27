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

/**
 * Key-derivation mode — protocol_spec §17 (v1.3). Selects how the §3 HMAC **key**
 * is chosen when signing is active. The signing-string layout, canonical JSON,
 * ts window and msg_id dedup are all unchanged from §3 — the *only* variable is
 * the key:
 *
 * | key_mode | signing key                                   | use |
 * |----------|-----------------------------------------------|-----|
 * | derived  | `HMAC_SHA256(PSK, identity)` per-endpoint key | v1.3 default; leak isolation |
 * | global   | the raw PSK bytes (v1.2 behaviour)            | interop with un-upgraded ends |
 *
 * The coordinator (broker / cohost / p2p controller) is authoritative and
 * declares it in `welcome.payload.key_mode` and UDP `announce.payload.key_mode`.
 *
 * **Backward-compat default is [GLOBAL]** (§17.3): a missing/unknown `key_mode`
 * on the wire MUST be treated as `global` (= v1.2). This differs from a fresh
 * broker *deployment*, which defaults to `derived` in its own config — but that
 * choice always reaches an end as an explicit `key_mode=derived` on the wire.
 *
 * Pure logic, no Android dependencies — fully unit-testable on the JVM.
 */
enum class KeyMode(val wire: String) {
    GLOBAL("global"),
    DERIVED("derived");

    companion object {
        /** Parse the wire string; missing/unknown → [GLOBAL] (§17.3). */
        fun parse(raw: String?): KeyMode = when (raw?.trim()?.lowercase()) {
            "derived" -> DERIVED
            "global" -> GLOBAL
            else -> GLOBAL
        }
    }
}
