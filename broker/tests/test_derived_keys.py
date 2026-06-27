"""§17 derived per-endpoint keys: derivation, sign/verify, key_mode
negotiation, and the leak-isolation negative test (§17.5).

The signing-string layout, canonical JSON, ts and msg_id rules are unchanged
from §3 — these tests only exercise the key choice (global PSK vs per-identity
device_key) and the cross-end byte-for-byte invariants in §17.5.
"""
import hashlib
import hmac
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import envelope  # noqa: E402

PSK = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


# ---- derive_key: the §17.2 invariant -------------------------------------
def test_derive_key_is_hmac_psk_identity_32_bytes():
    ident = "player:win-lobby-01"
    dk = envelope.derive_key(PSK, ident)
    assert isinstance(dk, bytes)
    assert len(dk) == 32                              # raw HMAC-SHA256 digest
    # Exactly HMAC_SHA256(PSK, identity).digest() — no hex round-trip (§17.5).
    expected = hmac.new(PSK.encode("utf-8"), ident.encode("utf-8"),
                        hashlib.sha256).digest()
    assert dk == expected


def test_derive_key_per_identity_differs():
    a = envelope.derive_key(PSK, "player:a")
    b = envelope.derive_key(PSK, "player:b")
    assert a != b


def test_derive_key_identity_is_byte_exact_no_normalization():
    # §17.5: identity participates verbatim — no lowercasing/trim.
    assert (envelope.derive_key(PSK, "player:Win-01")
            != envelope.derive_key(PSK, "player:win-01"))
    assert (envelope.derive_key(PSK, "broker ")
            != envelope.derive_key(PSK, "broker"))


# ---- normalize_key_mode: missing/unknown -> global (§17.3) ---------------
def test_normalize_key_mode_defaults_to_global():
    assert envelope.normalize_key_mode(None) == "global"
    assert envelope.normalize_key_mode("") == "global"
    assert envelope.normalize_key_mode("garbage") == "global"
    assert envelope.normalize_key_mode("DERIVED") == "derived"
    assert envelope.normalize_key_mode(" Global ") == "global"


# ---- derived sign/verify round-trip --------------------------------------
def test_derived_sign_verify_roundtrip():
    env = envelope.build_envelope(
        "status", {"online": True}, "player:win-01", "broker", PSK,
        key_mode="derived")
    raw = envelope.dumps(env)
    parsed = envelope.parse(raw)
    # Verifier derives device_key from the frame's own `from` — passes.
    assert envelope.verify_sig(parsed, PSK, "derived")


def test_derived_sig_differs_from_global_sig():
    common = dict(msg_id="m", ts=1, payload={"x": 1})
    g = envelope.compute_sig(PSK, 1, "status", "m", 1, "player:p", "broker",
                             {"x": 1}, "global")
    d = envelope.compute_sig(PSK, 1, "status", "m", 1, "player:p", "broker",
                             {"x": 1}, "derived")
    assert g != d
    # And the global path still equals raw-PSK HMAC (v1.2 unchanged).
    msg = envelope.signing_string(1, "status", "m", 1, "player:p", "broker",
                                  {"x": 1}).encode("utf-8")
    assert g == hmac.new(PSK.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def test_broker_frame_signed_with_broker_identity():
    # §17.5: broker downlink frames are from="broker", keyed by HMAC(PSK,"broker").
    env = envelope.build_envelope(
        "play_at", {"play_at": 123}, "broker", "group:lobby", PSK,
        key_mode="derived")
    expected_key = envelope.derive_key(PSK, "broker")
    msg = envelope.signing_string(
        env["v"], "play_at", env["msg_id"], env["ts"], "broker",
        "group:lobby", {"play_at": 123}).encode("utf-8")
    expected = hmac.new(expected_key, msg, hashlib.sha256).hexdigest()
    assert env["sig"] == expected


# ---- key_mode mismatch: derived frame fails global verify and vice versa --
def test_cross_key_mode_verify_fails():
    env = envelope.build_envelope(
        "status", {"x": 1}, "player:p", "broker", PSK, key_mode="derived")
    assert envelope.verify_sig(env, PSK, "derived")
    assert not envelope.verify_sig(env, PSK, "global")
    env2 = envelope.build_envelope(
        "status", {"x": 1}, "player:p", "broker", PSK, key_mode="global")
    assert envelope.verify_sig(env2, PSK, "global")
    assert not envelope.verify_sig(env2, PSK, "derived")


# ---- LEAK ISOLATION (§17.5 contract-compliance evidence) -----------------
def test_leak_isolation_signed_as_a_claiming_from_b_is_rejected():
    """Sign with identity-A's device_key but set from=identity-B.
    The verifier derives the key from the *claimed* from (B), so the recomputed
    sig won't match — the frame MUST be rejected. This is the whole point of
    §17: a leaked player-A key cannot forge player-B (or broker)."""
    ident_a = "player:leaked-A"
    ident_b = "player:victim-B"
    key_a = envelope.derive_key(PSK, ident_a)

    msg_id, ts, payload = "x1", 1_000, {"cmd": "stop"}
    sstr = envelope.signing_string(1, "stop", msg_id, ts, ident_b,
                                   "group:lobby", payload).encode("utf-8")
    # Forge: HMAC with A's key, but stamp from=B on the envelope.
    forged_sig = hmac.new(key_a, sstr, hashlib.sha256).hexdigest()
    forged = {
        "v": 1, "type": "stop", "msg_id": msg_id, "ts": ts,
        "from": ident_b, "to": "group:lobby", "sig": forged_sig,
        "payload": payload,
    }
    # Verifier derives B's key from from=B -> mismatch -> reject.
    assert not envelope.verify_sig(forged, PSK, "derived")
    # And the strict inbound gate drops it too.
    assert not envelope.verify_inbound(forged, PSK, "required", "derived")


def test_leak_isolation_forging_broker_from_player_key_rejected():
    # A leaked player key must not be able to impersonate the broker.
    player_key = envelope.derive_key(PSK, "player:leaked-A")
    sstr = envelope.signing_string(1, "play_at", "m", 1, "broker",
                                   "group:lobby", {"play_at": 9}).encode("utf-8")
    forged = {
        "v": 1, "type": "play_at", "msg_id": "m", "ts": 1, "from": "broker",
        "to": "group:lobby", "sig": hmac.new(player_key, sstr,
                                             hashlib.sha256).hexdigest(),
        "payload": {"play_at": 9},
    }
    assert not envelope.verify_inbound(forged, PSK, "required", "derived")


# ---- open mode: key_mode is moot -----------------------------------------
def test_open_mode_ignores_key_mode():
    forged = envelope.build_envelope(
        "stop", {"x": 1}, "player:p", "broker", PSK, sign=False)
    # open never verifies regardless of key_mode (§17.3).
    assert envelope.verify_inbound(forged, PSK, "open", "derived") is True
    assert envelope.verify_inbound(forged, PSK, "open", "global") is True
