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
from pathlib import Path

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config as C  # noqa: E402
import main as M  # noqa: E402


class _FakeWs:
    def __init__(self):
        self.sent = []

    async def send(self, type_, payload, **_kwargs):
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
    # status must echo the new display name so the controller wall updates
    status_msgs = [pl for t, pl in p.ws.sent if t == "status"]
    assert status_msgs, "rename must push an immediate status"
    assert status_msgs[-1].get("device_name") == "大厅左屏"


def test_send_status_includes_device_name(tmp_path):
    p = _player(tmp_path)
    p.device_name = "展示名-A"
    _run(p._send_status())
    status_msgs = [pl for t, pl in p.ws.sent if t == "status"]
    assert status_msgs
    assert status_msgs[-1]["device_name"] == "展示名-A"
    assert status_msgs[-1]["device_id"] == p.device_id


def test_configure_device_updates_discovery_name(tmp_path):
    p = _player(tmp_path)

    class _Disc:
        def __init__(self):
            self.device_name = "old"

        def update_name(self, name: str) -> None:
            self.device_name = name

    disc = _Disc()
    p.discovery = disc  # type: ignore[assignment]
    _run(p._h_configure_device(
        {"device_id": p.device_id, "device_name": "新名字"}, {}))
    assert disc.device_name == "新名字"


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




def test_configure_device_rejects_legacy_transport_and_key(tmp_path):
    p = _player(tmp_path)
    rebuilds = []

    async def _fake_rebuild():
        rebuilds.append(True)

    p._rebuild_transport = _fake_rebuild  # type: ignore[assignment]

    async def scenario():
        await p._h_configure_device({
            "device_id": p.device_id,
            "request_id": "legacy-config",
            "broker_host": "10.9.8.7",
            "broker_port": 9001,
            "use_wss": True,
            "psk": "must-not-persist",
        }, {"sig": "deadbeef"})
        await asyncio.sleep(0.05)

    _run(scenario())
    results = [payload for kind, payload in p.ws.sent if kind == "config_patch_result"]
    assert results
    assert results[-1]["ok"] is False
    assert results[-1]["applied"] == {}
    assert {entry["field"] for entry in results[-1]["rejected"]} == {
        "broker_host", "broker_port", "use_wss", "psk",
    }
    assert rebuilds == []
    assert p.state.broker_host is None
    assert p.state.psk_override is None


def test_explicit_p2p_intent_skips_discoverable_broker(tmp_path, monkeypatch):
    p = _player(tmp_path)
    p.state.set_transport_mode("p2p")
    probes = []

    class _Probe:
        @staticmethod
        def probe_for_broker(**_kwargs):
            probes.append(True)
            return M.topology_mod.BrokerFound(
                host="10.10.8.108", port=8770,
                auth_mode=p.auth.mode, key_mode=p.auth.key_mode,
            )

    monkeypatch.setattr(M, "discovery_probe_mod", _Probe)
    decision = p._discover_decision()

    assert decision.role == M.topology_mod.ROLE_P2P_SERVER
    assert probes == []


def test_transport_configure_persists_explicit_p2p_intent(tmp_path):
    p = _player(tmp_path)
    rebuilds = []

    async def _fake_rebuild():
        rebuilds.append(True)

    p._rebuild_transport = _fake_rebuild  # type: ignore[assignment]

    _run(p._h_transport_configure({
        "device_id": p.device_id,
        "request_id": "restore-p2p",
        "broker_host": "",
        "transport_mode": "p2p",
    }, {}))

    results = [payload for kind, payload in p.ws.sent if kind == "config_patch_result"]
    assert results[-1]["ok"] is True
    assert results[-1]["applied"]["transport_mode"] == "p2p"
    assert p.state.transport_mode == "p2p"
    assert C.PersistentState.load(p._state_dir).transport_mode == "p2p"  # type: ignore[attr-defined]
    assert rebuilds == [True]


def test_legacy_clear_without_mode_remains_auto_not_sticky_p2p(tmp_path):
    p = _player(tmp_path)
    rebuilds = []

    async def _fake_rebuild():
        rebuilds.append(p.state.transport_mode)

    p._rebuild_transport = _fake_rebuild  # type: ignore[assignment]
    _run(p._h_transport_configure({
        "device_id": p.device_id,
        "request_id": "legacy-clear",
        "broker_host": "",
    }, {}))
    result = [pl for kind, pl in p.ws.sent
              if kind == "config_patch_result"][-1]
    assert result["ok"] is True
    assert result["applied"]["transport_mode"] == "auto"
    assert p.state.transport_mode == "auto"
    assert rebuilds == ["auto"]


@pytest.mark.parametrize("field,value", [
    ("broker_port", 0),
    ("broker_port", float("nan")),
    ("use_wss", "yes"),
])
def test_transport_configure_rejects_invalid_fields_without_mutation(
        tmp_path, field, value):
    p = _player(tmp_path)
    before = dict(p.state.data)
    _run(p._h_transport_configure({
        "device_id": p.device_id,
        "request_id": "bad-transport",
        "broker_host": "10.0.0.8",
        "transport_mode": "broker",
        field: value,
    }, {}))
    result = [pl for kind, pl in p.ws.sent
              if kind == "config_patch_result"][-1]
    assert result["ok"] is False
    assert p.state.data == before


def test_commit_transport_does_not_mutate_memory_when_replace_fails(
        tmp_path, monkeypatch):
    state = C.PersistentState.load(tmp_path / "state")
    before = dict(state.data)

    def _fail_replace(self, target):
        raise OSError("simulated replace failure")

    monkeypatch.setattr(Path, "replace", _fail_replace)
    with pytest.raises(OSError, match="simulated"):
        state.commit_transport(mode="p2p", host="")
    assert state.data == before


def test_transport_configure_reports_persist_failure_without_rebuild(
        tmp_path, monkeypatch):
    p = _player(tmp_path)
    rebuilds = []

    def _fail_commit(**_kwargs):
        raise OSError("disk full")

    async def _fake_rebuild(**_kwargs):
        rebuilds.append(True)

    monkeypatch.setattr(p.state, "commit_transport", _fail_commit)
    p._rebuild_transport_with_rollback = _fake_rebuild  # type: ignore[assignment]
    _run(p._h_transport_configure({
        "device_id": p.device_id,
        "request_id": "persist-failure",
        "broker_host": "",
        "transport_mode": "p2p",
    }, {}))
    result = [pl for kind, pl in p.ws.sent
              if kind == "config_patch_result"][-1]
    assert result["ok"] is False
    assert result["rejected"] == [{
        "field": "transport_mode", "reason": "persist_failed"}]
    assert rebuilds == []


def test_broker_timeout_rolls_back_exact_prior_p2p_intent(tmp_path):
    p = _player(tmp_path)
    p.state.commit_transport(mode="p2p", host="")
    revision = p.state.commit_transport(
        mode="broker", host="10.0.0.8", port=8770, use_wss=False)
    rebuilds = []

    async def _fake_rebuild():
        rebuilds.append(p.state.transport_mode)

    p._rebuild_transport = _fake_rebuild  # type: ignore[assignment]
    _run(p._rebuild_transport_with_rollback(
        revision=revision,
        new_mode="broker",
        old_mode="p2p",
        old_host="",
        old_port=8770,
        old_wss=False,
        rollback_timeout_ms=0,
    ))
    assert rebuilds == ["broker", "p2p"]
    assert p.state.transport_mode == "p2p"
    assert p.state.broker_host is None
    assert p.cfg.get("broker", "host") == "127.0.0.1"
    assert p.cfg.get("topology", "auto") is False


def test_broker_migration_accepts_welcome_only_from_expected_generation(tmp_path):
    p = _player(tmp_path)
    p.state.commit_transport(mode="p2p", host="")
    revision = p.state.commit_transport(
        mode="broker", host="10.0.0.8", port=8770, use_wss=False)
    rebuilds = []

    async def _fake_rebuild():
        rebuilds.append(p.state.transport_mode)
        return 42

    p._rebuild_transport = _fake_rebuild  # type: ignore[assignment]
    p._welcomed_transport_generation = 42
    _run(p._rebuild_transport_with_rollback(
        revision=revision, new_mode="broker", old_mode="p2p",
        old_host="", old_port=8770, old_wss=False,
        rollback_timeout_ms=0))
    assert rebuilds == ["broker"]
    assert p.state.transport_mode == "broker"


def test_broker_migration_ignores_stale_generation_welcome(tmp_path):
    p = _player(tmp_path)
    p.state.commit_transport(mode="p2p", host="")
    revision = p.state.commit_transport(
        mode="broker", host="10.0.0.8", port=8770, use_wss=False)
    rebuilds = []

    async def _fake_rebuild():
        rebuilds.append(p.state.transport_mode)
        return 42

    p._rebuild_transport = _fake_rebuild  # type: ignore[assignment]
    p._welcomed_transport_generation = 41
    _run(p._rebuild_transport_with_rollback(
        revision=revision, new_mode="broker", old_mode="p2p",
        old_host="", old_port=8770, old_wss=False,
        rollback_timeout_ms=0))
    assert rebuilds == ["broker", "p2p"]
    assert p.state.transport_mode == "p2p"


def test_transport_phase1_status_failure_restores_old_route_without_rebuild(tmp_path):
    p = _player(tmp_path)
    old_ws = p.ws
    p._active_transport_generation = 17
    p.state.commit_transport(mode="p2p", host="")
    p._apply_transport_state()
    rebuilds = []

    async def _fail_status():
        raise ConnectionError("old route closed")

    async def _fake_rebuild(**_kwargs):
        rebuilds.append(True)

    p._send_status = _fail_status  # type: ignore[assignment]
    p._rebuild_transport_with_rollback = _fake_rebuild  # type: ignore[assignment]
    _run(p._h_transport_configure({
        "device_id": p.device_id, "request_id": "status-failure",
        "broker_host": "10.0.0.8", "broker_port": 8770,
        "use_wss": False, "transport_mode": "broker",
    }, {}))
    assert p.state.transport_mode == "p2p"
    assert p.state.broker_host is None
    assert p.cfg.get("broker", "host") == "127.0.0.1"
    assert p.cfg.get("topology", "auto") is False
    assert p.ws is old_ws
    assert p._active_transport_generation == 17
    assert rebuilds == []


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


def _seed_playlist(p, item_id="v1", type_="video", push_id="push-1"):
    # §6.3b: the resolved playlist carries the push_id the controller assigned;
    # prepare/play_at only act when the payload echoes this exact push_id.
    pl = {"playlist_id": "pl1", "push_id": push_id, "items": [
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
            {"playlist_id": "pl1", "push_id": "push-1", "start_index": 0,
             "prefetch": True, "barrier_timeout_ms": 5000}, {})
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
            {"playlist_id": "pl1", "push_id": "push-1", "start_index": 0,
             "prefetch": True, "barrier_timeout_ms": 50}, {})  # never marked ready
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
        {"playlist_id": "pl1", "push_id": "push-1", "start_index": 0}, {}))  # no prefetch flag
    readies = [pl for (t, pl) in p.ws.sent if t == "ready"]
    assert len(readies) == 1
    assert readies[0]["ready"] is False  # legacy behavior preserved


def test_prepare_ready_echoes_p2p_session_identity(tmp_path):
    p = _player(tmp_path)
    dl = _FakeDownloader()
    p.downloader = dl  # type: ignore[assignment]
    _seed_playlist(p)

    _run(p._h_prepare({
        "playlist_id": "pl1",
        "push_id": "push-1",
        "prepare_id": "prep-42",
        "group_id": "lobby",
        "start_index": 0,
    }, {}))

    readies = [pl for (t, pl) in p.ws.sent if t == "ready"]
    assert len(readies) == 1
    assert readies[0]["prepare_id"] == "prep-42"
    assert readies[0]["group_id"] == "lobby"


# ---- §6.3b push_id adoption gate (player half) ---------------------

def test_prepare_rejects_wrong_push_id(tmp_path):
    """§6.3b: a prepare whose push_id does not match the resolved playlist's
    assigned push_id is a stale/foreign session — the player must ignore it
    entirely (no prefetch, no ready), never adopting a superseded push."""
    p = _player(tmp_path)
    dl = _FakeDownloader()
    p.downloader = dl  # type: ignore[assignment]
    _seed_playlist(p, push_id="push-current")

    _run(p._h_prepare(
        {"playlist_id": "pl1", "push_id": "push-stale", "start_index": 0}, {}))

    assert p.ws.sent == [], "prepare with mismatched push_id must be ignored"
    assert dl.prefetched == [], "must not prefetch for a stale push_id"


def test_prepare_rejects_missing_push_id(tmp_path):
    """§6.3b: a prepare with no push_id predates the adoption contract and is
    rejected fail-closed — the player never acts on an unidentified push."""
    p = _player(tmp_path)
    dl = _FakeDownloader()
    p.downloader = dl  # type: ignore[assignment]
    _seed_playlist(p, push_id="push-current")

    _run(p._h_prepare({"playlist_id": "pl1", "start_index": 0}, {}))

    assert p.ws.sent == [], "prepare without push_id must be ignored"
    assert dl.prefetched == [], "must not prefetch without a push_id"


def test_play_at_rejects_wrong_push_id(tmp_path):
    """§6.3b: the sync-critical play_at must also refuse a mismatched push_id,
    so a superseded controller session can never drive playback."""
    p = _player(tmp_path)
    dl = _FakeDownloader()
    p.downloader = dl  # type: ignore[assignment]
    _seed_playlist(p, push_id="push-current")
    dl.mark("v1")
    before_index = p.index

    _run(p._h_play_at({
        "playlist_id": "pl1",
        "push_id": "push-stale",
        "start_index": 0,
        "play_at": 0,
    }, {}))

    assert p.index == before_index, "play_at with wrong push_id must not advance"
    assert not p._mpv_calls, "play_at with wrong push_id must not touch mpv"


def test_debug_snapshot_returns_diagnostic_status(tmp_path):
    p = _player(tmp_path)

    _run(p._on_message("debug_snapshot", {"device_id": p.device_id},
                       {"msg_id": "debug-1"}))

    kind, payload = p.ws.sent[0]
    assert kind == "diagnostic_status"
    assert payload["device_id"] == p.device_id
    assert "play_state=" in payload["detail"]


def test_download_logs_returns_bounded_diagnostic_bundle(tmp_path):
    p = _player(tmp_path)

    _run(p._on_message("download_logs", {"device_id": p.device_id},
                       {"msg_id": "logs-1"}))

    kind, payload = p.ws.sent[0]
    assert kind == "download_logs_result"
    assert payload["device_id"] == p.device_id
    assert payload["file_name"].endswith(".log")
    assert "device_id=" in payload["text"]


def test_diagnostics_ignore_a_different_device_target(tmp_path):
    p = _player(tmp_path)

    _run(p._h_debug_snapshot({"device_id": "another-device"}, {}))
    _run(p._h_download_logs({"device_id": "another-device"}, {}))

    assert getattr(p.ws, "sent") == []
