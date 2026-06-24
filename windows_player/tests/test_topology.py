"""Topology role decision (§14.5) + announce parsing (§7/§14) — pure logic."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import topology as TP  # noqa: E402
import discovery_probe as DP  # noqa: E402


# --- decide_topology (§14.5) -----------------------------------------
def test_broker_found_means_client():
    found = TP.BrokerFound(host="192.168.1.10", port=8770,
                           auth_mode="required", topology="dedicated")
    d = TP.decide_topology(found)
    assert d.role == TP.ROLE_CLIENT
    assert d.topology == "dedicated"
    assert d.host == "192.168.1.10" and d.port == 8770
    assert d.auth_mode == "required"
    assert d.cohost_broker is False


def test_no_broker_means_p2p_server():
    d = TP.decide_topology(None)
    assert d.role == TP.ROLE_P2P_SERVER
    assert d.topology == TP.P2P
    assert d.listen_port == TP.P2P_LISTEN_PORT
    assert d.host is None  # nothing to dial


def test_cohost_flag_wins_over_discovery():
    # even if a broker is visible, the operator asked us to BE the broker
    found = TP.BrokerFound(host="10.0.0.1", port=8770)
    d = TP.decide_topology(found, cohost=True)
    assert d.role == TP.ROLE_CLIENT
    assert d.topology == TP.COHOSTED
    assert d.cohost_broker is True
    assert d.host == TP.COHOST_BROKER_HOST and d.port == TP.COHOST_BROKER_PORT


def test_cohost_without_discovery():
    d = TP.decide_topology(None, cohost=True, fallback_auth_mode="optional")
    assert d.cohost_broker is True
    assert d.auth_mode == "optional"
    assert d.host == "127.0.0.1"


def test_fallback_auth_mode_for_p2p():
    d = TP.decide_topology(None, fallback_auth_mode="required")
    assert d.auth_mode == "required"
    # bad fallback normalizes to open
    d2 = TP.decide_topology(None, fallback_auth_mode="bogus")
    assert d2.auth_mode == "open"


def test_custom_p2p_port():
    d = TP.decide_topology(None, p2p_listen_port=9999)
    assert d.listen_port == 9999


# --- parse_announce / pick_broker (§7/§14) ---------------------------
def _announce(broker_hint, **extra):
    payload = {"device_id": "win-1", "ip": "192.168.1.5"}
    if broker_hint is not None:
        payload["broker_hint"] = broker_hint
    payload.update(extra)
    return {"type": "announce", "payload": payload}


def test_parse_announce_with_hint():
    env = _announce("192.168.1.10:8770", auth_mode="required",
                    topology="dedicated")
    found = DP.parse_announce(env)
    assert found is not None
    assert found.host == "192.168.1.10" and found.port == 8770
    assert found.auth_mode == "required"
    assert found.topology == "dedicated"


def test_parse_announce_bare_host_uses_default_port():
    found = DP.parse_announce(_announce("192.168.1.10"))
    assert found.host == "192.168.1.10"
    assert found.port == TP.COHOST_BROKER_PORT  # 8770


def test_parse_announce_no_hint_is_none():
    # a p2p peer announces with no broker_hint → not a coordinator
    assert DP.parse_announce(_announce(None)) is None
    assert DP.parse_announce(_announce("")) is None


def test_parse_announce_missing_v12_fields_defaults():
    # a v1.1 announce has no auth_mode/topology → safe defaults
    found = DP.parse_announce(_announce("10.0.0.1:8770"))
    assert found.auth_mode == "open"
    assert found.topology == "dedicated"


def test_parse_announce_wrong_type_or_shape():
    assert DP.parse_announce({"type": "discover", "payload": {}}) is None
    assert DP.parse_announce({"type": "announce"}) is None
    assert DP.parse_announce("not a dict") is None


def test_pick_broker_skips_p2p_peers():
    peers = [_announce(None), _announce(None),
             _announce("10.0.0.7:8770", auth_mode="open")]
    found = DP.pick_broker(peers)
    assert found is not None and found.host == "10.0.0.7"


def test_pick_broker_none_when_all_peers():
    assert DP.pick_broker([_announce(None), _announce(None)]) is None


def test_split_hint_malformed_port():
    host, port = DP._split_hint("10.0.0.1:notaport")
    assert host == "10.0.0.1" and port == TP.COHOST_BROKER_PORT
