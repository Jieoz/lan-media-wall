"""§6.3 broker forwarding parity for the v1.15.0 playlist contract.

The broker is opaque for playlist bodies: it caches only playlist_id/sync into
group meta and forwards the payload verbatim. These tests pin that the new
loop_mode / mode / items fields reach players untouched, so loop semantics stay
a controller+player concern and the broker never needs per-field awareness.
"""
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


def _wire_group(hub):
    controller = FakeConn("controller", "ctl-1")
    player = FakeConn("player", "dev-1")
    hub.controllers["ctl-1"] = controller
    hub.players["dev-1"] = player
    hub.reg.register("dev-1", group_id="lobby")
    return controller, player


def test_loop_mode_forwarded_verbatim():
    hub, path = _hub()
    try:
        controller, player = _wire_group(hub)
        payload = {
            "playlist_id": "pl-1", "group_id": "lobby", "sync": True,
            "loop_mode": "one", "loop": True, "mode": "replace",
            "items": [{"item_id": "a", "type": "video", "url": "http://x/a"}],
        }
        env = hub.make_env("playlist", payload, "group:lobby")
        _run(hub._dispatch(controller, env, 0))

        assert len(player.sent) == 1
        fwd = player.sent[0]
        assert fwd["type"] == "playlist"
        # every field survives opaque forwarding
        assert fwd["payload"]["loop_mode"] == "one"
        assert fwd["payload"]["loop"] is True
        assert fwd["payload"]["mode"] == "replace"
        assert fwd["payload"]["items"] == payload["items"]
    finally:
        os.path.exists(path) and os.unlink(path)


def test_append_mode_forwarded_verbatim():
    hub, path = _hub()
    try:
        controller, player = _wire_group(hub)
        payload = {
            "playlist_id": "pl-1", "group_id": "lobby",
            "mode": "append", "loop_mode": "all",
            "items": [{"item_id": "b", "type": "image", "url": "http://x/b"}],
        }
        env = hub.make_env("playlist", payload, "group:lobby")
        _run(hub._dispatch(controller, env, 0))
        assert player.sent[0]["payload"]["mode"] == "append"
        assert player.sent[0]["payload"]["loop_mode"] == "all"
    finally:
        os.path.exists(path) and os.unlink(path)


def test_empty_replace_clear_forwarded_verbatim():
    hub, path = _hub()
    try:
        controller, player = _wire_group(hub)
        # empty replace = CLEAR: broker still just forwards; the player enacts.
        payload = {"playlist_id": "pl-1", "group_id": "lobby",
                   "mode": "replace", "items": []}
        env = hub.make_env("playlist", payload, "group:lobby")
        _run(hub._dispatch(controller, env, 0))
        assert player.sent[0]["payload"]["items"] == []
        assert player.sent[0]["payload"]["mode"] == "replace"
    finally:
        os.path.exists(path) and os.unlink(path)
