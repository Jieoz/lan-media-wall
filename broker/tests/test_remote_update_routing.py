"""Broker routing for remote self-update (§23)."""
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


def test_update_app_routes_from_controller_to_target_player():
    hub, path = _hub()
    try:
        controller = FakeConn("controller", "ctl-1")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-1"] = controller
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")

        env = hub.make_env("update_app", {
            "device_id": "dev-1",
            "version_code": 26,
            "url": "http://broker:8773/media/app.apk",
            "sha256": "a" * 64,
        }, "broker")

        _run(hub._dispatch(controller, env, 0))

        assert len(player.sent) == 1
        assert player.sent[0]["type"] == "update_app"
        assert player.sent[0]["to"] == "player:dev-1"
        assert player.sent[0]["payload"]["version_code"] == 26
    finally:
        os.path.exists(path) and os.unlink(path)


def test_update_status_updates_registry_and_wall_dirty():
    hub, path = _hub()
    try:
        player = FakeConn("player", "dev-1")
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")
        hub._wall_dirty = False
        env = hub.make_env("update_status", {
            "device_id": "dev-1",
            "state": "downloading",
            "detail": "42%",
            "version_code": 25,
        }, "broker")

        _run(hub._dispatch(player, env, 0))

        dev = hub.reg.get("dev-1")
        assert dev.last_status["update_state"] == "downloading"
        assert dev.last_status["update_detail"] == "42%"
        assert dev.last_status["update_version_code"] == 25
        assert hub._wall_dirty is True
    finally:
        os.path.exists(path) and os.unlink(path)
