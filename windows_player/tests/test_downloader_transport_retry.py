"""§6 transport-layer retry for Windows Downloader.

Mirrors Android DownloaderTransportRetryTest:

  - Instant ConnectionError must share the same retry budget as HTTP 429/503
    (field evidence on Android: 2 of 96 music items died on ConnectException
    with zero retries while 94 siblings of the same batch succeeded).
  - Budget exhaustion keeps the real exception name (not a generic code).
  - Truncated body (Content-Length larger than bytes actually received) is a
    transport failure, not a content failure: keep .part and resume with Range.
  - True content corruption (full length, wrong sha) still fails terminal.
"""
from __future__ import annotations

import hashlib
import os
import sys
import threading
import time
from typing import Any, Dict, List, Optional
from unittest import mock

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import downloader as D  # noqa: E402


def _item(item_id: str, data: bytes, url: str = "http://example/x") -> Dict[str, Any]:
    return {
        "item_id": item_id,
        "name": f"{item_id}.bin",
        "url": url,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


class _FakeResp:
    def __init__(
        self,
        status: int = 200,
        body: bytes = b"",
        headers: Optional[Dict[str, str]] = None,
        raise_on_iter: Optional[BaseException] = None,
    ):
        self.status_code = status
        self.headers = headers or {}
        self._body = body
        self._raise_on_iter = raise_on_iter
        self._entered = False

    def __enter__(self):
        self._entered = True
        return self

    def __exit__(self, *a):
        return False

    def iter_content(self, chunk_size: int = 256 * 1024):
        if self._raise_on_iter is not None:
            raise self._raise_on_iter
        # yield whole body as one chunk (tests are small)
        if self._body:
            yield self._body


def _wait(pred, timeout=3.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(0.01)
    return pred()


def test_transient_connection_error_is_retried_and_becomes_ready(tmp_path):
    data = b"abcdefghij"
    item = _item("connect-refused", data)
    attempts: List[Dict[str, str]] = []

    def fake_get(url, headers=None, stream=False, timeout=30.0):
        attempts.append(dict(headers or {}))
        if len(attempts) < 3:
            raise ConnectionError("Connection refused")
        return _FakeResp(
            status=200,
            body=data,
            headers={"Content-Length": str(len(data))},
        )

    dl = D.Downloader(
        tmp_path,
        retry_base_delay_s=0.001,
        retry_max_delay_s=0.01,
        max_retry_attempts=5,
    )
    with mock.patch.object(D, "requests") as req:
        req.get.side_effect = fake_get
        dl.prefetch([item])
        assert _wait(lambda: dl.is_ready("connect-refused")), dl.cache_status()
        assert dl.cache_status()["connect-refused"] == "ready"
        assert dl.ready_path("connect-refused").read_bytes() == data
        assert len(attempts) == 3
    dl.stop()


def test_transport_retries_share_budget_and_keep_exception_name(tmp_path):
    item = _item("always-refused", b"zz")
    attempts = {"n": 0}

    def always_refused(url, headers=None, stream=False, timeout=30.0):
        attempts["n"] += 1
        raise ConnectionError("Connection refused")

    dl = D.Downloader(
        tmp_path,
        retry_base_delay_s=0.001,
        retry_max_delay_s=0.005,
        max_retry_attempts=2,
    )
    with mock.patch.object(D, "requests") as req:
        req.get.side_effect = always_refused
        dl.prefetch([item])
        assert _wait(
            lambda: dl.cache_status().get("always-refused", "").startswith("error:")
        )
        assert dl.cache_status()["always-refused"] == "error:ConnectionError"
        # first try + 2 retries = 3
        assert attempts["n"] == 3
    dl.stop()


def test_truncated_body_resumes_with_range(tmp_path):
    data = b"0123456789"
    item = _item("stream-cut", data)
    seen_headers: List[Dict[str, str]] = []

    def fake_get(url, headers=None, stream=False, timeout=30.0):
        h = dict(headers or {})
        seen_headers.append(h)
        if len(seen_headers) == 1:
            # Claim 10 bytes, deliver 4 — silent short read, no exception.
            return _FakeResp(
                status=200,
                body=b"0123",
                headers={"Content-Length": "10"},
            )
        # Second attempt must resume from byte 4.
        assert h.get("Range") == "bytes=4-"
        return _FakeResp(
            status=206,
            body=b"456789",
            headers={
                "Content-Length": "6",
                "Content-Range": "bytes 4-9/10",
            },
        )

    dl = D.Downloader(
        tmp_path,
        retry_base_delay_s=0.001,
        retry_max_delay_s=0.01,
        max_retry_attempts=3,
    )
    with mock.patch.object(D, "requests") as req:
        req.get.side_effect = fake_get
        dl.prefetch([item])
        assert _wait(lambda: dl.is_ready("stream-cut"), timeout=4.0), dl.cache_status()
        assert dl.ready_path("stream-cut").read_bytes() == data
        assert len(seen_headers) == 2
        assert seen_headers[1].get("Range") == "bytes=4-"
    dl.stop()


def test_true_sha_mismatch_still_terminal_and_deletes_part(tmp_path):
    """B2 black-screen guard must remain: full-length wrong content dies terminal."""
    good = b"0123456789"
    bad = b"XXXXXXXXXX"  # same length, wrong bytes
    item = _item("corrupt", good)  # sha of good

    def fake_get(url, headers=None, stream=False, timeout=30.0):
        return _FakeResp(
            status=200,
            body=bad,
            headers={"Content-Length": str(len(bad))},
        )

    dl = D.Downloader(tmp_path, max_retry_attempts=2)
    with mock.patch.object(D, "requests") as req:
        req.get.side_effect = fake_get
        dl.prefetch([item])
        assert _wait(
            lambda: dl.cache_status().get("corrupt") == "error:sha256-mismatch"
        )
        part = dl.local_path(item).with_suffix(dl.local_path(item).suffix + ".part")
        assert not part.exists(), "corrupt full body must delete .part"
    dl.stop()
