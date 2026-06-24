"""`lmw://pair?...` URI parsing → config overlay (protocol §15)."""
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pairing as P  # noqa: E402

HEX_PSK = "0123456789abcdef0123456789abcdef0123456789abcdef"


def test_is_pairing_uri():
    assert P.is_pairing_uri("lmw://pair?host=10.0.0.1")
    assert P.is_pairing_uri("LMW://pair?host=x")
    assert not P.is_pairing_uri("https://example.com")
    assert not P.is_pairing_uri(None)
    assert not P.is_pairing_uri(12345)


def test_full_required_uri():
    uri = (f"lmw://pair?host=192.168.1.10&port=8770&group=lobby"
           f"&mode=required&psk={HEX_PSK}&wss=1&name=%E5%A4%A7%E5%8E%85")
    f = P.parse_pairing_uri(uri)
    assert f["host"] == "192.168.1.10"
    assert f["port"] == 8770
    assert f["group"] == "lobby"
    assert f["mode"] == "required"
    assert f["psk"] == HEX_PSK
    assert f["wss"] is True
    assert f["name"] == "大厅"  # URL-decoded UTF-8


def test_open_uri_without_psk():
    # §15.1: open mode carries no psk — "纯扫一下进组"
    uri = "lmw://pair?host=10.0.0.5&port=8770&group=default&mode=open"
    f = P.parse_pairing_uri(uri)
    assert f["mode"] == "open"
    assert "psk" not in f
    assert f["host"] == "10.0.0.5"


def test_unknown_params_ignored():
    # §15.1 forward-compat: unknown query params dropped, not an error
    uri = ("lmw://pair?host=10.0.0.5&port=8770&future_flag=42"
           "&another=hello&mode=open")
    f = P.parse_pairing_uri(uri)
    assert "future_flag" not in f and "another" not in f
    assert f["host"] == "10.0.0.5" and f["mode"] == "open"


def test_wss_falsey_values():
    assert P.parse_pairing_uri("lmw://pair?host=x&wss=0")["wss"] is False
    assert P.parse_pairing_uri("lmw://pair?host=x&wss=1")["wss"] is True
    assert P.parse_pairing_uri("lmw://pair?host=x&wss=true")["wss"] is True


def test_bad_mode_normalized_to_default():
    f = P.parse_pairing_uri("lmw://pair?host=x&mode=banana")
    assert f["mode"] == "open"  # normalize_mode fallback


def test_triple_slash_action_accepted():
    # lmw:///pair?... puts "pair" in path, not netloc — still valid
    f = P.parse_pairing_uri("lmw:///pair?host=10.0.0.9&port=8770")
    assert f["host"] == "10.0.0.9" and f["port"] == 8770


def test_non_lmw_scheme_raises():
    with pytest.raises(P.PairingError):
        P.parse_pairing_uri("https://pair?host=x")


def test_wrong_action_raises():
    with pytest.raises(P.PairingError):
        P.parse_pairing_uri("lmw://connect?host=x")


def test_bad_port_raises():
    with pytest.raises(P.PairingError):
        P.parse_pairing_uri("lmw://pair?host=x&port=notanumber")


def test_overlay_shape_required():
    f = P.parse_pairing_uri(
        f"lmw://pair?host=1.2.3.4&port=9000&group=g1&mode=required"
        f"&psk={HEX_PSK}&wss=1&name=Screen")
    ov = P.pairing_to_config_overlay(f)
    assert ov["broker"] == {"host": "1.2.3.4", "port": 9000, "use_wss": True}
    assert ov["psk"] == HEX_PSK
    assert ov["auth_mode"] == "required"
    assert ov["device"] == {"group_id": "g1", "name": "Screen"}


def test_overlay_open_has_no_psk_key():
    f = P.parse_pairing_uri("lmw://pair?host=1.2.3.4&port=8770&mode=open")
    ov = P.pairing_to_config_overlay(f)
    assert "psk" not in ov
    assert ov["auth_mode"] == "open"
    assert ov["broker"]["host"] == "1.2.3.4"


def test_overlay_sparse_only_emits_present_keys():
    f = P.parse_pairing_uri("lmw://pair?group=onlygroup")
    ov = P.pairing_to_config_overlay(f)
    assert ov == {"device": {"group_id": "onlygroup"}}
