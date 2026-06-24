"""Cohost broker entry resolution (§14.2) — pure resolver against fakes."""
import asyncio
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import cohost as C  # noqa: E402


class _ModRunBroker:
    """Fake broker exposing the brief's documented run_broker(config)."""
    def __init__(self):
        self.called_with = None

    def run_broker(self, config):
        self.called_with = config
        async def _coro():
            return "ran-run_broker"
        return _coro()


class _ModRun:
    """Fake broker exposing the actual current async run(cfg)."""
    def __init__(self):
        self.called_with = None

    async def run(self, cfg):
        self.called_with = cfg
        return "ran-run"


class _ModRunSync:
    """Fake broker whose run() returns a plain value (not a coroutine)."""
    def run(self, cfg):
        return None


class _ModEmpty:
    pass


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def test_prefers_run_broker_when_present():
    mod = _ModRunBroker()
    cfg = {"psk": "x"}
    factory = C.resolve_broker_entry(mod, cfg)
    _run(factory())
    assert mod.called_with is cfg


def test_falls_back_to_run():
    mod = _ModRun()
    cfg = {"psk": "y"}
    factory = C.resolve_broker_entry(mod, cfg)
    _run(factory())
    assert mod.called_with is cfg


def test_sync_returning_entry_is_wrapped():
    mod = _ModRunSync()
    factory = C.resolve_broker_entry(mod, {"psk": "z"})
    # should not raise even though run() returns a non-awaitable
    _run(factory())


def test_run_broker_takes_priority_over_run():
    # a module with BOTH must use run_broker (the documented name)
    class Both:
        def __init__(self):
            self.which = None
        def run_broker(self, config):
            self.which = "run_broker"
            async def _c():
                return None
            return _c()
        async def run(self, cfg):
            self.which = "run"
    mod = Both()
    _run(C.resolve_broker_entry(mod, {})())
    assert mod.which == "run_broker"


def test_no_entry_raises():
    with pytest.raises(AttributeError):
        C.resolve_broker_entry(_ModEmpty(), {})


def test_build_broker_config_shape():
    cfg = C.build_broker_config("mypsk", auth_mode="required",
                                ws_port=8770, discovery_port=8772)
    assert cfg["psk"] == "mypsk"
    assert cfg["ws_port"] == 8770
    assert cfg["wss_port"] == 8771
    assert cfg["auth_mode"] == "required"
    assert cfg["topology"] == "cohosted"
    assert cfg["enable_discovery"] is False
