"""Resumable-download Range math + sha256 + cache state (protocol §6)."""
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import downloader as D  # noqa: E402


def test_range_header():
    assert D.range_header(0) is None
    assert D.range_header(-5) is None
    assert D.range_header(1024) == {"Range": "bytes=1024-"}


def test_percent():
    assert D.percent(0, 100) == 0
    assert D.percent(45, 100) == 45
    assert D.percent(100, 100) == 100
    assert D.percent(50, 0) == 0       # unknown total
    assert D.percent(200, 100) == 100  # clamp


def test_parse_content_range_total():
    assert D.parse_content_range_total("bytes 0-99/12345") == 12345
    assert D.parse_content_range_total("bytes 100-199/500") == 500
    assert D.parse_content_range_total("bytes 0-99/*") is None
    assert D.parse_content_range_total(None) is None
    assert D.parse_content_range_total("garbage") is None


def test_status_value_never_reports_100_before_ready():
    """§6.4 (E0001) truthfulness: the last chunk drives progress to 100 while the
    state is still `downloading` (verify + atomic publish happen after). The wire
    projection MUST cap that at 99 — 100 appears only as `ready`, so the
    controller never sees completion before the checksum/atomic finalize."""
    e = D.CacheEntry(item_id="a")
    e.state = "downloading"
    e.progress = 45
    assert e.status_value() == "downloading:45%"
    # final chunk: bytes complete but not verified/published yet
    e.progress = 100
    assert e.status_value() == "downloading:99%", "must not show 100 pre-finalize"
    # verify phase carries no percent
    e.state = "verifying"
    assert e.status_value() == "verifying"
    # only the atomic-published, checksum-verified item is ready==100
    e.state = "ready"
    e.progress = 100
    assert e.status_value() == "ready"


def test_status_value_downloading_floors_negative():
    """Defensive: a bogus negative progress never renders a negative percent."""
    e = D.CacheEntry(item_id="a")
    e.state = "downloading"
    e.progress = -3
    assert e.status_value() == "downloading:0%"


def test_expected_total_206_with_content_range():
    # resume from 1024; partial body of 500; content-range says full is 99999
    assert D.expected_total(1024, 206, 500, 99999) == 99999


def test_expected_total_206_without_content_range():
    # only Content-Length of the partial → existing + length
    assert D.expected_total(1024, 206, 500, None) == 1524


def test_expected_total_200_full_body():
    # server ignored Range → 200, Content-Length is whole object
    assert D.expected_total(1024, 200, 99999, None) == 99999


def test_sha256_file(tmp_path):
    p = tmp_path / "blob.bin"
    data = b"hello media wall" * 1000
    p.write_bytes(data)
    assert D.sha256_file(p) == hashlib.sha256(data).hexdigest()


def test_cache_entry_status_rendering():
    e = D.CacheEntry(item_id="a1", state="downloading", progress=45)
    assert e.status_value() == "downloading:45%"
    e.state = "ready"
    assert e.status_value() == "ready"
    e.state = "verifying"
    assert e.status_value() == "verifying"
    e.state = "error"; e.error = "sha256-mismatch"
    assert e.status_value() == "error:sha256-mismatch"


def test_local_path_content_addressed(tmp_path):
    dl = D.Downloader(tmp_path)
    item = {"item_id": "a1", "name": "promo.mp4", "sha256": "deadbeef"}
    p = dl.local_path(item)
    assert p.name == "deadbeef.mp4"        # sha-stem + original ext
    item2 = {"item_id": "b2", "name": "clip.webm"}  # no sha
    assert dl.local_path(item2).name == "b2.webm"


def test_prefetch_marks_existing_ready(tmp_path):
    dl = D.Downloader(tmp_path)
    item = {"item_id": "a1", "name": "x.bin", "size": 12}
    # pre-place a matching-size file at the content path
    target = dl.local_path(item)
    target.write_bytes(b"123456789012")
    dl.prefetch([item])
    assert dl.is_ready("a1")
    assert dl.cache_status()["a1"] == "ready"
    assert dl.ready_path("a1") == target
