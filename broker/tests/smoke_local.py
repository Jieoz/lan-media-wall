"""End-to-end smoke test: start a real broker in-process, connect one player
and one controller over WebSocket, and exercise the core flows:

  1. hello -> welcome (player + controller)
  2. status -> wall snapshot pushed to controller
  3. time_sync -> time_sync_ack round-trip (offset/rtt computed)
  4. full prepare -> ready -> play_at synchronized-start handshake

Run:  python3 tests/smoke_local.py
Exits non-zero on any failed assertion.
"""
import asyncio
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import websockets

import broker as broker_mod
import clock
import envelope

PSK = "smoke" * 8  # 40 chars
HOST = "127.0.0.1"
PORT = 8790  # off the default port to avoid clashes


def env(type_, payload, from_, to):
    return envelope.dumps(
        envelope.build_envelope(type_, payload, from_, to, PSK))


async def recv_type(ws, want, timeout=5.0):
    """Receive text frames until one of type `want` arrives."""
    while True:
        raw = await asyncio.wait_for(ws.recv(), timeout)
        if isinstance(raw, (bytes, bytearray)):
            continue
        e = envelope.parse(raw)
        assert envelope.verify_sig(e, PSK), "broker sent bad signature"
        if e["type"] == want:
            return e


async def main():
    tmp = tempfile.mkdtemp()
    cfg = dict(broker_mod.DEFAULTS)
    cfg.update({
        "psk": PSK,
        # Pin the strict path so this stays a backward-compat regression of the
        # dedicated+required flow (v1.2 default auth_mode is `open`, §13).
        "auth_mode": "required",
        "ws_port": PORT,
        "state_path": os.path.join(tmp, "state.json"),
        "certs_dir": os.path.join(tmp, "certs"),
        "wall_interval_ms": 200,  # speed up for the test
    })
    hub = broker_mod.Hub(cfg)

    server = await websockets.serve(hub.handle_connection, HOST, PORT)
    bg = [
        asyncio.create_task(hub.wall_loop()),
        asyncio.create_task(hub.sync_timeout_loop()),
    ]
    url = f"ws://{HOST}:{PORT}"
    results = []
    try:
        async with websockets.connect(url) as player, \
                websockets.connect(url) as controller:

            # 1a. controller hello -> welcome (with snapshot)
            await controller.send(env(
                "hello", {"role": "controller", "controller_id": "phone-jay",
                          "app_version": "1.0.0"},
                "controller:phone-jay", "broker"))
            w = await recv_type(controller, "welcome")
            assert "snapshot" in w["payload"], "controller welcome missing snapshot"
            results.append("controller hello->welcome OK")

            # 1b. player hello -> welcome
            await player.send(env(
                "hello", {"role": "player", "device_id": "win-lobby-01",
                          "device_name": "大厅左屏", "platform": "windows",
                          "app_version": "1.0.0", "ip": "192.168.1.50",
                          "group_id": "lobby",
                          "capabilities": ["video", "image"]},
                "player:win-lobby-01", "broker"))
            wp = await recv_type(player, "welcome")
            assert wp["payload"]["assigned"] is True
            assert wp["payload"]["group_id"] == "lobby"
            results.append("player hello->welcome OK (server_time=%d)"
                           % wp["payload"]["server_time"])

            # 2. player status -> controller receives wall
            await player.send(env(
                "status", {"device_id": "win-lobby-01", "online": True,
                           "group_id": "lobby", "state": "idle",
                           "volume": 80, "muted": False,
                           "clock_offset_ms": -12},
                "player:win-lobby-01", "broker"))
            wall = await recv_type(controller, "wall")
            devs = wall["payload"]["devices"]
            assert any(d["device_id"] == "win-lobby-01" for d in devs), \
                "player missing from wall"
            assert any(g["group_id"] == "lobby"
                       for g in wall["payload"]["groups"])
            results.append("status->wall OK (%d device(s))" % len(devs))

            # 3. time_sync round-trip
            t1 = clock.server_time_ms()
            await player.send(env("time_sync", {"t1": t1},
                                  "player:win-lobby-01", "broker"))
            ack = await recv_type(player, "time_sync_ack")
            t4 = clock.server_time_ms()
            p = ack["payload"]
            assert p["t1"] == t1, "t1 not echoed"
            assert p["t2"] <= p["t3"], "t2 must precede t3"
            offset, rtt = clock.offset_and_rtt(p["t1"], p["t2"], p["t3"], t4)
            assert rtt >= 0, "negative rtt"
            results.append(
                "time_sync OK (offset=%.1fms rtt=%.1fms)" % (offset, rtt))

            # 4. prepare -> ready -> play_at (sync handshake)
            await controller.send(env(
                "prepare", {"playlist_id": "pl-lobby-1", "group_id": "lobby",
                            "start_index": 0, "seek_ms": 0},
                "controller:phone-jay", "group:lobby"))
            # player should receive the forwarded prepare
            prep = await recv_type(player, "prepare")
            assert prep["payload"]["playlist_id"] == "pl-lobby-1"
            # player reports ready
            await player.send(env(
                "ready", {"device_id": "win-lobby-01",
                          "playlist_id": "pl-lobby-1", "ready": True},
                "player:win-lobby-01", "broker"))
            play = await recv_type(player, "play_at")
            pa = play["payload"]["play_at"]
            now = clock.server_time_ms()
            # play_at should be ~buffer_ms in the future.
            assert pa > now, "play_at not in the future"
            assert pa - now <= cfg["buffer_ms"] + 500, "play_at buffer too large"
            results.append(
                "prepare->ready->play_at OK (play_at=+%dms)" % (pa - now))

    finally:
        for t in bg:
            t.cancel()
        server.close()
        await server.wait_closed()

    print("SMOKE TEST RESULTS")
    for r in results:
        print("  [PASS]", r)
    print("ALL SMOKE CHECKS PASSED")


if __name__ == "__main__":
    asyncio.run(main())
