"""Resumable media download + sha256 verification + cache manager (§6).

Downloads media items in the background via HTTP Range (WebDAV/HTTP GET — SMB
deliberately avoided per §6.1). Partial downloads land in `<item>.part` and are
resumed from their current byte length using a `Range: bytes=N-` request. On
completion the file is sha256-verified against the item's `sha256` (when given)
and atomically renamed into place. Cache state is exposed in the exact shape
status.cache wants: "ready" | "downloading:NN%" | "error" | "verifying".

The Range math (offset/headers/expected total) is pure and unit-tested; the
network loop is thin around it.
"""

from __future__ import annotations

import hashlib
import os
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

try:
    import requests
except Exception:  # pragma: no cover
    requests = None  # type: ignore


def range_header(existing_bytes: int) -> Optional[Dict[str, str]]:
    """Header to resume from `existing_bytes`. None when starting fresh."""
    if existing_bytes <= 0:
        return None
    return {"Range": f"bytes={existing_bytes}-"}


def percent(downloaded: int, total: Optional[int]) -> int:
    """Integer 0–100 progress. Unknown total → 0 until done is signalled."""
    if not total or total <= 0:
        return 0
    return max(0, min(100, int(downloaded * 100 // total)))


def expected_total(existing_bytes: int, resp_status: int,
                   content_length: Optional[int],
                   content_range_total: Optional[int]) -> Optional[int]:
    """Resolve the full object size from a (possibly partial) response.

    - 206 + Content-Range "bytes a-b/TOTAL" → TOTAL is authoritative.
    - 206 with only Content-Length L → existing + L.
    - 200 (server ignored Range) → Content-Length is the whole object.
    """
    if resp_status == 206:
        if content_range_total is not None:
            return content_range_total
        if content_length is not None:
            return existing_bytes + content_length
        return None
    # 200 OK: full body, server ignored our Range
    return content_length


def parse_content_range_total(value: Optional[str]) -> Optional[int]:
    """Parse the TOTAL out of a Content-Range header: 'bytes 0-99/12345'."""
    if not value:
        return None
    try:
        # format: bytes <start>-<end>/<total>  (total may be '*')
        tail = value.split("/")[-1].strip()
        if tail == "*":
            return None
        return int(tail)
    except (ValueError, IndexError):
        return None


def sha256_file(path: Path, chunk: int = 1024 * 1024) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


@dataclass
class CacheEntry:
    item_id: str
    state: str = "pending"   # pending|downloading|verifying|ready|error
    progress: int = 0        # 0–100
    error: str = ""
    path: Optional[Path] = None

    def status_value(self) -> str:
        """Render to the status.cache string form (§5.1)."""
        if self.state == "ready":
            return "ready"
        if self.state == "downloading":
            return f"downloading:{self.progress}%"
        if self.state == "verifying":
            return "verifying"
        if self.state == "error":
            return f"error:{self.error}" if self.error else "error"
        return self.state


class Downloader:
    """Background, single-worker (per item) resumable downloader with a cache
    map. Thread-safe for status reads."""

    def __init__(self, cache_dir: Path, *,
                 on_change: Optional[Callable[[], None]] = None,
                 chunk_size: int = 256 * 1024,
                 timeout: float = 30.0):
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.on_change = on_change
        self.chunk_size = chunk_size
        self.timeout = timeout
        self._entries: Dict[str, CacheEntry] = {}
        self._threads: Dict[str, threading.Thread] = {}
        self._lock = threading.Lock()
        self._stop = threading.Event()

    # --- public API ---------------------------------------------------
    def local_path(self, item: Dict[str, Any]) -> Path:
        """Stable on-disk name. Prefer sha256 (content-addressed) so identical
        media de-dupes; fall back to item_id + extension."""
        name = item.get("name", item["item_id"])
        ext = os.path.splitext(name)[1] or ".bin"
        sha = item.get("sha256")
        stem = sha if sha else str(item["item_id"])
        return self.cache_dir / f"{stem}{ext}"

    def cache_status(self) -> Dict[str, str]:
        with self._lock:
            return {k: e.status_value() for k, e in self._entries.items()}

    def is_ready(self, item_id: str) -> bool:
        with self._lock:
            e = self._entries.get(item_id)
            return bool(e and e.state == "ready")

    def ready_path(self, item_id: str) -> Optional[Path]:
        with self._lock:
            e = self._entries.get(item_id)
            if e and e.state == "ready" and e.path:
                return e.path
            return None

    def prefetch(self, items: List[Dict[str, Any]]) -> None:
        """Queue a batch (§6.2). Already-ready items are skipped; others get a
        background worker thread."""
        for item in items:
            self._ensure_entry_and_start(item)

    def _ensure_entry_and_start(self, item: Dict[str, Any]) -> None:
        item_id = item["item_id"]
        target = self.local_path(item)
        with self._lock:
            # already on disk and matching → mark ready without re-download
            entry = self._entries.get(item_id)
            if entry and entry.state in ("downloading", "verifying"):
                return  # in flight
            if target.exists() and self._quick_ok(target, item):
                self._entries[item_id] = CacheEntry(
                    item_id=item_id, state="ready", progress=100, path=target)
                self._notify()
                return
            self._entries[item_id] = CacheEntry(item_id=item_id, state="pending")
            t = threading.Thread(target=self._worker, args=(item,),
                                 name=f"dl-{item_id}", daemon=True)
            self._threads[item_id] = t
        t.start()

    def _quick_ok(self, path: Path, item: Dict[str, Any]) -> bool:
        size = item.get("size")
        if size is not None and path.stat().st_size != size:
            return False
        # if sha provided, trust a prior verified rename; size match is enough
        # to avoid rehashing huge files every prefetch. Full hash happens on
        # the download completion path.
        return True

    # --- worker -------------------------------------------------------
    def _worker(self, item: Dict[str, Any]) -> None:
        item_id = item["item_id"]
        target = self.local_path(item)
        part = target.with_suffix(target.suffix + ".part")
        url = item["url"]
        if requests is None:
            self._fail(item_id, "requests-unavailable")
            return
        try:
            existing = part.stat().st_size if part.exists() else 0
            headers = range_header(existing) or {}
            with requests.get(url, headers=headers, stream=True,
                              timeout=self.timeout) as resp:
                if resp.status_code not in (200, 206):
                    self._fail(item_id, f"http-{resp.status_code}")
                    return
                if resp.status_code == 200 and existing:
                    # server ignored Range → restart from scratch
                    existing = 0
                    part.unlink(missing_ok=True)
                clen = resp.headers.get("Content-Length")
                clen_i = int(clen) if clen and clen.isdigit() else None
                cr_total = parse_content_range_total(
                    resp.headers.get("Content-Range"))
                total = expected_total(existing, resp.status_code, clen_i,
                                       cr_total) or item.get("size")
                downloaded = existing
                self._set(item_id, state="downloading",
                          progress=percent(downloaded, total), path=None)
                mode = "ab" if existing else "wb"
                with part.open(mode) as f:
                    for chunk in resp.iter_content(self.chunk_size):
                        if self._stop.is_set():
                            return  # leave .part for next resume
                        if not chunk:
                            continue
                        f.write(chunk)
                        downloaded += len(chunk)
                        self._set(item_id, state="downloading",
                                  progress=percent(downloaded, total))
            # verify
            self._set(item_id, state="verifying")
            sha = item.get("sha256")
            if sha:
                actual = sha256_file(part)
                if actual.lower() != str(sha).lower():
                    part.unlink(missing_ok=True)  # corrupt; force clean retry
                    self._fail(item_id, "sha256-mismatch")
                    return
            part.replace(target)  # atomic publish
            self._set(item_id, state="ready", progress=100, path=target)
        except Exception as exc:  # network/IO — keep .part for resume
            self._fail(item_id, type(exc).__name__)

    # --- state helpers ------------------------------------------------
    def _set(self, item_id: str, **kw: Any) -> None:
        with self._lock:
            e = self._entries.setdefault(item_id, CacheEntry(item_id=item_id))
            for k, v in kw.items():
                setattr(e, k, v)
        self._notify()

    def _fail(self, item_id: str, err: str) -> None:
        self._set(item_id, state="error", error=err)

    def _notify(self) -> None:
        if self.on_change:
            try:
                self.on_change()
            except Exception:
                pass

    def stop(self) -> None:
        self._stop.set()
