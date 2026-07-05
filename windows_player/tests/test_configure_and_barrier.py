"""§19 configure_device + §21 prefetch-barrier prepare on the player side.

Verifies:
  - configure_device changes name/group/volume only for our device_id and
    persists them; missing fields are left untouched; other-device ignored.
  - a prefetch-barrier prepare (prefetch=true) with an item NOT yet cached does
    NOT immediately answer ready:false — it defers, then emits ready:true once
    the cache becomes ready (barrier semantics), and ready:false on timeout.
"""
import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config as C  # noqa: E402
import main as M  # noqa: E402


class _FakeWs:
    def __init__(self):
        self.sent = []

    async def send(self, type_, payload):
        self.sent.append((type_, payload))


class _FakeMpv:
    def __init__(self):
        self.calls = []

    async def __call__(self, *a, **kw):  # not used directly
        self.calls.append((a, kw))


def _player(tmp_path, **cfg_over):
    raw = dict(C.DEFAULTS)
    raw["state_dir"] = str(tmp_path / "state")
    raw["cache_dir"] = str(tmp_path / "cache")
    raw.update(cfg_over)
    cfg = C.Config(raw=raw)
    p = M.Player(cfg)
    p._state_dir = cfg.state_dir  # type: ignore[attr-defined]
    p.ws = _FakeWs()
    # neutralize real mpv IPC
    mpv_calls = []

    async def _fake_mpv(cmd, *a, **kw):
        mpv_calls.append((cmd, a, kw))

    p._mpv = _fake_mpv  # type: ignore[assignment]
    p._mpv_calls = mpv_calls  # type: ignore[attr-defined]
    return p


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


# ---- §19 configure_device ------------------------------------------

def test_configure_device_applies_and_persists(tmp_path):
    p = _player(tmp_path)
    _run(p._h_configure_device(
        {"device_id": p.device_id, "device_name": "大厅左屏",
         "group_id": "hall-2", "volume": 55}, {}))
    assert p.device_name == "大厅左屏"
    assert p.group_id == "hall-2"
    assert p.volume == 55
    # persisted across reload
    s2 = C.PersistentState.load(p._state_dir)  # type: ignore[attr-defined]
    assert s2.device_name("x") == "大厅左屏"
    assert s2.group_id == "hall-2"


def test_configure_device_ignores_other_device(tmp_path):
    p = _player(tmp_path)
    before = p.device_name
    _run(p._h_configure_device(
        {"device_id": "someone-else", "device_name": "X", "volume": 10}, {}))
    assert p.device_name == before
    assert p.volume == 80  # unchanged default


def test_configure_device_partial_update(tmp_path):
    p = _player(tmp_path)
    p.group_id = "keep-me"
    _run(p._h_configure_device(
        {"device_id": p.device_id, "volume": 30}, {}))
    assert p.volume == 30
    assert p.group_id == "keep-me"  # not clobbered when omitted


# ---- §21 prefetch barrier ------------------------------------------

class _FakeDownloader:
    def __init__(self):
        self._ready = set()
        self.prefetched = []

    def prefetch(self, items):
        self.prefetched.extend(items)

    def is_ready(self, item_id):
        return item_id in self._ready

    def ready_path(self, item_id):
        return "/tmp/%s.mp4" % item_id if item_id in self._ready else None

    def mark(self, item_id):
        self._ready.add(item_id)


def _seed_playlist(p, item_id="v1", type_="video"):
    pl = {"playlist_id": "pl1", "items": [
        {"item_id": item_id, "type": type_, "url": "http://x/%s" % item_id}]}
    p._resolve_playlist = lambda pid: pl if pid == "pl1" else None  # type: ignore


def test_barrier_defers_then_ready_when_cache_completes(tmp_path):
    p = _player(tmp_path)
    dl = _FakeDownloader()
    p.downloader = dl  # type: ignore[assignment]
    _seed_playlist(p)

    async def scenario():
        # start barrier prepare; item not cached → must NOT answer immediately
        await p._h_prepare(
            {"playlist_id": "pl1", "start_index": 0, "prefetch": True,
             "barrier_timeout_ms": 5000}, {})
        await asyncio.sleep(0.1)
        assert p.ws.sent == [], "barrier must defer ready until cache ready"
        assert dl.prefetched, "should have kicked a prefetch"
        # cache completes → barrier task should emit ready:true
        dl.mark("v1")
        await asyncio.wait_for(p._barrier_task, timeout=3)

    _run(scenario())
    readies = [pl for (t, pl) in p.ws.sent if t == "ready"]
    assert len(readies) == 1
    assert readies[0]["ready"] is True
    assert readies[0]["playlist_id"] == "pl1"


def test_barrier_times_out_to_not_ready(tmp_path):
    p = _player(tmp_path)
    dl = _FakeDownloader()
    p.downloader = dl  # type: ignore[assignment]
    _seed_playlist(p)

    async def scenario():
        await p._h_prepare(
            {"playlist_id": "pl1", "start_index": 0, "prefetch": True,
             "barrier_timeout_ms": 50}, {})  # never marked ready
        await asyncio.wait_for(p._barrier_task, timeout=3)

    _run(scenario())
    readies = [pl for (t, pl) in p.ws.sent if t == "ready"]
    assert len(readies) == 1
    assert readies[0]["ready"] is False


def test_non_barrier_prepare_reports_not_ready_immediately(tmp_path):
    p = _player(tmp_path)
    dl = _FakeDownloader()
    p.downloader = dl  # type: ignore[assignment]
    _seed_playlist(p)

    _run(p._h_prepare(
        {"playlist_id": "pl1", "start_index": 0}, {}))  # no prefetch flag
    readies = [pl for (t, pl) in p.ws.sent if t == "ready"]
    assert len(readies) == 1
    assert readies[0]["ready"] is False  # legacy behavior preserved
