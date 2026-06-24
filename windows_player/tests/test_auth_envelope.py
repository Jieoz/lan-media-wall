"""Auth-mode-gated envelope build/verify (protocol §13 over §2/§3)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import envelope as E  # noqa: E402

PSK = "test-preshared-key-0123456789abcdef"


def test_build_unsigned_leaves_empty_sig_but_valid_shape():
    env = E.build_envelope(PSK, "hello", "player:win-1", "broker",
                           {"role": "player"}, sign_frame=False)
    assert env["sig"] == ""
    # all envelope fields still present (§2 shape unchanged)
    for k in ("v", "type", "msg_id", "ts", "from", "to", "sig", "payload"):
        assert k in env


def test_open_mode_accepts_unsigned():
    env = E.build_envelope(PSK, "play_at", "broker", "group:lobby", {"x": 1},
                           sign_frame=False)
    ok, reason = E.verify(PSK, env, now=env["ts"], auth_mode="open")
    assert ok and reason == ""


def test_open_mode_ignores_bad_sig():
    # even a wrong sig is accepted in open mode (sig not checked)
    env = E.build_envelope(PSK, "play_at", "broker", "group:lobby", {"x": 1})
    env["sig"] = "deadbeef"  # corrupt
    ok, reason = E.verify(PSK, env, now=env["ts"], auth_mode="open")
    assert ok and reason == ""


def test_open_mode_still_enforces_staleness():
    # ts hygiene runs in ALL modes (§13)
    env = E.build_envelope(PSK, "status", "player:win-1", "broker", {"x": 1},
                           ts=1_000_000, sign_frame=False)
    ok, reason = E.verify(PSK, env, now=1_000_000 + 40_000, auth_mode="open")
    assert not ok and reason == "stale"


def test_open_mode_still_dedups():
    cache = E.ReplayCache()
    env = E.build_envelope(PSK, "play_at", "broker", "group:lobby", {"x": 1},
                           sign_frame=False)
    ok1, _ = E.verify(PSK, env, replay=cache, now=env["ts"], auth_mode="open")
    ok2, reason2 = E.verify(PSK, env, replay=cache, now=env["ts"],
                            auth_mode="open")
    assert ok1 is True
    assert ok2 is False and reason2 == "dup"


def test_optional_mode_verifies_only_when_signed():
    # signed frame → verified (and tamper caught)
    signed = E.build_envelope(PSK, "play_at", "broker", "g:1", {"x": 1})
    ok, _ = E.verify(PSK, signed, now=signed["ts"], auth_mode="optional")
    assert ok
    signed["payload"]["x"] = 2  # tamper
    ok2, reason2 = E.verify(PSK, signed, now=signed["ts"], auth_mode="optional")
    assert not ok2 and reason2 == "sig"
    # unsigned frame → passed through (no sig to check)
    unsigned = E.build_envelope(PSK, "play_at", "broker", "g:1", {"x": 1},
                                sign_frame=False)
    ok3, _ = E.verify(PSK, unsigned, now=unsigned["ts"], auth_mode="optional")
    assert ok3


def test_required_mode_rejects_unsigned():
    unsigned = E.build_envelope(PSK, "play_at", "broker", "g:1", {"x": 1},
                                sign_frame=False)
    ok, reason = E.verify(PSK, unsigned, now=unsigned["ts"],
                          auth_mode="required")
    assert not ok and reason == "sig"


def test_default_auth_mode_is_required_backward_compatible():
    # no auth_mode kwarg → behaves exactly as v1 (always verifies)
    unsigned = E.build_envelope(PSK, "play_at", "broker", "g:1", {"x": 1},
                                sign_frame=False)
    ok, reason = E.verify(PSK, unsigned, now=unsigned["ts"])
    assert not ok and reason == "sig"
