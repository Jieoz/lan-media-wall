"""Broker role-safe routing for cache_cleanup / cache_inventory (§27/§28, TB3).

Direction + role are enforced per handler:
  - cache_cleanup / cache_inventory: controller->player ONLY (fan-out by
    device_id/group_id/all like debug_snapshot). A player forging a request is
    rejected.
  - cache_cleanup_result / cache_inventory_result: player->controller ONLY, and
    UNICAST to the INITIATING controller (role-security req #6) — NOT broadcast
    to every controller like diagnostic_status. A controller forging a result is
    rejected. A result whose request_id has no recorded origin is dropped, never
    broadcast.
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


# --- request routing: controller -> player ------------------------------
def test_cache_cleanup_routes_controller_to_target_player():
    hub, path = _hub()
    try:
        ctl = FakeConn("controller", "ctl-1")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-1"] = ctl
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")

        env = hub.make_env("cache_cleanup",
                           {"device_id": "dev-1", "request_id": "r1",
                            "mode": "unreferenced"}, "broker")
        _run(hub._dispatch(ctl, env, 0))

        assert len(player.sent) == 1
        assert player.sent[0]["type"] == "cache_cleanup"
        assert player.sent[0]["to"] == "player:dev-1"
        assert player.sent[0]["payload"]["request_id"] == "r1"
    finally:
        os.unlink(path) if os.path.exists(path) else None


def test_cache_inventory_routes_controller_to_target_player():
    hub, path = _hub()
    try:
        ctl = FakeConn("controller", "ctl-1")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-1"] = ctl
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")

        env = hub.make_env("cache_inventory",
                           {"device_id": "dev-1", "request_id": "inv-1"},
                           "broker")
        _run(hub._dispatch(ctl, env, 0))
        assert len(player.sent) == 1
        assert player.sent[0]["type"] == "cache_inventory"
    finally:
        os.unlink(path) if os.path.exists(path) else None


def test_player_forged_cache_cleanup_request_rejected():
    """A player must not be able to issue a controller->player request."""
    hub, path = _hub()
    try:
        rogue = FakeConn("player", "dev-evil")
        victim = FakeConn("player", "dev-1")
        hub.players["dev-evil"] = rogue
        hub.players["dev-1"] = victim
        hub.reg.register("dev-1", group_id="default")

        env = hub.make_env("cache_cleanup",
                           {"device_id": "dev-1", "request_id": "r1"}, "broker")
        _run(hub._dispatch(rogue, env, 0))
        assert victim.sent == []
    finally:
        os.unlink(path) if os.path.exists(path) else None


# --- result routing: player -> the INITIATING controller only -----------
def test_cache_cleanup_result_unicasts_to_initiating_controller_only():
    hub, path = _hub()
    try:
        ctl_a = FakeConn("controller", "ctl-A")
        ctl_b = FakeConn("controller", "ctl-B")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-A"] = ctl_a
        hub.controllers["ctl-B"] = ctl_b
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")

        # ctl-A initiates the request → broker records the origin.
        req = hub.make_env("cache_cleanup",
                          {"device_id": "dev-1", "request_id": "r1"}, "broker")
        _run(hub._dispatch(ctl_a, req, 0))
        fingerprint = hub._cleanup_fingerprint(req["payload"])

        # player replies with the terminal result.
        res = hub.make_env("cache_cleanup_result",
                          {"device_id": "dev-1", "request_id": "r1", "ok": True,
                           "operation_fingerprint": fingerprint},
                          "broker")
        _run(hub._dispatch(player, res, 0))

        assert len(ctl_a.sent) == 1
        assert ctl_a.sent[0]["type"] == "cache_cleanup_result"
        assert ctl_a.sent[0]["payload"]["request_id"] == "r1"
        # ctl-B never asked → must NOT receive the result.
        assert ctl_b.sent == []
    finally:
        os.unlink(path) if os.path.exists(path) else None


def test_cache_cleanup_result_with_unknown_request_is_dropped_not_broadcast():
    hub, path = _hub()
    try:
        ctl = FakeConn("controller", "ctl-1")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-1"] = ctl
        hub.players["dev-1"] = player

        res = hub.make_env("cache_cleanup_result",
                          {"device_id": "dev-1", "request_id": "ghost",
                           "ok": True}, "broker")
        _run(hub._dispatch(player, res, 0))
        assert ctl.sent == [], "unknown request_id must not broadcast to all"
    finally:
        os.unlink(path) if os.path.exists(path) else None


def test_cache_cleanup_result_with_wrong_fingerprint_is_dropped():
    hub, path = _hub()
    try:
        ctl = FakeConn("controller", "ctl-1")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-1"] = ctl
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")
        req = hub.make_env("cache_cleanup",
                           {"device_id": "dev-1", "request_id": "r1",
                            "mode": "selected", "item_ids": ["a"],
                            "dry_run": False, "expected_push_id": "gen-1"},
                           "broker")
        _run(hub._dispatch(ctl, req, 0))
        forged = hub.make_env("cache_cleanup_result",
                              {"device_id": "dev-1", "request_id": "r1",
                               "ok": True, "operation_fingerprint": "wrong"},
                              "broker")
        _run(hub._dispatch(player, forged, 0))
        assert ctl.sent == []
    finally:
        os.unlink(path) if os.path.exists(path) else None


def test_controller_forged_cache_cleanup_result_rejected():
    """A controller must not be able to forge a player->controller result."""
    hub, path = _hub()
    try:
        rogue = FakeConn("controller", "ctl-evil")
        victim = FakeConn("controller", "ctl-1")
        hub.controllers["ctl-evil"] = rogue
        hub.controllers["ctl-1"] = victim

        env = hub.make_env("cache_cleanup_result",
                          {"device_id": "dev-1", "request_id": "r1",
                           "ok": True}, "broker")
        _run(hub._dispatch(rogue, env, 0))
        assert victim.sent == []
    finally:
        os.unlink(path) if os.path.exists(path) else None


def test_cache_inventory_result_unicasts_to_initiating_controller():
    hub, path = _hub()
    try:
        ctl_a = FakeConn("controller", "ctl-A")
        ctl_b = FakeConn("controller", "ctl-B")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-A"] = ctl_a
        hub.controllers["ctl-B"] = ctl_b
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")

        req = hub.make_env("cache_inventory",
                          {"device_id": "dev-1", "request_id": "inv-9"},
                          "broker")
        _run(hub._dispatch(ctl_a, req, 0))
        res = hub.make_env("cache_inventory_result",
                          {"device_id": "dev-1", "request_id": "inv-9",
                           "items": []}, "broker")
        _run(hub._dispatch(player, res, 0))
        assert len(ctl_a.sent) == 1
        assert ctl_b.sent == []
    finally:
        os.unlink(path) if os.path.exists(path) else None


def test_two_devices_same_request_id_are_isolated():
    """Same request_id fanned to two devices: each device's result goes to the
    initiating controller, and correlation is per (request_id) origin — the
    origin is the controller, both results reach it, once each."""
    hub, path = _hub()
    try:
        ctl = FakeConn("controller", "ctl-1")
        d1 = FakeConn("player", "dev-1")
        d2 = FakeConn("player", "dev-2")
        hub.controllers["ctl-1"] = ctl
        hub.players["dev-1"] = d1
        hub.players["dev-2"] = d2
        hub.reg.register("dev-1", group_id="g")
        hub.reg.register("dev-2", group_id="g")

        req = hub.make_env("cache_cleanup",
                          {"group_id": "g", "request_id": "rG"}, "broker")
        _run(hub._dispatch(ctl, req, 0))
        fingerprint = hub._cleanup_fingerprint(req["payload"])
        assert len(d1.sent) == 1 and len(d2.sent) == 1

        for dev in ("dev-1", "dev-2"):
            res = hub.make_env("cache_cleanup_result",
                              {"device_id": dev, "request_id": "rG",
                               "ok": True, "operation_fingerprint": fingerprint},
                              "broker")
            _run(hub._dispatch(d1 if dev == "dev-1" else d2, res, 0))
        assert len(ctl.sent) == 2
        got = {e["payload"]["device_id"] for e in ctl.sent}
        assert got == {"dev-1", "dev-2"}
    finally:
        os.unlink(path) if os.path.exists(path) else None


def test_conflicting_request_id_is_rejected_before_player_fanout():
    hub, path = _hub()
    try:
        ctl_a = FakeConn("controller", "ctl-A")
        ctl_b = FakeConn("controller", "ctl-B")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-A"] = ctl_a
        hub.controllers["ctl-B"] = ctl_b
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")
        first = {"device_id": "dev-1", "request_id": "same",
                 "mode": "selected", "item_ids": ["a"], "dry_run": True,
                 "expected_push_id": "gen-1"}
        conflict = {"device_id": "dev-1", "request_id": "same",
                    "mode": "selected", "item_ids": ["b"], "dry_run": False,
                    "expected_push_id": "gen-2"}
        _run(hub._dispatch(ctl_a, hub.make_env("cache_cleanup", first, "broker"), 0))
        _run(hub._dispatch(ctl_b, hub.make_env("cache_cleanup", conflict, "broker"), 0))
        assert len(player.sent) == 1
        assert player.sent[0]["payload"]["item_ids"] == ["a"]
    finally:
        os.unlink(path) if os.path.exists(path) else None


def test_same_owner_request_id_cannot_change_operation_payload():
    hub, path = _hub()
    try:
        ctl = FakeConn("controller", "ctl-1")
        player = FakeConn("player", "dev-1")
        hub.controllers["ctl-1"] = ctl
        hub.players["dev-1"] = player
        hub.reg.register("dev-1", group_id="default")
        base = {"device_id": "dev-1", "request_id": "same",
                "mode": "selected", "item_ids": ["a"], "dry_run": True,
                "expected_push_id": "gen-1"}
        _run(hub._dispatch(ctl, hub.make_env("cache_cleanup", base, "broker"), 0))
        _run(hub._dispatch(ctl, hub.make_env(
            "cache_cleanup", dict(base, dry_run=False), "broker"), 0))
        assert len(player.sent) == 1
    finally:
        os.unlink(path) if os.path.exists(path) else None
