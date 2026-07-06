"""Broker media library HTTP server (§20.1): upload, dedup, sha256 guard,
Range download. Uses a real loopback socket against the asyncio server."""
import asyncio
import hashlib
import os
import sys
import tempfile

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import media_server as media_mod  # noqa: E402


async def _http(host, port, request: bytes, body: bytes = b""):
    """Send a raw HTTP request, return (status_line, headers dict, body)."""
    reader, writer = await asyncio.open_connection(host, port)
    writer.write(request + body)
    await writer.drain()
    raw = await reader.read(-1)  # server sends Connection: close
    writer.close()
    try:
        await writer.wait_closed()
    except Exception:
        pass
    head, _, payload = raw.partition(b"\r\n\r\n")
    lines = head.decode("latin1").split("\r\n")
    status = lines[0]
    headers = {}
    for ln in lines[1:]:
        if ":" in ln:
            k, v = ln.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return status, headers, payload


@pytest.fixture
def server():
    tmp = tempfile.mkdtemp(prefix="lmw_media_")
    srv = media_mod.MediaServer(tmp, port=0, max_bytes=1024 * 1024)
    yield srv, tmp


async def _run(server, coro):
    srv, _ = server
    # port=0 -> ask the OS for a free port, then rebind the server to it.
    # MediaServer binds in start(); grab the actual port from the socket.
    await srv.start()
    sock = list(srv._server.sockets)[0]
    port = sock.getsockname()[1]
    try:
        return await coro(port)
    finally:
        srv.stop()
        await srv.wait_closed()


def _run_isolated(server, coro):
    """Run an async scenario on a private event loop, then restore a fresh
    current loop. Prevents polluting sibling tests that use the legacy
    asyncio.get_event_loop() (which asyncio.run() would leave closed/unset)."""
    loop = asyncio.new_event_loop()
    try:
        asyncio.set_event_loop(loop)
        return loop.run_until_complete(_run(server, coro))
    finally:
        loop.close()
        # Leave a usable current loop behind for legacy-style sibling tests.
        asyncio.set_event_loop(asyncio.new_event_loop())


def test_upload_then_download_roundtrip(server):
    data = b"hello media wall" * 100
    sha = hashlib.sha256(data).hexdigest()

    async def scenario(port):
        put = (f"PUT /media/{sha}.mp4 HTTP/1.1\r\n"
               f"Host: x\r\nContent-Length: {len(data)}\r\n\r\n").encode()
        status, _, _ = await _http("127.0.0.1", port, put, data)
        assert status.startswith("HTTP/1.1 201")

        get = (f"GET /media/{sha}.mp4 HTTP/1.1\r\nHost: x\r\n\r\n").encode()
        status, headers, body = await _http("127.0.0.1", port, get)
        assert status.startswith("HTTP/1.1 200")
        assert body == data
        assert headers.get("accept-ranges") == "bytes"

    _run_isolated(server, scenario)


def test_sha256_mismatch_rejected(server):
    data = b"real bytes"
    wrong_sha = "0" * 64

    async def scenario(port):
        put = (f"PUT /media/{wrong_sha}.bin HTTP/1.1\r\n"
               f"Content-Length: {len(data)}\r\n\r\n").encode()
        status, _, _ = await _http("127.0.0.1", port, put, data)
        assert status.startswith("HTTP/1.1 400")

    _run_isolated(server, scenario)


def test_upload_token_required_but_download_open():
    data = b"signed apk bytes"
    sha = hashlib.sha256(data).hexdigest()
    tmp = tempfile.mkdtemp(prefix="lmw_media_token_")
    srv = media_mod.MediaServer(tmp, port=0, max_bytes=1024 * 1024,
                                upload_token="upload-secret")

    async def scenario(port):
        put = (f"PUT /media/{sha}.apk HTTP/1.1\r\n"
               f"Host: x\r\nContent-Length: {len(data)}\r\n\r\n").encode()
        status, _, _ = await _http("127.0.0.1", port, put, data)
        assert status.startswith("HTTP/1.1 401")

        authed_put = (f"PUT /media/{sha}.apk HTTP/1.1\r\n"
                      f"Host: x\r\nAuthorization: Bearer upload-secret\r\n"
                      f"Content-Length: {len(data)}\r\n\r\n").encode()
        status, _, _ = await _http("127.0.0.1", port, authed_put, data)
        assert status.startswith("HTTP/1.1 201")

        get = (f"GET /media/{sha}.apk HTTP/1.1\r\nHost: x\r\n\r\n").encode()
        status, _, body = await _http("127.0.0.1", port, get)
        assert status.startswith("HTTP/1.1 200")
        assert body == data

    _run_isolated((srv, tmp), scenario)


def test_idempotent_reupload(server):
    data = b"dedup me"
    sha = hashlib.sha256(data).hexdigest()

    async def scenario(port):
        put = (f"PUT /media/{sha} HTTP/1.1\r\n"
               f"Content-Length: {len(data)}\r\n\r\n").encode()
        status, _, _ = await _http("127.0.0.1", port, put, data)
        assert status.startswith("HTTP/1.1 201")
        # Second upload of identical content -> 200 (exists), not rewritten.
        status2, _, _ = await _http("127.0.0.1", port, put, data)
        assert status2.startswith("HTTP/1.1 200")

    _run_isolated(server, scenario)


def test_range_request_returns_partial(server):
    data = bytes(range(256)) * 8  # 2048 bytes
    sha = hashlib.sha256(data).hexdigest()

    async def scenario(port):
        put = (f"PUT /media/{sha}.bin HTTP/1.1\r\n"
               f"Content-Length: {len(data)}\r\n\r\n").encode()
        await _http("127.0.0.1", port, put, data)

        # Ask for bytes 100-199.
        get = (f"GET /media/{sha}.bin HTTP/1.1\r\n"
               f"Range: bytes=100-199\r\n\r\n").encode()
        status, headers, body = await _http("127.0.0.1", port, get)
        assert status.startswith("HTTP/1.1 206")
        assert headers.get("content-range") == f"bytes 100-199/{len(data)}"
        assert body == data[100:200]
        assert len(body) == 100

    _run_isolated(server, scenario)


def test_oversize_upload_rejected(server):
    # server fixture caps at 1 MB.
    big = 2 * 1024 * 1024
    sha = "a" * 64

    async def scenario(port):
        put = (f"PUT /media/{sha}.bin HTTP/1.1\r\n"
               f"Content-Length: {big}\r\n\r\n").encode()
        # Don't actually send the body; server should 413 on the header.
        status, _, _ = await _http("127.0.0.1", port, put, b"")
        assert status.startswith("HTTP/1.1 413")

    _run_isolated(server, scenario)


def test_bad_media_name_rejected(server):
    async def scenario(port):
        get = b"GET /media/not-a-hash.mp4 HTTP/1.1\r\n\r\n"
        status, _, _ = await _http("127.0.0.1", port, get)
        assert status.startswith("HTTP/1.1 400")

    _run_isolated(server, scenario)


def test_missing_file_404(server):
    sha = hashlib.sha256(b"never uploaded").hexdigest()

    async def scenario(port):
        get = (f"GET /media/{sha}.mp4 HTTP/1.1\r\n\r\n").encode()
        status, _, _ = await _http("127.0.0.1", port, get)
        assert status.startswith("HTTP/1.1 404")

    _run_isolated(server, scenario)
