"""§17 derived-key signing/verification + leak isolation (protocol §17)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import envelope as E  # noqa: E402

PSK = "test-preshared-key-0123456789abcdef"


def test_derive_device_key_is_hmac_psk_identity_32_bytes():
    # §17.2: device_key = HMAC_SHA256(PSK, identity).digest() — 32 raw bytes.
    import hashlib
    import hmac
    ident = "player:win-lobby-01"
    dk = E.derive_device_key(PSK, ident)
    assert isinstance(dk, bytes) and len(dk) == 32
    expected = hmac.new(PSK.encode(), ident.encode(), hashlib.sha256).digest()
    assert dk == expected


def test_identity_is_byte_exact_no_normalization():
    # §17.5: identity participates verbatim — case/whitespace change the key.
    a = E.derive_device_key(PSK, "player:Win-01")
    b = E.derive_device_key(PSK, "player:win-01")
    c = E.derive_device_key(PSK, "player:win-01 ")
    assert a != b != c and a != c


def test_derived_sign_verify_roundtrip_via_psk_derivation():
    # Sender signs with its own device_key; verifier (holding PSK) re-derives
    # from `from` and accepts (§17.2 stateless verify).
    env = E.build_envelope(PSK, "status", "player:win-1", "broker", {"x": 1},
                           key_mode=E.KEY_MODE_DERIVED)
    ok, reason = E.verify(PSK, env, now=env["ts"],
                          key_mode=E.KEY_MODE_DERIVED)
    assert ok and reason == ""


def test_derived_sign_with_explicit_device_key_matches_psk_derivation():
    # A PSK-less end signs with the device_key it was handed at pairing; a
    # PSK-holding verifier re-derives the same key and accepts.
    dk = E.derive_device_key(PSK, "player:win-1")
    env = E.build_envelope("", "status", "player:win-1", "broker", {"x": 1},
                           key_mode=E.KEY_MODE_DERIVED, device_key=dk)
    ok, _ = E.verify(PSK, env, now=env["ts"], key_mode=E.KEY_MODE_DERIVED)
    assert ok


def test_global_mode_unaffected_by_derived_verifier_mismatch():
    # A frame signed in global mode (key=PSK) must NOT verify under derived
    # (key=device_key) — the two modes are distinct keys, as intended.
    env = E.build_envelope(PSK, "status", "player:win-1", "broker", {"x": 1})
    ok_g, _ = E.verify(PSK, env, now=env["ts"])  # global default → ok
    ok_d, reason_d = E.verify(PSK, env, now=env["ts"],
                              key_mode=E.KEY_MODE_DERIVED)
    assert ok_g is True
    assert ok_d is False and reason_d == "sig"


# --- §17.5 leak isolation (the contract-compliance negative test) ----------

def test_leak_isolation_key_a_cannot_sign_as_identity_b():
    """A key minted for identity-A, used to sign a frame claiming from=B, must
    be REJECTED — a compromised end can't impersonate another (§17.5)."""
    dk_a = E.derive_device_key(PSK, "player:attacker-A")
    # attacker forges a broker command but signs with its own (A) device_key
    forged = E.build_envelope("", "play_at", "broker", "group:lobby",
                              {"evil": True},
                              key_mode=E.KEY_MODE_DERIVED, device_key=dk_a)
    # frame claims from="broker"; verifier derives the BROKER key from `from`
    ok, reason = E.verify(PSK, forged, now=forged["ts"],
                          key_mode=E.KEY_MODE_DERIVED)
    assert ok is False and reason == "sig"


def test_leak_isolation_player_a_cannot_forge_player_b():
    dk_a = E.derive_device_key(PSK, "player:A")
    # A signs with its key but stamps from="player:B"
    forged = E.build_envelope("", "status", "player:B", "broker", {"x": 1},
                              key_mode=E.KEY_MODE_DERIVED, device_key=dk_a)
    ok, reason = E.verify(PSK, forged, now=forged["ts"],
                          key_mode=E.KEY_MODE_DERIVED)
    assert ok is False and reason == "sig"
    # but A signing honestly as itself verifies fine
    honest = E.build_envelope("", "status", "player:A", "broker", {"x": 1},
                              key_mode=E.KEY_MODE_DERIVED, device_key=dk_a)
    assert E.verify(PSK, honest, now=honest["ts"],
                    key_mode=E.KEY_MODE_DERIVED)[0] is True


def test_resolver_path_verifies_broker_frame_without_psk():
    # A PSK-less end verifies a broker frame using the broker_key it got from
    # pairing (the resolver maps "broker" -> bk); no PSK on this end.
    broker_dk = E.derive_device_key(PSK, "broker")
    env = E.build_envelope(PSK, "play_at", "broker", "group:lobby", {"x": 1},
                           key_mode=E.KEY_MODE_DERIVED)  # broker signs (has PSK)
    resolver = lambda frm: broker_dk if frm == "broker" else None  # noqa: E731
    ok, _ = E.verify("", env, now=env["ts"], key_mode=E.KEY_MODE_DERIVED,
                     key_resolver=resolver)
    assert ok is True


def test_resolver_unknown_identity_fails_closed():
    # The resolver returns None for an identity it has no key for → reject.
    env = E.build_envelope(PSK, "status", "player:stranger", "broker", {"x": 1},
                           key_mode=E.KEY_MODE_DERIVED)
    resolver = lambda frm: None  # noqa: E731
    ok, reason = E.verify("", env, now=env["ts"], key_mode=E.KEY_MODE_DERIVED,
                          key_resolver=resolver)
    assert ok is False and reason == "sig"


def test_open_mode_skips_sig_even_in_derived():
    # §17.3: open never signs/verifies regardless of key_mode.
    env = E.build_envelope(PSK, "play_at", "broker", "g:1", {"x": 1},
                           sign_frame=False, key_mode=E.KEY_MODE_DERIVED)
    ok, _ = E.verify(PSK, env, now=env["ts"], auth_mode="open",
                     key_mode=E.KEY_MODE_DERIVED)
    assert ok is True
