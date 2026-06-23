"""HMAC envelope round-trip + replay/staleness/dedup (protocol §2/§3)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import envelope as E  # noqa: E402

PSK = "test-preshared-key-0123456789abcdef"


def test_sign_is_deterministic_and_canonical():
    p1 = {"b": 2, "a": 1, "nested": {"y": 1, "x": 2}}
    p2 = {"a": 1, "nested": {"x": 2, "y": 1}, "b": 2}  # different key order
    s1 = E.sign(PSK, 1, "status", "m1", 100, "player:x", "broker", p1)
    s2 = E.sign(PSK, 1, "status", "m1", 100, "player:x", "broker", p2)
    assert s1 == s2  # canonical_json sorts keys → same signature


def test_build_and_verify_roundtrip():
    env = E.build_envelope(PSK, "hello", "player:win-1", "broker",
                           {"role": "player", "device_id": "win-1"})
    ok, reason = E.verify(PSK, env, now=env["ts"])
    assert ok and reason == ""


def test_tampered_payload_fails_sig():
    env = E.build_envelope(PSK, "status", "player:win-1", "broker", {"v": 1})
    env["payload"]["v"] = 999  # tamper after signing
    ok, reason = E.verify(PSK, env, now=env["ts"])
    assert not ok and reason == "sig"


def test_wrong_psk_fails():
    env = E.build_envelope(PSK, "status", "player:win-1", "broker", {"x": 1})
    ok, reason = E.verify("other-key", env, now=env["ts"])
    assert not ok and reason == "sig"


def test_stale_ts_rejected_outside_window():
    env = E.build_envelope(PSK, "status", "player:win-1", "broker", {"x": 1},
                           ts=1_000_000)
    # 40s later, normal 30s window → stale
    ok, reason = E.verify(PSK, env, now=1_000_000 + 40_000)
    assert not ok and reason == "stale"


def test_first_connect_window_is_relaxed():
    env = E.build_envelope(PSK, "hello", "player:win-1", "broker", {"x": 1},
                           ts=1_000_000)
    # 90s later: rejected normally, accepted on first connect (120s window)
    assert E.verify(PSK, env, now=1_000_000 + 90_000)[0] is False
    assert E.verify(PSK, env, now=1_000_000 + 90_000, first_connect=True)[0] is True


def test_replay_dedup():
    cache = E.ReplayCache()
    env = E.build_envelope(PSK, "play_at", "broker", "group:lobby", {"x": 1})
    ok1, _ = E.verify(PSK, env, replay=cache, now=env["ts"])
    ok2, reason2 = E.verify(PSK, env, replay=cache, now=env["ts"])
    assert ok1 is True
    assert ok2 is False and reason2 == "dup"


def test_replay_cache_ttl_expiry():
    cache = E.ReplayCache(ttl_ms=1000)
    assert cache.seen("mid-1", now=0) is False     # first time
    assert cache.seen("mid-1", now=500) is True     # within ttl
    assert cache.seen("mid-1", now=2000) is False   # expired → seen-as-new


def test_missing_fields_shape():
    ok, reason = E.verify(PSK, {"type": "x"}, now=0)
    assert not ok and reason == "shape"
