"""Master clock + time-sync handshake (§8).

The broker's clock is the single authoritative timeline (`server_time`).
For a `time_sync` from a player carrying t1, the broker stamps t2 at receive
and t3 at send and echoes them back in `time_sync_ack`; the player does the
NTP-style offset/rtt math locally (§8.1).
"""
from __future__ import annotations

import time


def server_time_ms() -> int:
    """Authoritative master-clock reading in epoch milliseconds (§8)."""
    return int(time.time() * 1000)


def build_time_sync_ack_payload(t1: int, t2: int, *, t3: int = None) -> dict:
    """Assemble the time_sync_ack payload.

    t1 — echoed player send time.
    t2 — broker receive time (captured as early as possible).
    t3 — broker send time (captured as late as possible, just before send).
    """
    if t3 is None:
        t3 = server_time_ms()
    return {"t1": t1, "t2": t2, "t3": t3}


def offset_and_rtt(t1: int, t2: int, t3: int, t4: int):
    """NTP formulas from §8.1 — provided here so tests (and an optional
    broker-side estimate) can compute offset/rtt the same way a player does.

    offset = ((t2 - t1) + (t3 - t4)) / 2
    rtt    = (t4 - t1) - (t3 - t2)
    """
    offset = ((t2 - t1) + (t3 - t4)) / 2.0
    rtt = (t4 - t1) - (t3 - t2)
    return offset, rtt


def best_offset(samples):
    """Given (t1,t2,t3,t4) samples, pick the offset whose rtt is smallest
    (§8.1: 'take the offset of the minimum-rtt sample')."""
    best = None
    best_rtt = None
    for t1, t2, t3, t4 in samples:
        offset, rtt = offset_and_rtt(t1, t2, t3, t4)
        if best_rtt is None or rtt < best_rtt:
            best_rtt = rtt
            best = offset
    return best
