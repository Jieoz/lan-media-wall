"""Announce/welcome payload shape (§7/§13/§14) + Hub mode-aware signing."""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import broker as broker_mod  # noqa: E402
import envelope  # noqa: E402

PSK = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def _hub(**over):
    cfg = dict(broker_mod.DEFAULTS)
    cfg.update({
        "psk": PSK,
        "state_path": os.path.join(tempfile.mkdtemp(), "state.json"),
        "advertise_host": "192.168.1.10",
        "ws_port": 8770,
    })
    cfg.update(over)
    cfg["auth_mode"] = envelope.normalize_auth_mode(cfg["auth_mode"])
    return broker_mod.Hub(cfg)


def test_announce_payload_carries_topology_auth_mode_hint():
    hub = _hub(auth_mode="open", topology="cohosted")
    p = hub.build_announce_payload()
    assert p["auth_mode"] == "open"
    assert p["topology"] == "cohosted"
    assert p["broker_hint"] == "192.168.1.10:8770"
    assert p["ws_port"] == 8770


def test_auth_meta_shape():
    hub = _hub(auth_mode="required", topology="dedicated")
    meta = hub.auth_meta()
    assert meta == {"auth_mode": "required", "topology": "dedicated"}


def test_make_env_open_emits_empty_sig():
    hub = _hub(auth_mode="open")
    env = hub.make_env("announce", hub.build_announce_payload(), "all")
    assert env["sig"] == ""               # open never signs (§13)


def test_make_env_required_signs():
    hub = _hub(auth_mode="required")
    env = hub.make_env("announce", hub.build_announce_payload(), "all")
    assert env["sig"] != ""
    assert envelope.verify_sig(env, PSK)


def test_make_env_optional_signs_when_psk_present():
    hub = _hub(auth_mode="optional")
    env = hub.make_env("welcome", {"assigned": True}, "player:p")
    assert env["sig"] != ""               # has PSK -> signs in optional


def test_make_env_optional_empty_sig_without_psk():
    hub = _hub(auth_mode="optional", psk="")
    env = hub.make_env("welcome", {"assigned": True}, "player:p")
    assert env["sig"] == ""               # no PSK -> empty sig in optional
