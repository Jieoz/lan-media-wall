"""Config auth_mode accessor + pairing overlay merge (§13/§15)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config as C  # noqa: E402
import pairing as P  # noqa: E402

HEX_PSK = "0123456789abcdef0123456789abcdef0123456789abcdef"


def test_auth_mode_default_is_open():
    cfg = C.load_config(None)
    assert cfg.auth_mode == "open"


def test_auth_mode_env_override(monkeypatch):
    cfg = C.load_config(None)
    monkeypatch.setenv("LMW_AUTH_MODE", "required")
    assert cfg.auth_mode == "required"


def test_topology_defaults_present():
    cfg = C.load_config(None)
    assert cfg.get("topology", "cohost") is False
    assert cfg.get("topology", "auto") is True
    assert cfg.get("topology", "p2p_listen_port") == 8770


def test_apply_pairing_merges_broker_and_auth():
    cfg = C.load_config(None)
    f = P.parse_pairing_uri(
        f"lmw://pair?host=10.1.2.3&port=9001&group=hall&mode=required"
        f"&psk={HEX_PSK}&wss=1")
    overlay = P.pairing_to_config_overlay(f)
    C.apply_pairing(cfg, overlay)
    assert cfg.raw["broker"]["host"] == "10.1.2.3"
    assert cfg.raw["broker"]["port"] == 9001
    assert cfg.raw["broker"]["use_wss"] is True
    assert cfg.auth_mode == "required"
    assert cfg.raw["device"]["group_id"] == "hall"
    # untouched keys survive the merge
    assert "mpv" in cfg.raw and "thumbnail" in cfg.raw


def test_apply_pairing_open_leaves_existing_psk():
    cfg = C.load_config(None)
    original_psk = cfg.raw["psk"]
    f = P.parse_pairing_uri("lmw://pair?host=10.0.0.1&port=8770&mode=open")
    C.apply_pairing(cfg, P.pairing_to_config_overlay(f))
    # open URI carries no psk → config psk untouched
    assert cfg.raw["psk"] == original_psk
    assert cfg.auth_mode == "open"
    assert cfg.raw["broker"]["host"] == "10.0.0.1"
