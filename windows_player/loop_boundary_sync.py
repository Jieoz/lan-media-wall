"""§8.2 / §8.5 loop-boundary synchronization math — PURE, no I/O, no mpv.

This is a deliberate 1:1 port of the Android player's
`player/sync/ContentClock.kt` + `player/sync/LoopBoundarySync.kt`. Both fleets
must agree on the *same* arithmetic or a mixed wall (Android boxes + a Windows
screen) drifts apart even though every box believes it is in sync.

Keep this file behaviourally identical to the Kotlin originals. If you change a
rule here, change it there in the same commit — the capability bit
`loop_boundary_sync_v1` is a promise about this math, not about having *some*
resync code.

Design (same as Android, mode `boundary_only`):
  - The decoder keeps its own seamless loop (mpv `loop-file`); we never run a
    continuous seek/rate-control loop, which would flood a weak box with seeks.
  - Once per lap, at the shared master-clock boundary, sample the decoder phase
    and correct ONLY when the shortest circular error exceeds the tolerance.
    A correcting seek costs a visible frame, so micro-jitter is left alone.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

# Below this, a late start counts as on-time: a correcting seek would itself
# cost a frame. Mirrors ContentClock.LATE_START_THRESHOLD_MS.
LATE_START_THRESHOLD_MS = 40

# Mirrors PlayerService.LOOP_BOUNDARY_TOLERANCE_MS / _SAMPLE_SETTLE_MS.
LOOP_BOUNDARY_TOLERANCE_MS = 80
LOOP_BOUNDARY_SAMPLE_SETTLE_MS = 40


def _floormod(value: int, modulus: int) -> int:
    """Java/Kotlin Math.floorMod: result carries the divisor's sign.

    Python's `%` already floor-divides for positive moduli, but be explicit —
    the Kotlin original relies on floorMod semantics and a future reader should
    not have to re-derive that the two agree.
    """
    return value % modulus


def _wrap(raw_ms: int, duration_ms: int, loop: bool) -> int:
    """Wrap into [0,duration) for loops; clamp to [0,duration] otherwise."""
    if duration_ms <= 0:
        return max(raw_ms, 0)
    if loop:
        return _floormod(raw_ms, duration_ms)
    return min(max(raw_ms, 0), duration_ms)


def expected_offset_ms(play_at_ms: int, base_seek_ms: int,
                       now_content_domain_ms: int, duration_ms: int,
                       loop: bool) -> int:
    """Content offset the item should be showing at `now_content_domain_ms`.

    All three time args share ONE clock domain (caller folds master→local, or
    stays in master, but must not mix). Before play_at we clamp to the base
    seek: nothing has started yet, the primed frame *is* the seek point.
    """
    base = max(base_seek_ms, 0)
    elapsed = now_content_domain_ms - play_at_ms
    if elapsed <= 0:
        return base
    return _wrap(base + elapsed, duration_ms, loop)


def late_start_seek_ms(play_at_ms: int, base_seek_ms: int, actual_start_ms: int,
                       duration_ms: int, loop: bool) -> Optional[int]:
    """Seek target when the real start slipped past the scheduled play_at.

    Returns None when the start was on time within LATE_START_THRESHOLD_MS, so
    the caller can skip a needless seek.
    """
    base = max(base_seek_ms, 0)
    late_ms = actual_start_ms - play_at_ms
    if late_ms <= LATE_START_THRESHOLD_MS:
        return None
    return _wrap(base + late_ms, duration_ms, loop)


def next_boundary_master_ms(play_at_master_ms: int, base_seek_ms: int,
                            duration_ms: int,
                            master_now_ms: int) -> Optional[int]:
    """First loop boundary strictly after `master_now_ms`.

    A non-zero initial seek shortens only the FIRST lap; later laps are full
    length. Returns None when the duration is not known yet.
    """
    if duration_ms <= 0:
        return None
    normalized_seek = _floormod(base_seek_ms, duration_ms)
    first_boundary = play_at_master_ms + (duration_ms - normalized_seek)
    if master_now_ms < first_boundary:
        return first_boundary
    completed_after_first = (master_now_ms - first_boundary) // duration_ms
    return first_boundary + (completed_after_first + 1) * duration_ms


def shortest_circular_drift_ms(expected_position_ms: int,
                               actual_position_ms: int,
                               duration_ms: int) -> int:
    """Signed drift on the SHORTEST path around the loop.

    Without the circular fold, a box sitting just before EOS while the wall has
    already wrapped looks like it is a whole duration behind, and we would seek
    on every lap. Positive = ahead of the wall, negative = trailing.
    """
    if duration_ms <= 0:
        return actual_position_ms - expected_position_ms
    expected = _floormod(expected_position_ms, duration_ms)
    actual = _floormod(actual_position_ms, duration_ms)
    raw = actual - expected
    half = duration_ms // 2
    if raw > half:
        return raw - duration_ms
    if raw < -half:
        return raw + duration_ms
    return raw


@dataclass(frozen=True)
class BoundaryDecision:
    expected_position_ms: int
    drift_ms: int
    #: None means: leave the decoder's seamless loop untouched.
    seek_to_ms: Optional[int]


def decide(play_at_master_ms: int, base_seek_ms: int, master_now_ms: int,
           duration_ms: int, actual_position_ms: int,
           tolerance_ms: int = LOOP_BOUNDARY_TOLERANCE_MS) -> BoundaryDecision:
    """One lap's correction decision. Mirrors LoopBoundarySync.decide."""
    if duration_ms <= 0:
        return BoundaryDecision(expected_position_ms=0, drift_ms=0,
                                seek_to_ms=None)
    expected = expected_offset_ms(
        play_at_ms=play_at_master_ms,
        base_seek_ms=base_seek_ms,
        now_content_domain_ms=master_now_ms,
        duration_ms=duration_ms,
        loop=True,
    )
    drift = shortest_circular_drift_ms(expected, actual_position_ms,
                                       duration_ms)
    seek = expected if abs(drift) > max(tolerance_ms, 0) else None
    return BoundaryDecision(expected_position_ms=expected, drift_ms=drift,
                            seek_to_ms=seek)
