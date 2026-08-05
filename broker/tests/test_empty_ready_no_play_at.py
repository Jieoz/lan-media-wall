"""Timeout with zero ready members must NOT fan out play_at.

Regression: check_sync_timeouts always called _emit_play_at(targets=ready).
When ready==[], Python treats the list as falsy and the emit path fell into
the group-addressed else branch — every online box got a play_at for a
session nobody had prepared. Mid-group push then looked like "some screens
start, some don't / start mid-failure".
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
    cfg.update({
        "auth_mode": "open",
        "state_path": os.path.join(tempfile.mkdtemp(), "state.json"),
        "prefetch_barrier_timeout_ms": 5,
    })
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


def _env(type_, payload, frm, to, msg_id=None):
    return {
        "v": 1,
        "type": type_,
        "msg_id": msg_id or f"{type_}-{id(payload)}",
        "ts": envelope.now_ms(),
        "from": frm,
        "to": to,
        "payload": payload,
    }


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


def _types(conn):
    return [envelope.parse(m)["type"] for m in conn.ws.sent]


def _force_expire_all(hub):
    """Move every live session's created_ms into the past so is_expired trips."""
    for s in list(hub.sync._sessions.values()):
        s.created_ms = 0
        s.timeout_ms = 1


def test_timeout_with_zero_ready_emits_no_play_at():
    hub = _hub()
    a = _player(hub, "a", "lobby")
    b = _player(hub, "b", "lobby")
    ctl = _controller(hub)

    prepare_env = _env(
        "prepare",
        {
            "playlist_id": "pl-1",
            "group_id": "lobby",
            "push_id": "push-1",
            "prefetch": True,
            "start_index": 0,
        },
        "controller:ctl",
        "group:lobby",
        msg_id="prep-empty-ready",
    )
    run(hub._dispatch(ctl, prepare_env, t2=envelope.now_ms()))
    assert "prepare" in _types(a)
    assert "prepare" in _types(b)

    # Nobody reports ready=true.
    _force_expire_all(hub)
    a.ws.sent.clear()
    b.ws.sent.clear()
    run(hub.check_sync_timeouts())

    assert _types(a) == [], f"a got unexpected frames: {_types(a)}"
    assert _types(b) == [], f"b got unexpected frames: {_types(b)}"


def test_timeout_with_partial_ready_only_targets_ready_members():
    hub = _hub()
    a = _player(hub, "a", "lobby")
    b = _player(hub, "b", "lobby")
    ctl = _controller(hub)

    prepare_env = _env(
        "prepare",
        {
            "playlist_id": "pl-1",
            "group_id": "lobby",
            "push_id": "push-1",
            "prefetch": True,
        },
        "controller:ctl",
        "group:lobby",
        msg_id="prep-partial",
    )
    run(hub._dispatch(ctl, prepare_env, t2=envelope.now_ms()))

    # Only a is ready.
    run(hub._dispatch(a, _env(
        "ready",
        {"playlist_id": "pl-1", "device_id": "a", "ready": True,
         "prepare_id": "prep-partial"},
        "player:a", "broker"), t2=envelope.now_ms()))

    _force_expire_all(hub)
    a.ws.sent.clear()
    b.ws.sent.clear()
    run(hub.check_sync_timeouts())

    assert "play_at" in _types(a)
    assert "play_at" not in _types(b)


def test_prepare_with_no_online_members_emits_nothing():
    hub = _hub()
    ctl = _controller(hub)
    # No players online for this group.
    run(hub._dispatch(ctl, _env(
        "prepare",
        {"playlist_id": "pl-x", "group_id": "empty-hall", "push_id": "p"},
        "controller:ctl", "group:empty-hall"), t2=envelope.now_ms()))
    # No session should hang open waiting forever with empty expected;
    # and nothing should blow up.
    assert hub.sync.expired_sessions(now_ms=10**12) == []
    # If a session was opened with empty expected, completing it must still
    # not invent targets — covered by the zero-ready case above.
