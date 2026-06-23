"""Thumbnail capture (§6.4): grab the current frame from mpv, scale to a
≤max_width JPEG, return the bytes. main pairs each JPEG with a thumb_meta
JSON frame + the binary WS frame, and only runs this when a controller is
present (bandwidth gate).

mpv writes a screenshot to a temp PNG via IPC (screenshot-to-file); Pillow then
downscales + re-encodes to JPEG. Pillow is required; mpv access is via the
controller passed in.
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Optional

try:
    from PIL import Image
except Exception:  # pragma: no cover
    Image = None  # type: ignore


def scale_dims(w: int, h: int, max_width: int) -> "tuple[int, int]":
    """Aspect-preserving target size capped at max_width wide."""
    if w <= 0 or h <= 0:
        return (max_width, max_width)
    if w <= max_width:
        return (w, h)
    ratio = max_width / float(w)
    return (max_width, max(1, int(round(h * ratio))))


def encode_jpeg(src_png: Path, max_width: int = 320, quality: int = 70) -> bytes:
    """Downscale a PNG to ≤max_width and JPEG-encode it. Pure-ish (file in,
    bytes out) so it's unit-testable with a synthetic image."""
    if Image is None:
        raise RuntimeError("Pillow not available")
    with Image.open(src_png) as im:
        im = im.convert("RGB")
        tw, th = scale_dims(im.width, im.height, max_width)
        if (tw, th) != (im.width, im.height):
            im = im.resize((tw, th), Image.BILINEAR)
        import io
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=quality, optimize=True)
        return buf.getvalue()


class Thumbnailer:
    def __init__(self, controller, *, max_width: int = 320, quality: int = 70,
                 tmp_dir: Optional[str] = None):
        self.controller = controller
        self.max_width = max_width
        self.quality = quality
        self.tmp_dir = tmp_dir or tempfile.gettempdir()
        self._seq = 0

    def capture(self) -> Optional["tuple[int, bytes]"]:
        """Capture one frame. Returns (seq, jpeg_bytes) or None if nothing is
        playing / capture failed."""
        if self.controller is None or not getattr(self.controller, "connected", False):
            return None
        png_path = Path(self.tmp_dir) / "lmw-thumb.png"
        try:
            # don't bother if idle (black screen) — still produce a frame so the
            # wall shows the device is alive; mpv screenshots black fine.
            self.controller.screenshot_to(str(png_path))
        except Exception:
            return None
        if not png_path.exists() or png_path.stat().st_size == 0:
            return None
        try:
            jpeg = encode_jpeg(png_path, self.max_width, self.quality)
        except Exception:
            return None
        finally:
            try:
                png_path.unlink(missing_ok=True)
            except Exception:
                pass
        self._seq += 1
        return (self._seq, jpeg)
