"""Receive-path auth gating through Hub._handle_text (§13).

Drives the dispatch pipeline directly with a fake connection so we can assert:
  - open accepts unsigned frames and never trips the auth-fail counter;
  - required trips the counter + cooldown on bad sig;
  - ts-window and msg_id dedup run in EVERY mode.
"""
import asyncio
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import broker as broker_mod  # noqa: E402
import envelope  # noqa: E402

PSK = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


class FakeWS:
    def __init__(self):
        self.closed = None
        self.sent = []

    async def send(self, data):
        self.sent.append(data)

    async def close(self, code=1000, reason=""):
        self.closed = (code, reason)


def _hub(auth_mode):
    cfg = dict(broker_mod.DEFAULTS)
    cfg.update({
        "psk": PSK,
        "auth_mode": envelope.normalize_auth_mode(auth_mode),
        "state_path": os.path.join(tempfile.mkdtemp(), "state.json"),
        "auth_fail_limit": 3,
        "auth_cooldown_s": 60,
    })
    return broker_mod.Hub(cfg)


def _conn(hub):
    ws = FakeWS()
    return broker_mod.ClientConn(ws, "10.0.0.9"), ws


def _hello_raw(*, sign):
    env = envelope.build_envelope(
        "hello", {"role": "player", "device_id": "p1", "group_id": "g"},
        "player:p1", "broker", PSK, sign=sign)
    return env, envelope.dumps(env)


def run(coro):
    return asyncio.get_event_loop().run_until_complete(coro)


def test_open_accepts_unsigned_hello_and_registers():
    hub = _hub("open")
    conn, ws = _conn(hub)
    _, raw = _hello_raw(sign=False)
    run(hub._handle_text(conn, raw, t2=envelope.now_ms()))
    assert conn.role == "player"
    assert "p1" in hub.players
    assert ws.closed is None
    assert conn.auth_fails == 0


def test_required_rejects_unsigned_and_counts_to_cooldown():
    hub = _hub("required")
    conn, ws = _conn(hub)
    # three unsigned frames -> three fails -> cooldown + close (limit=3).
    for _ in range(3):
        _, raw = _hello_raw(sign=False)
        run(hub._handle_text(conn, raw, t2=envelope.now_ms()))
    assert conn.role is None              # never registered
    assert conn.auth_fails >= 3
    assert ws.closed is not None and ws.closed[1] == "auth"
    assert conn.ip in hub._cooldowns      # cooldown recorded for the IP


def test_open_never_records_cooldown_on_bad_sig():
    hub = _hub("open")
    conn, ws = _conn(hub)
    for _ in range(5):
        env, _ = _hello_raw(sign=True)
        env["sig"] = "deadbeef"           # bogus — but open doesn't verify
        run(hub._handle_text(conn, envelope.dumps(env), t2=envelope.now_ms()))
    assert ws.closed is None
    assert hub._cooldowns == {}


def test_dedup_runs_in_open_mode():
    hub = _hub("open")
    conn, _ = _conn(hub)
    env, raw = _hello_raw(sign=False)
    run(hub._handle_text(conn, raw, t2=envelope.now_ms()))
    assert "p1" in hub.players
    # Replay the exact same msg_id: dedup must drop it (hub.players unchanged,
    # and crucially no crash). Re-send identical frame.
    hub.players.clear()
    run(hub._handle_text(conn, raw, t2=envelope.now_ms()))
    assert "p1" not in hub.players        # duplicate msg_id dropped


def test_stale_ts_rejected_in_open_mode():
    hub = _hub("open")
    conn, _ = _conn(hub)
    env = envelope.build_envelope(
        "hello", {"role": "player", "device_id": "old"},
        "player:old", "broker", PSK, sign=False,
        ts=envelope.now_ms() - 5 * 60 * 1000)  # 5 min old, past 120s first win
    run(hub._handle_text(conn, envelope.dumps(env), t2=envelope.now_ms()))
    assert "old" not in hub.players       # ts-window applies in open too
