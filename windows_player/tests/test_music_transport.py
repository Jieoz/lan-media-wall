"""§6.3c music transport: prev/next in MUSIC mode + the shuffle setting.

These cover the v1.19.7 fix for "music mode ignores prev/next" and the new
controller-selectable ordering. The pure-queue tests are the cross-platform
contract: the Kotlin MusicQueue must behave identically (same laps, same
bounded history, same prev semantics).
"""
from __future__ import annotations

import asyncio
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config as C  # noqa: E402
import main as M  # noqa: E402
from playback_modes import MusicPlaylist, MusicQueue, PlaybackMode  # noqa: E402


def audio(item_id):
    return {"item_id": item_id, "name": item_id, "type": "audio",
            "url": f"https://media.invalid/{item_id}.mp3"}


def run(coro):
    return asyncio.run(coro)


class FakeWs:
    def __init__(self):
        self.sent = []

    async def send(self, type_, payload, to="broker", *, msg_id=None):
        self.sent.append((type_, payload, to))
        return "mid-1"


def player(tmp_path, items=("a", "b", "c"), shuffle=True):
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
    p.music_playlist = {
        "playlist_id": "music-1", "revision": 1,
        "items": [audio(i) for i in items], "shuffle": shuffle,
    }
    p.music_queue.set_shuffle(shuffle)
    p.runtime_mode.set_mode(PlaybackMode.MUSIC)
    return p


# --- pure queue contract (mirrored by Kotlin MusicQueue) -----------------

def test_sequential_mode_follows_controller_list_order_and_wraps():
    q = MusicQueue()
    q.set_shuffle(False)
    ids = ["a", "b", "c"]
    assert [q.next(ids) for _ in range(4)] == ["a", "b", "c", "a"]


def test_sequential_prev_walks_back_through_the_list():
    q = MusicQueue()
    q.set_shuffle(False)
    ids = ["a", "b", "c"]
    q.next(ids); q.next(ids); q.next(ids)      # a, b, c
    assert q.prev(ids) == "b"
    assert q.prev(ids) == "a"


def test_prev_replays_actual_history_not_another_random_track():
    """The point of the fix: prev must return what the user just heard."""
    q = MusicQueue(random.Random(7))
    ids = ["a", "b", "c", "d", "e"]
    heard = [q.next(ids) for _ in range(4)]
    assert q.prev(ids) == heard[-2]
    assert q.prev(ids) == heard[-3]
    assert q.prev(ids) == heard[-4]


def test_shuffle_lap_plays_every_track_once_before_repeating():
    q = MusicQueue(random.Random(3))
    ids = ["a", "b", "c", "d"]
    lap = [q.next(ids) for _ in range(4)]
    assert sorted(lap) == ids


def test_history_is_bounded_so_long_running_boxes_do_not_grow_forever():
    q = MusicQueue(random.Random(11))
    ids = [f"t{i}" for i in range(50)]
    for _ in range(500):
        q.next(ids)
    assert q.history_depth <= MusicQueue.MAX_HISTORY


def test_prev_at_the_bottom_of_history_holds_instead_of_jumping():
    q = MusicQueue(random.Random(5))
    ids = ["a", "b", "c"]
    first = q.next(ids)
    assert q.prev(ids) == first
    assert q.current == first


def test_prev_skips_history_entries_no_longer_in_the_list():
    q = MusicQueue()
    q.set_shuffle(False)
    q.next(["a", "b", "c"])          # a
    q.next(["a", "b", "c"])          # b
    q.next(["a", "b", "c"])          # c
    # "b" was removed from the list by the controller.
    assert q.prev(["a", "c"]) == "a"


def test_toggling_shuffle_keeps_the_setting_across_a_queue_reset():
    q = MusicQueue()
    q.set_shuffle(False)
    q.next(["a", "b"])
    q.reset()
    assert q.shuffle is False
    assert q.current is None


def test_set_shuffle_reports_only_real_changes():
    q = MusicQueue()
    assert q.set_shuffle(True) is False   # already shuffling
    assert q.set_shuffle(False) is True
    assert q.set_shuffle(False) is False


# --- wire contract ------------------------------------------------------

def test_shuffle_travels_with_the_playlist_and_defaults_to_true():
    parsed = MusicPlaylist.from_payload({
        "playlist_id": "m", "revision": 1, "items": [audio("a")],
    })
    assert parsed is not None and parsed.shuffle is True

    off = MusicPlaylist.from_payload({
        "playlist_id": "m", "revision": 1, "items": [audio("a")],
        "shuffle": False,
    })
    assert off is not None and off.shuffle is False


def test_non_bool_shuffle_is_rejected_rather_than_coerced():
    assert MusicPlaylist.from_payload({
        "playlist_id": "m", "revision": 1, "items": [audio("a")],
        "shuffle": "yes",
    }) is None


# --- player wiring ------------------------------------------------------

def test_music_mode_next_advances_the_music_queue(tmp_path):
    p = player(tmp_path, shuffle=False)
    run(p._advance(+1, explicit=True))
    first = p.music_queue.current
    run(p._advance(+1, explicit=True))
    assert p.music_queue.current != first
    assert any(call[0] == "loadfile" for call in p.mpv_calls)


def test_music_mode_prev_goes_back_instead_of_forward(tmp_path):
    """Regression: prev used to fall through to _play_next_music(+1)."""
    p = player(tmp_path, shuffle=False)
    run(p._advance(+1, explicit=True))   # a
    run(p._advance(+1, explicit=True))   # b
    assert p.music_queue.current == "b"
    run(p._advance(-1, explicit=True))
    assert p.music_queue.current == "a"


def test_music_transport_leaves_the_visual_playlist_untouched(tmp_path):
    p = player(tmp_path, shuffle=False)
    p.playlist = {"playlist_id": "vis", "items": [
        {"item_id": "v1", "type": "video", "url": "x"},
        {"item_id": "v2", "type": "video", "url": "y"},
    ]}
    p.index = 0
    run(p._advance(+1, explicit=True))
    assert p.index == 0, "music prev/next must not move the video wall"


def test_shuffle_only_change_does_not_restart_the_current_track(tmp_path):
    p = player(tmp_path, shuffle=True)
    run(p._play_next_music(p.mode_generation))
    playing = p.music_queue.current
    loads_before = [c for c in p.mpv_calls if c[0] == "loadfile"]
    run(p._on_message("music_playlist", {
        "request_id": "r-shuffle-off", "device_id": p.device_id,
        "playlist_id": "music-1", "revision": 2,
        "items": [audio(i) for i in ("a", "b", "c")],
        "shuffle": False,
    }, {"msg_id": "m1"}))
    assert p.music_queue.shuffle is False
    assert p.music_queue.current == playing
    assert [c for c in p.mpv_calls if c[0] == "loadfile"] == loads_before
    assert p.ws.sent[-1][1]["ok"] is True


def test_content_change_still_replaces_and_restarts_the_queue(tmp_path):
    p = player(tmp_path, shuffle=False)
    run(p._play_next_music(p.mode_generation))
    loads_before = len([c for c in p.mpv_calls if c[0] == "loadfile"])
    run(p._on_message("music_playlist", {
        "request_id": "r-new", "device_id": p.device_id,
        "playlist_id": "music-1", "revision": 3,
        "items": [audio("x"), audio("y")],
        "shuffle": False,
    }, {"msg_id": "m2"}))
    assert p.music_queue.current in {"x", "y"}
    assert len([c for c in p.mpv_calls if c[0] == "loadfile"]) > loads_before


def test_shuffle_setting_survives_a_player_restart(tmp_path):
    p = player(tmp_path, shuffle=True)
    run(p._on_message("music_playlist", {
        "request_id": "r-off", "device_id": p.device_id,
        "playlist_id": "music-1", "revision": 2,
        "items": [audio("a"), audio("b")], "shuffle": False,
    }, {"msg_id": "m3"}))
    assert p.music_queue.shuffle is False

    raw = dict(C.DEFAULTS)
    raw["state_dir"] = p.cfg.state_dir
    raw["cache_dir"] = p.cfg.cache_dir
    revived = M.Player(C.Config(raw=raw))
    assert revived.music_queue.shuffle is False, \
        "a reboot must not silently fall back to shuffle"


def test_status_reports_the_shuffle_setting_for_the_controller(tmp_path):
    """The controller renders its toggle from status, so it must be on the wire."""
    p = player(tmp_path, shuffle=False)
    run(p._send_status())
    status = next(payload for type_, payload, _ in p.ws.sent if type_ == "status")
    assert status["music_shuffle"] is False
    assert status["music_history_depth"] == 0


def test_music_mode_polls_eof_faster_than_visual_mode(tmp_path):
    """A gap between tracks is audible; a held video frame is not."""
    assert M.MUSIC_EOF_POLL_S < M.VISUAL_EOF_POLL_S
    # The stall detector is wall-clock based (>=2s since track start), so the
    # tighter poll must not turn a normal startup into a false failure.
    p = player(tmp_path)
    p.music_started_monotonic = 99999.0
    snap = {"eof": False, "idle": True, "duration_ms": 0, "position_ms": 0}
    assert p._music_snapshot_failed(snap, now=99999.0 + M.MUSIC_EOF_POLL_S) is False


def test_mpv_is_launched_with_audio_continuity_buffers():
    from mpv_controller import mpv_launch_args
    args = mpv_launch_args("/tmp/ipc.sock")
    assert "--cache=yes" in args
    assert any(a.startswith("--audio-buffer=") for a in args)
    assert any(a.startswith("--demuxer-readahead-secs=") for a in args)


def test_hello_advertises_music_transport_capability(tmp_path):
    p = player(tmp_path)
    run(p._on_connect())
    hello = next(payload for type_, payload, _ in p.ws.sent if type_ == "hello")
    assert "music_transport_v1" in hello["capabilities"]
