"""Pairing URI build/parse (§15) — encoding + psk-omitted-in-open."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pairing  # noqa: E402

PSK = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def test_open_uri_omits_psk():
    uri = pairing.build_pairing_uri(
        host="192.168.1.10", port=8770, group="lobby",
        mode="open", psk=PSK, wss=False)
    assert uri.startswith("lmw://pair?")
    assert "psk=" not in uri          # §15.1: open carries no psk
    d = pairing.parse_pairing_uri(uri)
    assert d["host"] == "192.168.1.10"
    assert d["port"] == 8770
    assert d["group"] == "lobby"
    assert d["mode"] == "open"
    assert d["wss"] is False
    assert "psk" not in d


def test_required_uri_includes_psk():
    uri = pairing.build_pairing_uri(
        host="10.0.0.5", port=8771, group="hall",
        mode="required", psk=PSK, wss=True)
    assert f"psk={PSK}" in uri
    d = pairing.parse_pairing_uri(uri)
    assert d["mode"] == "required"
    assert d["psk"] == PSK
    assert d["wss"] is True


def test_optional_with_psk_includes_it():
    uri = pairing.build_pairing_uri(
        host="h", mode="optional", psk=PSK)
    assert "psk=" in uri
    assert pairing.parse_pairing_uri(uri)["psk"] == PSK


def test_optional_without_psk_omits_it():
    uri = pairing.build_pairing_uri(host="h", mode="optional", psk=None)
    assert "psk=" not in uri


def test_url_encoding_of_name_and_group():
    # Chinese name + spaces must round-trip through URL-encoding.
    uri = pairing.build_pairing_uri(
        host="h", group="大厅 组", mode="open", name="大厅 左屏")
    assert " " not in uri.split("?", 1)[1]   # spaces encoded
    d = pairing.parse_pairing_uri(uri)
    assert d["group"] == "大厅 组"
    assert d["name"] == "大厅 左屏"


def test_unknown_param_preserved_on_parse():
    # Forward-compat: unknown query params are kept, not an error (§15.1).
    uri = "lmw://pair?host=h&port=8770&future_flag=42"
    d = pairing.parse_pairing_uri(uri)
    assert d["future_flag"] == "42"


def test_parse_rejects_wrong_scheme():
    for bad in ("http://pair?host=h", "lmw://connect?host=h"):
        raised = False
        try:
            pairing.parse_pairing_uri(bad)
        except ValueError:
            raised = True
        assert raised, bad


def test_from_config_open_has_no_psk():
    cfg = {"auth_mode": "open", "ws_port": 8770, "psk": PSK,
           "advertise_host": "192.168.1.10"}
    uri = pairing.pairing_uri_from_config(cfg)
    assert "psk=" not in uri
    assert "192.168.1.10" in uri


def test_from_config_required_has_psk():
    cfg = {"auth_mode": "required", "ws_port": 8770, "psk": PSK,
           "advertise_host": "192.168.1.10"}
    uri = pairing.pairing_uri_from_config(cfg)
    assert f"psk={PSK}" in uri


def test_render_qr_falls_back_to_uri_text():
    # qrcode may not be installed; render must still surface the URI + note.
    uri = "lmw://pair?host=h&port=8770"
    out = pairing.render_qr(uri)
    assert uri in out
