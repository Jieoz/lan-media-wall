"""§8.5 loop resync WIRING — drives the real Player driver loop, not the math.

test_loop_boundary_sync.py proves the arithmetic. That is not enough: a correct
formula wired to nothing still lets a Windows screen free-run. These tests run
the actual `_loop_boundary_loop` against a fake mpv + a controlled clock and
assert on the seeks it really issues, plus that every timeline-invalidating
command disarms the epoch.
"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import config as C  # noqa: E402
import main as M  # noqa: E402
import loop_boundary_sync as L  # noqa: E402
from playback_modes import PlaybackMode  # noqa: E402


class FakeWs:
    def __init__(self):
        self.sent = []

    async def send(self, type_, payload, to="broker", *, msg_id=None):
        self.sent.append((type_, payload, to))
        return "mid-1"


def player(tmp_path, *, position_ms=0, duration_ms=60_000):
    raw = dict(C.DEFAULTS)
    raw["state_dir"] = str(tmp_path / "state")
    raw["cache_dir"] = str(tmp_path / "cache")
    p = M.Player(C.Config(raw=raw))
    p.ws = FakeWs()
    p.mpv_calls = []
    p._snap = {"position_ms": position_ms, "duration_ms": duration_ms,
               "pause": False}

    async def fake_mpv(fn, *args, **kwargs):
        p.mpv_calls.append((fn, args, kwargs))
        if fn == "snapshot":
            return dict(p._snap)
        return None

    p._mpv = fake_mpv
    p.play_state = "playing"
    p.runtime_mode.set_mode(PlaybackMode.VISUAL)
    # Boundaries are awaited via _await_local; make it instant so one lap of the
    # real loop runs without wall-clock waiting.
    async def instant(_target):
        return None
    p._await_local = instant
    return p


def seeks(p):
    return [args[0] for fn, args, _ in p.mpv_calls if fn == "seek_abs_ms"]


def run_one_lap(p, *, master_now, epoch_play_at=0, base_seek=0,
                duration_hint=60_000):
    """Run the real driver for exactly one sample, then stop it."""
    p._loop_sync = {"session_id": "s1", "item_id": "i1",
                    "play_at": epoch_play_at, "base_seek_ms": base_seek}
    p._loop_boundary_count = 0
    p._loop_correction_count = 0
    p._loop_last_drift_ms = None
    p._loop_last_expected_ms = None
    epoch = p._loop_sync
    p.clock.master_now = lambda: master_now
    p.clock.to_local = lambda ms: ms

    asyncio.run(_drive_until_sampled(p, epoch, duration_hint))


async def _drive_until_sampled(p, epoch, duration_hint, *, laps=1,
                               timeout_s=2.0):
    """Run the real driver until it has taken `laps` samples, then stop it.

    Real sleeps (not sleep(0)) because the driver waits out
    LOOP_BOUNDARY_SAMPLE_SETTLE_MS before sampling.
    """
    task = asyncio.create_task(p._loop_boundary_loop(epoch, duration_hint))
    deadline = asyncio.get_event_loop().time() + timeout_s
    while (p._loop_boundary_count < laps
           and asyncio.get_event_loop().time() < deadline):
        await asyncio.sleep(0.005)
    p._loop_sync = None
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


def test_in_tolerance_lap_issues_no_seek(tmp_path):
    # Wall expects 30ms in; decoder sits 20ms before wrap -> 50ms circular error.
    # Same vector as the Kotlin `small circular phase error` test.
    p = player(tmp_path, position_ms=60_000 - 20)
    run_one_lap(p, master_now=70_030, epoch_play_at=10_000)
    assert p._loop_boundary_count == 1
    assert p._loop_correction_count == 0
    assert seeks(p) == []
    assert p._loop_last_drift_ms == -50


def test_out_of_tolerance_lap_seeks_to_the_master_projection(tmp_path):
    # Lagging 250ms: beyond the 80ms tolerance, so correct to the wall position.
    p = player(tmp_path, position_ms=59_800)
    run_one_lap(p, master_now=70_050, epoch_play_at=10_000)
    assert p._loop_boundary_count == 1
    assert p._loop_correction_count == 1
    assert seeks(p) == [50]


def test_paused_decoder_is_not_corrected(tmp_path):
    # Correcting a paused screen would fight the operator and, on resume, land it
    # at a stale phase anyway.
    p = player(tmp_path, position_ms=0)
    p._snap["pause"] = True
    p._loop_sync = {"session_id": "s1", "item_id": "i1", "play_at": 0,
                    "base_seek_ms": 0}
    epoch = p._loop_sync
    p.clock.master_now = lambda: 70_050
    p.clock.to_local = lambda ms: ms
    # No sample will ever land (pause short-circuits), so just let it spin then stop.
    asyncio.run(_drive_until_sampled(p, epoch, 60_000, timeout_s=0.25))
    assert seeks(p) == []
    assert p._loop_correction_count == 0


def test_music_mode_does_not_get_video_loop_corrections(tmp_path):
    # A box in MUSIC mode has no video timeline; seeking it would jump the track.
    p = player(tmp_path, position_ms=59_800)
    p.runtime_mode.set_mode(PlaybackMode.MUSIC)
    p._loop_sync = {"session_id": "s1", "item_id": "i1", "play_at": 0,
                    "base_seek_ms": 0}
    epoch = p._loop_sync
    p.clock.master_now = lambda: 70_050
    p.clock.to_local = lambda ms: ms
    asyncio.run(_drive_until_sampled(p, epoch, 60_000, timeout_s=0.25))
    assert seeks(p) == []


def test_cancel_disarms_the_epoch_and_reports_reason(tmp_path):
    p = player(tmp_path)

    async def body():
        p._arm_loop_boundary_sync(session_id="s1", item_id="i1",
                                  play_at_master_ms=0, base_seek_ms=0,
                                  duration_hint_ms=60_000)
        assert p._loop_sync is not None
        p._cancel_loop_boundary_sync("stop")
        assert p._loop_sync is None
        assert p._loop_sync_task is None
        await asyncio.sleep(0)

    asyncio.run(body())


def test_session_teardown_cancels_resync(tmp_path):
    # THE stale-epoch bug: without this, stop/next leaves the old epoch armed and
    # the NEXT item gets seeked to the previous item's phase.
    p = player(tmp_path)

    async def body():
        p._arm_loop_boundary_sync(session_id="s1", item_id="i1",
                                  play_at_master_ms=0, base_seek_ms=0,
                                  duration_hint_ms=60_000)
        p._cancel_session_tasks()
        assert p._loop_sync is None
        await asyncio.sleep(0)

    asyncio.run(body())


def test_pause_cancels_resync(tmp_path):
    # Paused wall time is not content time, so the projection is void.
    p = player(tmp_path)

    async def body():
        p._arm_loop_boundary_sync(session_id="s1", item_id="i1",
                                  play_at_master_ms=0, base_seek_ms=0,
                                  duration_hint_ms=60_000)
        await p._h_pause({"target": {"device_ids": [p.device_id]}}, {})
        assert p._loop_sync is None
        await asyncio.sleep(0)

    asyncio.run(body())


def _status_frame(p):
    """Capture the real status frame this player would send."""
    asyncio.run(p._send_status())
    return next(payload for type_, payload, _ in p.ws.sent if type_ == "status")


def test_status_advertises_capability_and_omits_telemetry_when_idle(tmp_path):
    # The controller decides whether a screen may join a synced group from this
    # list; advertising it in hello but not status (the Android bug) makes P2P
    # devices look incapable.
    p = player(tmp_path)
    status = _status_frame(p)
    assert "loop_boundary_sync_v1" in status["capabilities"]
    # No epoch armed -> no telemetry block at all, so old controllers and the
    # wall view do not show a stale drift number.
    assert "loop_sync" not in status


def test_status_reports_live_loop_telemetry_when_armed(tmp_path):
    p = player(tmp_path, position_ms=59_800)
    run_one_lap(p, master_now=70_050, epoch_play_at=10_000)
    # run_one_lap disarms at the end; re-arm state to reflect a live epoch.
    p._loop_sync = {"session_id": "s1", "item_id": "i1", "play_at": 10_000,
                    "base_seek_ms": 0}
    status = _status_frame(p)
    ls = status["loop_sync"]
    assert ls["mode"] == "boundary_only"
    assert ls["tolerance_ms"] == L.LOOP_BOUNDARY_TOLERANCE_MS
    assert ls["session_id"] == "s1" and ls["item_id"] == "i1"
    assert ls["correction_count"] == 1
    assert ls["drift_ms"] == -250
    assert ls["expected_position_ms"] == 50


def test_telemetry_constants_are_reported_from_one_source(tmp_path):
    # The controller reads tolerance from status; it must be the same constant the
    # decision uses, not a duplicated literal.
    assert L.LOOP_BOUNDARY_TOLERANCE_MS == 80
