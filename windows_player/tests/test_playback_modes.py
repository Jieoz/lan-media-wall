from __future__ import annotations

import asyncio
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config as C  # noqa: E402
import main as M  # noqa: E402
from playback_modes import MusicPlaylist, PlaybackMode, PlaybackModeState, ShuffleBag  # noqa: E402


class FakeWs:
    def __init__(self):
        self.sent = []

    async def send(self, type_, payload, to="broker", *, msg_id=None):
        self.sent.append((type_, payload, to))
        return "mid-1"


def player(tmp_path):
    raw = dict(C.DEFAULTS)
    raw["state_dir"] = str(tmp_path / "state")
    raw["cache_dir"] = str(tmp_path / "cache")
    p = M.Player(C.Config(raw=raw))
    p.ws = FakeWs()
    p.mpv_calls = []

    async def fake_mpv(fn, *args, **kwargs):
        p.mpv_calls.append((fn, args, kwargs))
        return None

    p._mpv = fake_mpv
    return p


def audio(item_id):
    return {"item_id": item_id, "name": item_id, "type": "audio",
            "url": f"https://media.invalid/{item_id}.mp3"}


def run(coro):
    return asyncio.run(coro)


def test_mode_state_preserves_previous_active_mode():
    state = PlaybackModeState()
    assert state.set_mode(PlaybackMode.MUSIC) is PlaybackMode.MUSIC
    assert state.set_mode(PlaybackMode.STANDBY) is PlaybackMode.STANDBY
    state.set_mode(PlaybackMode.STANDBY)
    assert state.previous_active is PlaybackMode.MUSIC
    assert state.restore() is PlaybackMode.MUSIC


def test_shuffle_bag_one_lap_unique_and_no_boundary_repeat():
    bag = ShuffleBag(random.Random(7))
    items = ["a", "b", "c", "d"]
    first = [bag.next(items) for _ in items]
    second = [bag.next(items) for _ in items]
    assert set(first) == set(items)
    assert set(second) == set(items)
    assert first[-1] != second[0]
    assert bag.cycle == 2


def test_music_playlist_rejects_visual_media():
    assert MusicPlaylist.from_payload({
        "playlist_id": "music-1", "revision": 1,
        "items": [{"item_id": "v", "type": "video", "url": "x"}],
    }) is None


def test_player_music_standby_restore_round_trip(tmp_path):
    p = player(tmp_path)
    music = {
        "request_id": "req-list", "device_id": p.device_id,
        "playlist_id": "music-1", "revision": 1,
        "items": [audio("a"), audio("b")],
    }
    run(p._on_message("music_playlist", music, {"msg_id": "m-list"}))
    assert p.music_playlist["revision"] == 1
    assert p.state.music_playlist["playlist_id"] == "music-1"
    assert p.ws.sent[-1][0] == "music_playlist_result"
    assert p.ws.sent[-1][1]["ok"] is True

    run(p._on_message("set_runtime_mode", {
        "request_id": "req-mode", "device_id": p.device_id, "mode": "music",
    }, {"msg_id": "m-mode"}))
    assert p.runtime_mode.current is PlaybackMode.MUSIC
    assert p.state.runtime_mode == "music"
    assert p.music_current_item_id in {"a", "b"}
    assert any(call[0] == "loadfile" for call in p.mpv_calls)
    assert p.ws.sent[-1][0] == "runtime_mode_result"

    run(p._on_message("set_runtime_mode", {
        "request_id": "req-off", "device_id": p.device_id, "mode": "standby",
    }, {"msg_id": "m-off"}))
    assert p.runtime_mode.current is PlaybackMode.STANDBY
    assert p.runtime_mode.previous_active is PlaybackMode.MUSIC
    assert p.music_playlist["playlist_id"] == "music-1"
    assert p.play_state == "idle"

    run(p._on_message("restore_runtime_mode", {
        "request_id": "req-restore", "device_id": p.device_id,
    }, {"msg_id": "m-restore"}))
    assert p.runtime_mode.current is PlaybackMode.MUSIC
    assert p.state.runtime_mode == "music"
    assert p.play_state == "playing"


def test_music_snapshot_marks_only_immediate_or_stalled_failures(tmp_path):
    p = player(tmp_path)
    p.music_started_monotonic = 100.0
    assert p._music_snapshot_failed(
        {"eof": True, "duration_ms": 0, "position_ms": 0, "idle": False}, 100.5)
    assert p._music_snapshot_failed(
        {"eof": False, "duration_ms": 0, "position_ms": 0, "idle": True}, 102.1)
    assert not p._music_snapshot_failed(
        {"eof": True, "duration_ms": 5000, "position_ms": 5000, "idle": False}, 105.0)
    assert not p._music_snapshot_failed(
        {"eof": False, "duration_ms": 0, "position_ms": 0, "idle": True}, 101.0)


def test_player_all_bad_music_stops_without_requeue(tmp_path):
    p = player(tmp_path)
    p.music_playlist = {
        "playlist_id": "music-1", "revision": 1,
        "items": [audio("a"), audio("b")],
    }
    p.runtime_mode.set_mode(PlaybackMode.MUSIC)
    p.music_failures = {"a", "b"}
    run(p._play_next_music(p.mode_generation))
    assert p.play_state == "error"
    assert p.music_current_item_id is None
    assert not any(call[0] == "loadfile" for call in p.mpv_calls)


def test_player_rejects_invalid_music_without_optimistic_ack(tmp_path):
    p = player(tmp_path)
    run(p._on_message("music_playlist", {
        "request_id": "bad", "device_id": p.device_id,
        "playlist_id": "music", "revision": 1,
        "items": [{"item_id": "v", "type": "video", "url": "x"}],
    }, {"msg_id": "m"}))
    assert [entry[0] for entry in p.ws.sent] == ["music_playlist_result"]
    assert p.ws.sent[0][1]["ok"] is False
