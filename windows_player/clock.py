"""Clock synchronization (protocol_spec §8) — the sync linchpin.

SNTP-style handshake over the existing WS connection. The player sends
time_sync{t1}; broker replies time_sync_ack{t1,t2,t3}; the player records t4.

    offset = ((t2 - t1) + (t3 - t4)) / 2
    rtt    = (t4 - t1) - (t3 - t2)

We keep a sliding window of recent samples and trust the offset from the
sample with the **smallest rtt** (least network jitter). That offset is what
goes into status.clock_offset_ms.

Start-of-play folding (§8.2): a sync command carries play_at in the broker's
master clock. The local target instant is:

    local_target_ms = play_at - offset

(offset = local - master, so subtracting folds a master instant back to the
local clock.)

Pure logic, no I/O — fully unit-tested.
"""

from __future__ import annotations

import time
from collections import deque
from dataclasses import dataclass
from typing import Deque, Optional


def now_ms() -> int:
    return int(time.time() * 1000)


@dataclass(frozen=True)
class Sample:
    t1: int  # player send (local)
    t2: int  # broker recv (master)
    t3: int  # broker send (master)
    t4: int  # player recv (local)

    @property
    def offset(self) -> float:
        return ((self.t2 - self.t1) + (self.t3 - self.t4)) / 2.0

    @property
    def rtt(self) -> float:
        return (self.t4 - self.t1) - (self.t3 - self.t2)


class ClockSync:
    """Maintains a window of time_sync samples and exposes the best offset."""

    def __init__(self, window: int = 8):
        self.window = window
        self._samples: Deque[Sample] = deque(maxlen=window)
        self._best: Optional[Sample] = None

    def add_sample(self, t1: int, t2: int, t3: int, t4: int) -> Sample:
        """Record a completed round trip. Returns the sample added."""
        s = Sample(t1=t1, t2=t2, t3=t3, t4=t4)
        # Guard against absurd samples (negative rtt from clock weirdness):
        # keep them out of the window so they can't poison the min-rtt pick.
        if s.rtt >= 0:
            self._samples.append(s)
            self._recompute_best()
        return s

    def _recompute_best(self) -> None:
        if not self._samples:
            self._best = None
            return
        self._best = min(self._samples, key=lambda s: s.rtt)

    @property
    def synced(self) -> bool:
        return self._best is not None

    @property
    def offset_ms(self) -> int:
        """Best (min-rtt) offset, rounded. 0 until first sample lands."""
        if self._best is None:
            return 0
        return int(round(self._best.offset))

    @property
    def best_rtt_ms(self) -> Optional[float]:
        return None if self._best is None else self._best.rtt

    def to_local(self, master_ms: int) -> int:
        """Fold a broker-master-clock instant to this player's local clock."""
        return int(master_ms - self.offset_ms)

    def master_now(self) -> int:
        """Estimate the current broker master-clock time from local now."""
        return int(now_ms() + self.offset_ms)

    def reset(self) -> None:
        """Drop all samples — called on reconnect (must re-handshake, §1)."""
        self._samples.clear()
        self._best = None
