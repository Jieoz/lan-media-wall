"""§17.4 pairing-URI derived-mode parsing + config overlay/accessors."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config as C  # noqa: E402
import pairing as P  # noqa: E402

DK_HEX = "11" * 32   # 32-byte device_key in hex
BK_HEX = "22" * 32   # 32-byte broker verify key in hex


def test_parse_derived_uri_fields():
    uri = (f"lmw://pair?host=10.0.0.1&port=8770&group=lobby&mode=required"
           f"&key_mode=derived&dk={DK_HEX}&id=player%3Awin-1&bk={BK_HEX}")
    f = P.parse_pairing_uri(uri)
    assert f["mode"] == "required"
    assert f["key_mode"] == "derived"
    assert f["dk"] == DK_HEX
    assert f["id"] == "player:win-1"   # URL-decoded
    assert f["bk"] == BK_HEX
    assert "psk" not in f              # derived carries no PSK


def test_derived_overlay_shape():
    f = P.parse_pairing_uri(
        f"lmw://pair?host=10.0.0.1&port=8770&group=lobby&mode=required"
        f"&key_mode=derived&dk={DK_HEX}&id=player%3Awin-1&bk={BK_HEX}")
    ov = P.pairing_to_config_overlay(f)
    assert ov["auth_mode"] == "required"
    assert ov["key_mode"] == "derived"
    assert ov["derived_key"] == {
        "device_key": DK_HEX, "identity": "player:win-1", "broker_key": BK_HEX}
    assert "psk" not in ov


def test_key_mode_inferred_derived_when_dk_present_without_explicit_flag():
    # an old generator might omit key_mode but still send dk → infer derived
    f = P.parse_pairing_uri(
        f"lmw://pair?host=x&mode=required&dk={DK_HEX}&id=player%3Aw")
    ov = P.pairing_to_config_overlay(f)
    assert ov["key_mode"] == "derived"


def test_global_psk_uri_stays_global():
    # a legacy psk-only QR has no key_mode and no dk → overlay stays global
    psk = "0123456789abcdef0123456789abcdef0123456789abcdef"
    f = P.parse_pairing_uri(f"lmw://pair?host=x&mode=required&psk={psk}")
    ov = P.pairing_to_config_overlay(f)
    assert "key_mode" not in ov          # not forced → config default (global)
    assert ov["psk"] == psk
    assert "derived_key" not in ov


def test_apply_derived_pairing_then_config_accessors():
    cfg = C.load_config(None)
    f = P.parse_pairing_uri(
        f"lmw://pair?host=10.1.2.3&port=9001&group=hall&mode=required"
        f"&key_mode=derived&dk={DK_HEX}&id=player%3Awin-7&bk={BK_HEX}")
    C.apply_pairing(cfg, P.pairing_to_config_overlay(f))
    assert cfg.auth_mode == "required"
    assert cfg.key_mode == "derived"
    # hex decoded to raw bytes by the typed accessors
    assert cfg.device_key == bytes.fromhex(DK_HEX)
    assert cfg.broker_key == bytes.fromhex(BK_HEX)
    assert cfg.identity == "player:win-7"
    # untouched keys survive
    assert "mpv" in cfg.raw


def test_config_key_mode_default_global():
    cfg = C.load_config(None)
    assert cfg.key_mode == "global"
    assert cfg.device_key is None
    assert cfg.broker_key is None
    assert cfg.identity is None


def test_config_key_mode_env_override(monkeypatch):
    cfg = C.load_config(None)
    monkeypatch.setenv("LMW_KEY_MODE", "derived")
    assert cfg.key_mode == "derived"


def test_config_device_key_env_override(monkeypatch):
    cfg = C.load_config(None)
    monkeypatch.setenv("LMW_DEVICE_KEY", DK_HEX)
    assert cfg.device_key == bytes.fromhex(DK_HEX)


def test_malformed_device_key_hex_degrades_to_none(monkeypatch):
    cfg = C.load_config(None)
    monkeypatch.setenv("LMW_DEVICE_KEY", "not-hex-zz")
    assert cfg.device_key is None       # bad hex → None, never crash
