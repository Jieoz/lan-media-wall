"""§9.4b single-device prepare targeting + §9.4 restart routing.

A prepare carrying `device_id` must open a ready session for ONLY that device
and emit play_at to only that device — group siblings are untouched. restart
must be routed to the addressed player like the other transport verbs.
"""
import asyncio
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import broker as broker_mod  # noqa: E402
import envelope  # noqa: E402


def _hub(**over):
    cfg = dict(broker_mod.DEFAULTS)
    cfg.update({"auth_mode": "open",
                "state_path": os.path.join(tempfile.mkdtemp(), "state.json")})
    cfg.update(over)
    cfg["auth_mode"] = envelope.normalize_auth_mode(cfg["auth_mode"])
    cfg["key_mode"] = envelope.normalize_key_mode(cfg["key_mode"])
    return broker_mod.Hub(cfg)


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send(self, data):
        self.sent.append(data)

    async def close(self, code=1000, reason=""):
        pass


def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def _env(type_, payload, frm, to):
    return {"v": 1, "type": type_, "msg_id": f"{type_}-{id(payload)}",
            "ts": envelope.now_ms(), "from": frm, "to": to, "payload": payload}


def _player(hub, dev, group):
    conn = broker_mod.ClientConn(FakeWS(), "10.0.0.1")
    run(hub._dispatch(conn, _env(
        "hello", {"role": "player", "device_id": dev, "group_id": group},
        f"player:{dev}", "broker"), t2=envelope.now_ms()))
    return conn


def _controller(hub):
    conn = broker_mod.ClientConn(FakeWS(), "10.0.0.2")
    run(hub._dispatch(conn, _env(
        "hello", {"role": "controller", "controller_id": "ctl"},
        "controller:ctl", "broker"), t2=envelope.now_ms()))
    return conn


def _play_at_types(conn):
    return [envelope.parse(m)["type"] for m in conn.ws.sent
            if envelope.parse(m)["type"] == "play_at"]


def test_unicast_prepare_targets_only_that_device():
    hub = _hub()
    a = _player(hub, "a", "lobby")
    b = _player(hub, "b", "lobby")
    ctl = _controller(hub)
    # controller → prepare with device_id=a (barrier off, short timeout).
    prepare_env = _env(
        "prepare",
        {"playlist_id": "pl-1", "group_id": "lobby", "device_id": "a"},
        "controller:ctl", "player:a")
    run(hub._dispatch(ctl, prepare_env, t2=envelope.now_ms()))
    # only "a" received the prepare fan-out.
    a_types = [envelope.parse(m)["type"] for m in a.ws.sent]
    b_types = [envelope.parse(m)["type"] for m in b.ws.sent]
    assert "prepare" in a_types
    assert "prepare" not in b_types
    prepare_wire = next(envelope.parse(m) for m in a.ws.sent
                        if envelope.parse(m)["type"] == "prepare")
    assert prepare_wire["payload"]["prepare_id"] == prepare_env["msg_id"]
    assert prepare_wire["payload"]["sync_session_id"] == prepare_env["msg_id"]
    # "a" reports ready → play_at goes to a only, not b.
    run(hub._dispatch(a, _env(
        "ready", {"playlist_id": "pl-1", "device_id": "a", "ready": True},
        "player:a", "broker"), t2=envelope.now_ms()))
    assert _play_at_types(a) == ["play_at"]
    assert _play_at_types(b) == []
    play_at = next(envelope.parse(m) for m in a.ws.sent
                   if envelope.parse(m)["type"] == "play_at")
    assert play_at["payload"]["sync_session_id"] == prepare_env["msg_id"]


def test_group_prepare_still_reaches_all_members():
    hub = _hub()
    a = _player(hub, "a", "lobby")
    b = _player(hub, "b", "lobby")
    ctl = _controller(hub)
    run(hub._dispatch(ctl, _env(
        "prepare", {"playlist_id": "pl-1", "group_id": "lobby"},
        "controller:ctl", "group:lobby"), t2=envelope.now_ms()))
    assert "prepare" in [envelope.parse(m)["type"] for m in a.ws.sent]
    assert "prepare" in [envelope.parse(m)["type"] for m in b.ws.sent]


def test_restart_routed_to_player():
    hub = _hub()
    a = _player(hub, "a", "lobby")
    ctl = _controller(hub)
    run(hub._dispatch(ctl, _env(
        "restart", {"device_id": "a"},
        "controller:ctl", "player:a"), t2=envelope.now_ms()))
    assert "restart" in [envelope.parse(m)["type"] for m in a.ws.sent]
