"""Broker media library HTTP server (§20.1, protocol_spec v1.4).

A minimal, dependency-free (stdlib asyncio) HTTP/1.1 server that lets the
controller upload local files to the broker, which then serves them back to
players over the *existing* cache_prefetch download path (§6.2). This is mode B
of the local-upload design (docs/controller-ux-redesign.md §2.1).

Endpoints
---------
  PUT  /media/<sha256>.<ext>        upload a file; body = raw bytes.
      - The path's <sha256> is authoritative: the server hashes the received
        bytes and rejects (400) if they don't match.
      - Idempotent: if <sha256> already on disk, returns 200 without rewriting.
      - Enforces max_bytes (413 when exceeded).
  GET  /media/<sha256>.<ext>        download; supports Range (206) for the
                                    player's resumable/byte-range fetch (§6.2).
  HEAD /media/<sha256>.<ext>        metadata only (Content-Length / Accept-Ranges).

Design notes
------------
- Files are stored by content hash, so name collisions and duplicate uploads
  are free (dedup + "instant upload" when the hash already exists).
- Downloads are intentionally open so players can cache media by URL. Uploads
  can be gated with an optional bearer token for less-trusted LANs.
- Kept deliberately small and framework-free so it runs on the Synology Docker
  broker image without adding aiohttp/starlette.
"""
from __future__ import annotations

import asyncio
import hmac
import hashlib
import logging
import os
import re
from typing import Optional, Tuple

log = logging.getLogger("broker.media")

DEFAULT_MEDIA_PORT = 8773
DEFAULT_MAX_BYTES = 500 * 1024 * 1024  # 500 MB (§20.1 / contract §4.9)

# Only hex sha256 (optionally with a short extension) is a valid media name.
_NAME_RE = re.compile(r"^([0-9a-fA-F]{64})(?:\.([A-Za-z0-9]{1,8}))?$")

_CONTENT_TYPES = {
    "mp4": "video/mp4", "mov": "video/quicktime", "mkv": "video/x-matroska",
    "webm": "video/webm", "m4v": "video/x-m4v",
    "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
    "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp",
}


def _content_type(ext: str) -> str:
    return _CONTENT_TYPES.get(ext.lower(), "application/octet-stream")


class MediaServer:
    """Stdlib-asyncio HTTP server for the broker media library."""

    def __init__(self, media_dir: str, *, port: int = DEFAULT_MEDIA_PORT,
                 max_bytes: int = DEFAULT_MAX_BYTES, bind_host: str = "0.0.0.0",
                 upload_token: str = ""):
        self.media_dir = media_dir
        self.port = port
        self.max_bytes = max_bytes
        self.bind_host = bind_host or "0.0.0.0"
        self.upload_token = upload_token or ""
        self._server: Optional[asyncio.AbstractServer] = None
        os.makedirs(self.media_dir, exist_ok=True)

    # ---- lifecycle -------------------------------------------------------
    async def start(self) -> None:
        self._server = await asyncio.start_server(
            self._handle_client, self.bind_host, self.port)
        auth_note = "upload-token" if self.upload_token else "open-upload"
        log.info("broker media library on %s:%d (dir=%s, max=%dMB, %s)",
                 self.bind_host, self.port, self.media_dir,
                 self.max_bytes // (1024 * 1024), auth_note)

    def stop(self) -> None:
        if self._server is not None:
            self._server.close()

    async def wait_closed(self) -> None:
        if self._server is not None:
            await self._server.wait_closed()

    # ---- path helpers ----------------------------------------------------
    def _safe_path(self, name: str) -> Optional[Tuple[str, str, str]]:
        """Validate a /media/<name>; return (abs_path, sha256, ext) or None."""
        m = _NAME_RE.match(name)
        if not m:
            return None
        sha, ext = m.group(1).lower(), (m.group(2) or "").lower()
        fname = f"{sha}.{ext}" if ext else sha
        abs_path = os.path.abspath(os.path.join(self.media_dir, fname))
        # Path-traversal guard: must stay inside media_dir.
        if os.path.dirname(abs_path) != os.path.abspath(self.media_dir):
            return None
        return abs_path, sha, ext

    # ---- HTTP plumbing ---------------------------------------------------
    async def _handle_client(self, reader: asyncio.StreamReader,
                             writer: asyncio.StreamWriter) -> None:
        try:
            request_line = await reader.readline()
            if not request_line:
                return
            parts = request_line.decode("latin1").split()
            if len(parts) < 2:
                await self._send_simple(writer, 400, "Bad Request")
                return
            method, target = parts[0].upper(), parts[1]
            headers = await self._read_headers(reader)

            path = target.split("?", 1)[0]
            if not path.startswith("/media/"):
                await self._send_simple(writer, 404, "Not Found")
                return
            name = path[len("/media/"):]
            resolved = self._safe_path(name)
            if resolved is None:
                await self._send_simple(writer, 400, "Bad media name")
                return
            abs_path, sha, ext = resolved

            if method == "PUT" or method == "POST":
                if not self._upload_authorized(headers):
                    await self._send_simple(writer, 401, "Unauthorized")
                    return
                await self._handle_put(reader, writer, headers, abs_path, sha, ext)
            elif method in ("GET", "HEAD"):
                await self._handle_get(writer, headers, abs_path, ext,
                                       head_only=(method == "HEAD"))
            else:
                await self._send_simple(writer, 405, "Method Not Allowed")
        except Exception as exc:
            log.debug("media request error: %s", exc)
            try:
                await self._send_simple(writer, 500, "Internal Error")
            except Exception:
                pass
        finally:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

    async def _read_headers(self, reader: asyncio.StreamReader) -> dict:
        headers: dict = {}
        while True:
            line = await reader.readline()
            if not line or line in (b"\r\n", b"\n"):
                break
            try:
                k, v = line.decode("latin1").split(":", 1)
                headers[k.strip().lower()] = v.strip()
            except ValueError:
                continue
        return headers

    def _upload_authorized(self, headers: dict) -> bool:
        if not self.upload_token:
            return True
        auth = headers.get("authorization", "")
        prefix = "Bearer "
        if not auth.startswith(prefix):
            return False
        return hmac.compare_digest(auth[len(prefix):].strip(), self.upload_token)

    # ---- PUT (upload, §20.1) --------------------------------------------
    async def _handle_put(self, reader: asyncio.StreamReader,
                          writer: asyncio.StreamWriter, headers: dict,
                          abs_path: str, sha: str, ext: str) -> None:
        try:
            length = int(headers.get("content-length", "0"))
        except ValueError:
            length = -1
        if length < 0:
            await self._send_simple(writer, 411, "Length Required")
            return
        if length > self.max_bytes:
            await self._send_simple(writer, 413, "Payload Too Large")
            return

        # Idempotent: identical content hash already stored -> instant 200.
        if os.path.exists(abs_path) and self._verify_existing(abs_path, sha):
            await self._drain(reader, length)
            await self._send_simple(writer, 200, "OK (exists)")
            return

        tmp = abs_path + ".part"
        hasher = hashlib.sha256()
        remaining = length
        try:
            with open(tmp, "wb") as fh:
                while remaining > 0:
                    chunk = await reader.read(min(65536, remaining))
                    if not chunk:
                        break
                    fh.write(chunk)
                    hasher.update(chunk)
                    remaining -= len(chunk)
        except OSError as exc:
            self._unlink(tmp)
            log.warning("media write failed: %s", exc)
            await self._send_simple(writer, 500, "Write Failed")
            return

        if remaining != 0:
            self._unlink(tmp)
            await self._send_simple(writer, 400, "Truncated Body")
            return
        if hasher.hexdigest() != sha:
            self._unlink(tmp)
            await self._send_simple(writer, 400, "sha256 mismatch")
            return
        os.replace(tmp, abs_path)
        log.info("media stored %s (%d bytes)", os.path.basename(abs_path), length)
        await self._send_simple(writer, 201, "Created")

    def _verify_existing(self, abs_path: str, sha: str) -> bool:
        """Cheap trust: an on-disk file named by its hash is assumed valid.
        (Full re-hash on every idempotent PUT would be wasteful for big video.)"""
        try:
            return os.path.getsize(abs_path) > 0
        except OSError:
            return False

    async def _drain(self, reader: asyncio.StreamReader, length: int) -> None:
        remaining = length
        while remaining > 0:
            chunk = await reader.read(min(65536, remaining))
            if not chunk:
                break
            remaining -= len(chunk)

    # ---- GET / HEAD (download with Range, §6.2/§20.1) -------------------
    async def _handle_get(self, writer: asyncio.StreamWriter, headers: dict,
                          abs_path: str, ext: str, *, head_only: bool) -> None:
        if not os.path.exists(abs_path):
            await self._send_simple(writer, 404, "Not Found")
            return
        size = os.path.getsize(abs_path)
        ctype = _content_type(ext)
        start, end = 0, size - 1
        status, reason = 200, "OK"

        rng = headers.get("range")
        if rng:
            parsed = self._parse_range(rng, size)
            if parsed is None:
                extra = [f"Content-Range: bytes */{size}"]
                await self._send_head(writer, 416,
                                      "Range Not Satisfiable", 0, ctype, extra)
                return
            start, end = parsed
            status, reason = 206, "Partial Content"

        clen = end - start + 1
        extra = ["Accept-Ranges: bytes"]
        if status == 206:
            extra.append(f"Content-Range: bytes {start}-{end}/{size}")
        await self._send_head(writer, status, reason, clen, ctype, extra)
        if head_only:
            return

        with open(abs_path, "rb") as fh:
            fh.seek(start)
            remaining = clen
            while remaining > 0:
                chunk = fh.read(min(65536, remaining))
                if not chunk:
                    break
                writer.write(chunk)
                await writer.drain()
                remaining -= len(chunk)

    @staticmethod
    def _parse_range(rng: str, size: int) -> Optional[Tuple[int, int]]:
        """Parse a single 'bytes=start-end' range. Returns (start, end) or None."""
        if not rng.startswith("bytes="):
            return None
        spec = rng[len("bytes="):].split(",")[0].strip()
        if "-" not in spec:
            return None
        a, _, b = spec.partition("-")
        try:
            if a == "":  # suffix range: bytes=-N (last N bytes)
                n = int(b)
                if n <= 0:
                    return None
                start = max(0, size - n)
                return start, size - 1
            start = int(a)
            end = int(b) if b else size - 1
        except ValueError:
            return None
        if start > end or start >= size:
            return None
        return start, min(end, size - 1)

    # ---- response helpers ------------------------------------------------
    async def _send_head(self, writer: asyncio.StreamWriter, status: int,
                         reason: str, content_length: int, ctype: str,
                         extra_headers: Optional[list] = None) -> None:
        lines = [
            f"HTTP/1.1 {status} {reason}",
            f"Content-Type: {ctype}",
            f"Content-Length: {content_length}",
            "Connection: close",
        ]
        if extra_headers:
            lines.extend(extra_headers)
        writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("latin1"))
        await writer.drain()

    async def _send_simple(self, writer: asyncio.StreamWriter, status: int,
                          reason: str) -> None:
        body = reason.encode("utf-8")
        lines = [
            f"HTTP/1.1 {status} {reason}",
            "Content-Type: text/plain; charset=utf-8",
            f"Content-Length: {len(body)}",
            "Connection: close",
            "", "",
        ]
        writer.write("\r\n".join(lines).encode("latin1") + body)
        await writer.drain()

    @staticmethod
    def _unlink(path: str) -> None:
        try:
            os.unlink(path)
        except OSError:
            pass
