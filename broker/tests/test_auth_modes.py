"""Auth-mode gating (§13): outbound signing + inbound verification.

Covers the pure envelope helpers (should_sign / verify_inbound) and the
load_config PSK rules per mode.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import envelope  # noqa: E402
import broker as broker_mod  # noqa: E402

PSK = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def _signed(type_="status", payload=None):
    return envelope.build_envelope(
        type_, payload or {"x": 1}, "player:p", "broker", PSK)


def _unsigned(type_="status", payload=None):
    return envelope.build_envelope(
        type_, payload or {"x": 1}, "player:p", "broker", PSK, sign=False)


# ---- normalize / should_sign --------------------------------------------
def test_normalize_auth_mode_defaults_to_open():
    assert envelope.normalize_auth_mode(None) == "open"
    assert envelope.normalize_auth_mode("garbage") == "open"
    assert envelope.normalize_auth_mode("REQUIRED") == "required"
    assert envelope.normalize_auth_mode(" Optional ") == "optional"


def test_should_sign_matrix():
    # open never signs (even with a PSK present).
    assert envelope.should_sign("open", PSK) is False
    assert envelope.should_sign("open", "") is False
    # optional signs only when a PSK is available.
    assert envelope.should_sign("optional", PSK) is True
    assert envelope.should_sign("optional", "") is False
    # required always signs.
    assert envelope.should_sign("required", PSK) is True
    assert envelope.should_sign("required", "") is True


def test_build_envelope_empty_sig_when_unsigned():
    env = _unsigned()
    assert env["sig"] == ""
    # structure still parses (§13: open keeps sig field, just empty).
    raw = envelope.dumps(env)
    parsed = envelope.parse(raw)
    assert parsed["sig"] == ""


# ---- verify_inbound: open -----------------------------------------------
def test_open_accepts_everything():
    assert envelope.verify_inbound(_unsigned(), PSK, "open") is True
    assert envelope.verify_inbound(_signed(), PSK, "open") is True
    # even a bogus sig is accepted in open (no verification at all).
    bad = _signed()
    bad["sig"] = "deadbeef"
    assert envelope.verify_inbound(bad, PSK, "open") is True


# ---- verify_inbound: optional -------------------------------------------
def test_optional_passes_empty_sig_but_checks_nonempty():
    assert envelope.verify_inbound(_unsigned(), PSK, "optional") is True
    assert envelope.verify_inbound(_signed(), PSK, "optional") is True
    # non-empty but wrong sig -> reject.
    bad = _signed()
    bad["sig"] = "deadbeef"
    assert envelope.verify_inbound(bad, PSK, "optional") is False


# ---- verify_inbound: required -------------------------------------------
def test_required_rejects_empty_and_bad_sig():
    assert envelope.verify_inbound(_signed(), PSK, "required") is True
    assert envelope.verify_inbound(_unsigned(), PSK, "required") is False
    bad = _signed()
    bad["sig"] = "deadbeef"
    assert envelope.verify_inbound(bad, PSK, "required") is False


# ---- load_config PSK rules per mode -------------------------------------
def _clean_env(monkeypatch):
    for k in ("LMW_PSK", "LMW_AUTH_MODE", "LMW_TOPOLOGY", "LMW_CONFIG"):
        monkeypatch.delenv(k, raising=False)


def test_open_mode_needs_no_psk(monkeypatch, tmp_path):
    _clean_env(monkeypatch)
    monkeypatch.setenv("LMW_CONFIG", str(tmp_path / "absent.yaml"))
    monkeypatch.setenv("LMW_AUTH_MODE", "open")
    cfg = broker_mod.load_config()
    assert cfg["auth_mode"] == "open"
    assert cfg["psk"] == ""        # zero-config: no key demanded


def test_optional_mode_needs_no_psk(monkeypatch, tmp_path):
    _clean_env(monkeypatch)
    monkeypatch.setenv("LMW_CONFIG", str(tmp_path / "absent.yaml"))
    monkeypatch.setenv("LMW_AUTH_MODE", "optional")
    cfg = broker_mod.load_config()
    assert cfg["auth_mode"] == "optional"
    assert cfg["psk"] == ""


def test_required_mode_demands_psk(monkeypatch, tmp_path):
    _clean_env(monkeypatch)
    monkeypatch.setenv("LMW_CONFIG", str(tmp_path / "absent.yaml"))
    monkeypatch.setenv("LMW_AUTH_MODE", "required")
    raised = False
    try:
        broker_mod.load_config()
    except SystemExit:
        raised = True
    assert raised, "required mode must reject a missing PSK"


def test_required_mode_with_psk_ok(monkeypatch, tmp_path):
    _clean_env(monkeypatch)
    monkeypatch.setenv("LMW_CONFIG", str(tmp_path / "absent.yaml"))
    monkeypatch.setenv("LMW_AUTH_MODE", "required")
    monkeypatch.setenv("LMW_PSK", PSK)
    cfg = broker_mod.load_config()
    assert cfg["auth_mode"] == "required"
    assert cfg["psk"] == PSK


def test_default_auth_mode_is_open_and_discovery_on(monkeypatch, tmp_path):
    _clean_env(monkeypatch)
    monkeypatch.setenv("LMW_CONFIG", str(tmp_path / "absent.yaml"))
    cfg = broker_mod.load_config()
    assert cfg["auth_mode"] == "open"
    assert cfg["enable_discovery"] is True
    assert cfg["topology"] == "dedicated"
