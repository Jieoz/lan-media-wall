"""§19 config results are bound to the initiating controller and target Player."""
import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import broker as broker_mod  # noqa: E402


class _Conn:
    def __init__(self, role, ident):
        self.role = role
        self.ident = ident
        self.sent = []

    async def send_env(self, env):
        self.sent.append(env)


def _hub(tmp_path):
    cfg = dict(broker_mod.DEFAULTS)
    cfg["state_path"] = str(tmp_path / "state.json")
    return broker_mod.Hub(cfg)


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def test_config_result_is_unicast_and_player_identity_is_authoritative(tmp_path):
    hub = _hub(tmp_path)
    controller = _Conn("controller", "ctl-a")
    observer = _Conn("controller", "ctl-b")
    player = _Conn("player", "dev-a")
    attacker = _Conn("player", "dev-b")
    hub.controllers = {"ctl-a": controller, "ctl-b": observer}
    hub.players = {"dev-a": player, "dev-b": attacker}

    _run(hub._on_configure_device(controller, {
        "type": "transport_configure",
        "payload": {"request_id": "req-1", "device_id": "dev-a",
                    "broker_host": "", "transport_mode": "p2p"},
    }))
    assert len(player.sent) == 1

    result = {"type": "config_patch_result", "payload": {
        "request_id": "req-1", "device_id": "spoofed", "ok": True,
        "revision": 7, "applied": {"transport_mode": "p2p"},
    }}
    _run(hub._on_config_result(attacker, result))
    assert controller.sent == []

    _run(hub._on_config_result(player, result))
    assert len(controller.sent) == 1
    assert observer.sent == []
    assert controller.sent[0]["payload"]["device_id"] == "dev-a"
    assert controller.sent[0]["to"] == "controller:ctl-a"

    _run(hub._on_config_result(player, result))
    assert len(controller.sent) == 1, "terminal result replay must be dropped"


def test_config_request_id_collision_is_fail_closed(tmp_path):
    hub = _hub(tmp_path)
    first = _Conn("controller", "ctl-a")
    second = _Conn("controller", "ctl-b")
    player = _Conn("player", "dev-a")
    hub.players = {"dev-a": player}

    base = {"type": "transport_configure", "payload": {
        "request_id": "same", "device_id": "dev-a",
        "broker_host": "", "transport_mode": "p2p"}}
    _run(hub._on_configure_device(first, base))
    _run(hub._on_configure_device(second, base))
    assert len(player.sent) == 1
