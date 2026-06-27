"""Player transport-role selection (§14.5) with a mocked discovery probe.

The brief requires the auto-discovery decision (find broker → client; none →
p2p server) to be unit-tested as pure logic. Player._discover_decision is the
integration point; we mock the probe result and the OS subsystems so the test
stays pure (no sockets, no mpv, no websockets I/O)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config as C  # noqa: E402
import main as M  # noqa: E402
import topology as TP  # noqa: E402


def _player(tmp_path, **cfg_over):
    raw = dict(C.DEFAULTS)
    raw["state_dir"] = str(tmp_path / "state")
    raw["cache_dir"] = str(tmp_path / "cache")
    raw.update(cfg_over)
    cfg = C.Config(raw=raw)
    return M.Player(cfg)


def test_decision_client_when_broker_found(tmp_path, monkeypatch):
    p = _player(tmp_path)
    found = TP.BrokerFound(host="192.168.1.10", port=8770,
                           auth_mode="required", topology="dedicated")
    monkeypatch.setattr(M.discovery_probe_mod, "probe_for_broker",
                        lambda **kw: found)
    d = p._discover_decision()
    assert d.role == TP.ROLE_CLIENT
    assert d.host == "192.168.1.10"
    assert d.auth_mode == "required"


def test_decision_p2p_server_when_no_broker(tmp_path, monkeypatch):
    p = _player(tmp_path)
    monkeypatch.setattr(M.discovery_probe_mod, "probe_for_broker",
                        lambda **kw: None)
    d = p._discover_decision()
    assert d.role == TP.ROLE_P2P_SERVER
    assert d.topology == TP.P2P
    assert d.listen_port == 8770


def test_decision_cohost_skips_probe(tmp_path, monkeypatch):
    p = _player(tmp_path)
    p.cohost = True

    def _boom(**kw):
        raise AssertionError("probe must not run when cohosting")

    monkeypatch.setattr(M.discovery_probe_mod, "probe_for_broker", _boom)
    d = p._discover_decision()
    assert d.cohost_broker is True
    assert d.topology == TP.COHOSTED


def test_decision_probe_exception_falls_back_to_p2p(tmp_path, monkeypatch):
    p = _player(tmp_path)

    def _raise(**kw):
        raise OSError("network down")

    monkeypatch.setattr(M.discovery_probe_mod, "probe_for_broker", _raise)
    d = p._discover_decision()
    # probe failed, auto on → no broker found → p2p server
    assert d.role == TP.ROLE_P2P_SERVER


def test_decision_auto_off_uses_configured_broker(tmp_path, monkeypatch):
    raw_topo = dict(C.DEFAULTS["topology"])
    raw_topo["auto"] = False
    p = _player(tmp_path, topology=raw_topo,
                broker={"host": "10.9.9.9", "port": 8770, "use_wss": False})
    # probe should not even be consulted, but guard anyway
    monkeypatch.setattr(M.discovery_probe_mod, "probe_for_broker",
                        lambda **kw: None)
    d = p._discover_decision()
    assert d.role == TP.ROLE_CLIENT
    assert d.host == "10.9.9.9"


def test_build_transport_p2p_returns_server(tmp_path, monkeypatch):
    p = _player(tmp_path)
    d = TP.decide_topology(None, fallback_auth_mode="open")
    transport = p._build_transport(d)
    assert isinstance(transport, M.P2PServer)
    assert p.auth.mode == "open"


def test_build_transport_client_returns_broker_client(tmp_path):
    p = _player(tmp_path)
    found = TP.BrokerFound(host="10.0.0.1", port=8770, auth_mode="optional")
    d = TP.decide_topology(found)
    transport = p._build_transport(d)
    assert isinstance(transport, M.BrokerClient)
    assert transport.url == "ws://10.0.0.1:8770"
    # player adopted the discovered broker's auth mode
    assert p.auth.mode == "optional"


def test_build_transport_adopts_broker_key_mode(tmp_path):
    # §17.3: a derived-mode broker discovered → player adopts key_mode=derived.
    p = _player(tmp_path)
    found = TP.BrokerFound(host="10.0.0.1", port=8770, auth_mode="required",
                           key_mode="derived")
    d = TP.decide_topology(found)
    assert d.key_mode == "derived"
    p._build_transport(d)
    assert p.auth.key_mode == "derived"


def test_p2p_decision_carries_fallback_key_mode(tmp_path, monkeypatch):
    p = _player(tmp_path)
    p.auth.key_mode = "derived"  # locally configured derived
    monkeypatch.setattr(M.discovery_probe_mod, "probe_for_broker",
                        lambda **kw: None)
    d = p._discover_decision()
    assert d.role == TP.ROLE_P2P_SERVER
    assert d.key_mode == "derived"  # we are coordinator → keep our key_mode
