"""Broker routing for remote log download + debug snapshot (§debug).

Regression guard: the broker dispatch table must forward the controller->player
requests (debug_snapshot / download_logs) to the addressed player AND relay the
player->controller results (diagnostic_status / download_logs_result) back to
controllers. When these types are missing from the dispatch table the handler is
None and the frame is silently dropped, so the controller's pending completer
always hits its timeout.
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


def test_debug_snapshot_routes_from_controller_to_target_player():
    hub, path = _hub()
    try:
        controller = FakeConn("controller", "ctl-1")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-1"] = controller
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")

        env = hub.make_env("debug_snapshot", {"device_id": "dev-1"}, "broker")
        _run(hub._dispatch(controller, env, 0))

        assert len(player.sent) == 1
        assert player.sent[0]["type"] == "debug_snapshot"
        assert player.sent[0]["to"] == "player:dev-1"
    finally:
        os.path.exists(path) and os.unlink(path)


def test_download_logs_routes_from_controller_to_target_player():
    hub, path = _hub()
    try:
        controller = FakeConn("controller", "ctl-1")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-1"] = controller
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")

        env = hub.make_env("download_logs", {"device_id": "dev-1"}, "broker")
        _run(hub._dispatch(controller, env, 0))

        assert len(player.sent) == 1
        assert player.sent[0]["type"] == "download_logs"
        assert player.sent[0]["to"] == "player:dev-1"
    finally:
        os.path.exists(path) and os.unlink(path)


def test_diagnostic_status_relays_player_result_to_controllers():
    hub, path = _hub()
    try:
        controller = FakeConn("controller", "ctl-1")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-1"] = controller
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")

        env = hub.make_env(
            "diagnostic_status",
            {"device_id": "dev-1", "detail": "v=1.13.4; play=playing"},
            "broker",
        )
        _run(hub._dispatch(player, env, 0))

        assert len(controller.sent) == 1
        assert controller.sent[0]["type"] == "diagnostic_status"
        assert controller.sent[0]["payload"]["device_id"] == "dev-1"
        assert controller.sent[0]["payload"]["detail"].startswith("v=1.13.4")
    finally:
        os.path.exists(path) and os.unlink(path)


def test_download_logs_result_relays_player_result_to_controllers():
    hub, path = _hub()
    try:
        controller = FakeConn("controller", "ctl-1")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-1"] = controller
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")

        env = hub.make_env(
            "download_logs_result",
            {
                "device_id": "dev-1",
                "text": "line-a\nline-b\n",
                "file_name": "player-dev-1.log",
            },
            "broker",
        )
        _run(hub._dispatch(player, env, 0))

        assert len(controller.sent) == 1
        assert controller.sent[0]["type"] == "download_logs_result"
        assert controller.sent[0]["payload"]["file_name"] == "player-dev-1.log"
        assert "line-a" in controller.sent[0]["payload"]["text"]
    finally:
        os.path.exists(path) and os.unlink(path)


def test_result_frames_from_controller_are_not_relayed():
    """A controller must not be able to spoof a player result back to peers."""
    hub, path = _hub()
    try:
        controller = FakeConn("controller", "ctl-1")
        other = FakeConn("controller", "ctl-2")
        hub.controllers["ctl-1"] = controller
        hub.controllers["ctl-2"] = other

        env = hub.make_env(
            "diagnostic_status", {"device_id": "dev-x", "detail": "spoof"},
            "broker")
        _run(hub._dispatch(controller, env, 0))

        assert other.sent == []
    finally:
        os.path.exists(path) and os.unlink(path)
