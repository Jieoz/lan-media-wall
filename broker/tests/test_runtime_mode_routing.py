"""Role-safe Broker routing for playback mode and device-local music lists."""
import asyncio
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import broker as broker_mod  # noqa: E402


class FakeConn:
    def __init__(self, role, ident):
        self.role = role
        self.ident = ident
        self.addr = f"{role}:{ident}"
        self.sent = []

    async def send_env(self, env):
        self.sent.append(env)


def _hub():
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    os.unlink(path)
    cfg = dict(broker_mod.DEFAULTS)
    cfg["state_path"] = path
    return broker_mod.Hub(cfg), path


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def test_group_standby_routes_to_each_player_and_result_returns_only_to_initiator():
    hub, path = _hub()
    try:
        ctl = FakeConn("controller", "ctl-a")
        other = FakeConn("controller", "ctl-b")
        a = FakeConn("player", "a")
        b = FakeConn("player", "b")
        hub.controllers.update({"ctl-a": ctl, "ctl-b": other})
        hub.players.update({"a": a, "b": b})
        hub.reg.register("a", group_id="lobby")
        hub.reg.register("b", group_id="lobby")
        request = hub.make_env("set_runtime_mode", {
            "request_id": "mode-1", "group_id": "lobby", "mode": "standby",
        }, "group:lobby")
        _run(hub._dispatch(ctl, request, 0))
        assert [e["type"] for e in a.sent] == ["set_runtime_mode"]
        assert [e["type"] for e in b.sent] == ["set_runtime_mode"]
        for conn, device in ((a, "a"), (b, "b")):
            result = hub.make_env("runtime_mode_result", {
                "request_id": "mode-1", "device_id": device,
                "ok": True, "mode": "standby",
            }, "controller:ctl-a")
            _run(hub._dispatch(conn, result, 0))
        assert {e["payload"]["device_id"] for e in ctl.sent} == {"a", "b"}
        assert other.sent == []
    finally:
        if os.path.exists(path): os.unlink(path)


def test_music_playlist_is_single_device_and_rejects_forged_result():
    hub, path = _hub()
    try:
        ctl = FakeConn("controller", "ctl")
        player = FakeConn("player", "dev")
        rogue = FakeConn("player", "rogue")
        hub.controllers["ctl"] = ctl
        hub.players.update({"dev": player, "rogue": rogue})
        hub.reg.register("dev", group_id="default")
        request = hub.make_env("music_playlist", {
            "request_id": "music-7", "device_id": "dev",
            "playlist_id": "music-dev", "revision": 7, "items": [],
        }, "player:dev")
        _run(hub._dispatch(ctl, request, 0))
        assert [e["type"] for e in player.sent] == ["music_playlist"]
        forged = hub.make_env("music_playlist_result", {
            "request_id": "music-7", "device_id": "dev", "ok": True,
            "revision": 7,
        }, "controller:ctl")
        _run(hub._dispatch(rogue, forged, 0))
        assert ctl.sent == []
        _run(hub._dispatch(player, forged, 0))
        assert len(ctl.sent) == 1
        assert ctl.sent[0]["type"] == "music_playlist_result"
    finally:
        if os.path.exists(path): os.unlink(path)


def test_player_cannot_forge_mode_request_and_unknown_result_is_dropped():
    hub, path = _hub()
    try:
        ctl = FakeConn("controller", "ctl")
        victim = FakeConn("player", "victim")
        rogue = FakeConn("player", "rogue")
        hub.controllers["ctl"] = ctl
        hub.players.update({"victim": victim, "rogue": rogue})
        hub.reg.register("victim", group_id="default")
        request = hub.make_env("set_runtime_mode", {
            "request_id": "evil", "device_id": "victim", "mode": "standby",
        }, "player:victim")
        _run(hub._dispatch(rogue, request, 0))
        assert victim.sent == []
        unknown = hub.make_env("runtime_mode_result", {
            "request_id": "ghost", "device_id": "rogue", "ok": True,
            "mode": "standby",
        }, "controller:ctl")
        _run(hub._dispatch(rogue, unknown, 0))
        assert ctl.sent == []
    finally:
        if os.path.exists(path): os.unlink(path)
