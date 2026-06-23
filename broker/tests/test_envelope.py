"""HMAC sign/verify round-trip + envelope parsing + dedup + ts checks (§2/§3)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import envelope  # noqa: E402

PSK = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def test_sign_verify_roundtrip():
    env = envelope.build_envelope(
        "hello", {"role": "player", "device_id": "win-01"},
        "player:win-01", "broker", PSK)
    raw = envelope.dumps(env)
    parsed = envelope.parse(raw)
    assert envelope.verify_sig(parsed, PSK)


def test_tampered_payload_fails():
    env = envelope.build_envelope(
        "stop", {"group_id": "lobby"}, "controller:p1", "group:lobby", PSK)
    env["payload"]["group_id"] = "other"
    assert not envelope.verify_sig(env, PSK)


def test_wrong_psk_fails():
    env = envelope.build_envelope("ping", {"x": 1}, "broker", "all", PSK)
    assert not envelope.verify_sig(env, "different-psk")


def test_canonical_json_is_stable_and_sorted():
    a = envelope.canonical_json({"b": 1, "a": 2})
    b = envelope.canonical_json({"a": 2, "b": 1})
    assert a == b == '{"a":2,"b":1}'


def test_canonical_json_unicode_preserved():
    # ensure_ascii=False per §3 — Chinese names must hash identically.
    s = envelope.canonical_json({"name": "大厅"})
    assert "大厅" in s


def test_parse_rejects_missing_field():
    import json
    bad = json.dumps({"v": 1, "type": "x"})
    try:
        envelope.parse(bad)
        assert False, "should have raised"
    except envelope.MalformedEnvelope:
        pass


def test_parse_rejects_non_json():
    try:
        envelope.parse("not json{{")
        assert False
    except envelope.MalformedEnvelope:
        pass


def test_ts_window():
    now = 1_000_000_000_000
    assert envelope.check_ts(now, now=now)
    assert envelope.check_ts(now - 29_000, now=now)
    assert not envelope.check_ts(now - 31_000, now=now)
    # first-connection window is wider (120s).
    assert envelope.check_ts(now - 100_000, now=now, first=True)
    assert not envelope.check_ts(now - 130_000, now=now, first=True)


def test_dedup_cache():
    cache = envelope.MsgIdCache(ttl_ms=1000)
    now = 5_000_000
    assert not cache.seen("m1", now=now)      # first time
    assert cache.seen("m1", now=now)          # duplicate
    # after TTL expiry it is forgotten.
    assert not cache.seen("m1", now=now + 2000)


def test_signing_string_layout():
    s = envelope.signing_string(1, "hello", "id1", 42, "a", "b", {"k": "v"})
    assert s == '1|hello|id1|42|a|b|{"k":"v"}'
