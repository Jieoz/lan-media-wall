"""Thumbnail scaling/encoding (§6.4) + persistent state (§4/§10)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import thumbnailer as T  # noqa: E402
import config as C  # noqa: E402


def test_scale_dims_caps_width():
    assert T.scale_dims(1920, 1080, 320) == (320, 180)
    assert T.scale_dims(640, 480, 320) == (320, 240)


def test_scale_dims_no_upscale():
    assert T.scale_dims(200, 100, 320) == (200, 100)  # already small


def test_scale_dims_degenerate():
    assert T.scale_dims(0, 0, 320) == (320, 320)


def test_encode_jpeg_roundtrip(tmp_path):
    pytest_pil = __import__("PIL.Image", fromlist=["Image"])
    img = pytest_pil.new("RGB", (1280, 720), (10, 20, 30))
    src = tmp_path / "frame.png"
    img.save(src)
    data = T.encode_jpeg(src, max_width=320, quality=70)
    assert data[:2] == b"\xff\xd8"        # JPEG SOI marker
    # verify it decodes to ≤320 wide
    import io
    out = pytest_pil.open(io.BytesIO(data))
    assert out.width <= 320


def test_persistent_state_device_id_stable(tmp_path):
    s1 = C.PersistentState.load(tmp_path)
    did = s1.device_id
    assert did.startswith("win-")
    # reload → same id
    s2 = C.PersistentState.load(tmp_path)
    assert s2.device_id == did


def test_persistent_state_device_name_first_boot(tmp_path):
    s = C.PersistentState.load(tmp_path)
    name = s.device_name("大厅左屏")
    assert name == "大厅左屏"
    # persists and ignores later fallback
    s2 = C.PersistentState.load(tmp_path)
    assert s2.device_name("other") == "大厅左屏"


def test_persistent_state_last_task_and_group(tmp_path):
    s = C.PersistentState.load(tmp_path)
    s.set_group_id("lobby")
    s.set_last_task({"playlist_id": "pl-1", "index": 2, "seek_ms": 500})
    s2 = C.PersistentState.load(tmp_path)
    assert s2.group_id == "lobby"
    assert s2.last_task["index"] == 2


def test_config_env_psk_override(tmp_path, monkeypatch):
    cfg = C.load_config(None)  # defaults
    monkeypatch.setenv("LMW_PSK", "env-secret-key")
    assert cfg.psk == "env-secret-key"   # env wins over file/default


def test_config_broker_url():
    cfg = C.load_config(None)
    assert cfg.broker_url.startswith("ws://")
    cfg.raw["broker"]["use_wss"] = True
    assert cfg.broker_url.startswith("wss://")
