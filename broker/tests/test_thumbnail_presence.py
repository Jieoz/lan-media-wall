"""Regression coverage for thumbnail delivery after transport changes."""
import asyncio
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
import broker as broker_mod  # noqa: E402


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send(self, data):
        self.sent.append(data)
        await asyncio.sleep(0)


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def _hub():
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    os.unlink(path)
    cfg = dict(broker_mod.DEFAULTS)
    cfg["state_path"] = path
    return broker_mod.Hub(cfg), path


def test_thumb_meta_and_jpeg_are_sent_as_one_locked_pair():
    async def scenario():
        ws = FakeWS()
        conn = broker_mod.ClientConn(ws, "10.0.0.2")
        meta = {"type": "thumb_meta", "payload": {"device_id": "d", "bytes": 3}}
        other = {"type": "wall", "payload": {}}
        await asyncio.gather(conn.send_thumb(meta, b"jpg"), conn.send_env(other))
        assert len(ws.sent) == 3
        decoded = [json.loads(x) if isinstance(x, str) else x for x in ws.sent]
        thumb_index = next(i for i, value in enumerate(decoded)
                           if isinstance(value, dict) and value.get("type") == "thumb_meta")
        assert decoded[thumb_index + 1] == b"jpg"

    _run(scenario())


def test_hub_binds_thumbnail_to_authenticated_player_identity():
    async def scenario():
        hub, path = _hub()
        try:
            player = broker_mod.ClientConn(FakeWS(), "10.0.0.3")
            player.role = "player"
            player.ident = "real-device"
            player.pending_thumb = hub.make_env("thumb_meta", {
                "device_id": "spoofed-device", "bytes": 3,
            }, "all")
            controller_ws = FakeWS()
            controller = broker_mod.ClientConn(controller_ws, "10.0.0.4")
            controller.role = "controller"
            controller.ident = "ctl-1"
            hub.controllers[controller.ident] = controller

            await hub._handle_binary(player, b"jpg")

            assert len(controller_ws.sent) == 2
            meta = json.loads(controller_ws.sent[0])
            assert meta["payload"]["device_id"] == "real-device"
            assert controller_ws.sent[1] == b"jpg"
        finally:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass

    _run(scenario())


def test_hub_drops_thumbnail_when_declared_length_does_not_match_binary():
    async def scenario():
        hub, path = _hub()
        try:
            player = broker_mod.ClientConn(FakeWS(), "10.0.0.3")
            player.role = "player"
            player.ident = "real-device"
            player.pending_thumb = hub.make_env("thumb_meta", {
                "device_id": "real-device", "bytes": 4,
            }, "all")
            controller_ws = FakeWS()
            controller = broker_mod.ClientConn(controller_ws, "10.0.0.4")
            controller.role = "controller"
            controller.ident = "ctl-1"
            hub.controllers[controller.ident] = controller

            await hub._handle_binary(player, b"jpg")

            assert controller_ws.sent == []
            assert player.pending_thumb is None
        finally:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass

    _run(scenario())


def test_second_thumb_meta_invalidates_pair_instead_of_rebinding_binary():
    async def scenario():
        hub, path = _hub()
        try:
            player = broker_mod.ClientConn(FakeWS(), "10.0.0.3")
            player.role = "player"
            player.ident = "real-device"
            first = hub.make_env("thumb_meta", {
                "device_id": "real-device", "item_id": "first", "bytes": 3,
            }, "all")
            second = hub.make_env("thumb_meta", {
                "device_id": "real-device", "item_id": "second", "bytes": 3,
            }, "all")
            controller_ws = FakeWS()
            controller = broker_mod.ClientConn(controller_ws, "10.0.0.4")
            controller.role = "controller"
            controller.ident = "ctl-1"
            hub.controllers[controller.ident] = controller

            await hub._on_thumb_meta(player, first)
            await hub._on_thumb_meta(player, second)
            await hub._handle_binary(player, b"jpg")

            assert controller_ws.sent == []
            assert player.pending_thumb is None
        finally:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass

    _run(scenario())


def test_controller_join_and_leave_broadcast_presence_to_existing_players():
    async def scenario():
        hub, path = _hub()
        try:
            player_ws = FakeWS()
            player = broker_mod.ClientConn(player_ws, "10.0.0.3")
            player.role = "player"
            player.ident = "dev-1"
            player.addr = "player:dev-1"
            hub.players[player.ident] = player

            controller_ws = FakeWS()
            controller = broker_mod.ClientConn(controller_ws, "10.0.0.4")
            hello = hub.make_env("hello", {
                "role": "controller", "controller_id": "ctl-1",
            }, "broker")
            await hub._on_hello(controller, hello)
            joined = json.loads(player_ws.sent[-1])
            assert joined["type"] == "controller_presence"
            assert joined["payload"]["present"] is True
            assert joined["payload"]["controllers_online"] == 1

            await hub._cleanup(controller)
            left = json.loads(player_ws.sent[-1])
            assert left["type"] == "controller_presence"
            assert left["payload"]["present"] is False
            assert left["payload"]["controllers_online"] == 0
        finally:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass

    _run(scenario())
