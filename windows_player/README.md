# LAN Media Wall — Windows 10 Player

> **v1.15.0:** playlist `replace` 回显控制端生成的唯一 `push_id`，使同一 `playlist_id` 重推也有明确任务边界；下载阶段 `status.cache` 最多 99%，仅在 SHA-256/尺寸校验和原子落盘完成后上报 `ready`(100%)。空 `replace` 清空活动列表、停止播放器并回到黑屏占位。

Python + **mpv** player (被控端) for the LAN Media Wall. Connects to the broker
over WebSocket, executes synchronized playback, and reports status. Implements
the player side of [`../protocol_spec.md`](../protocol_spec.md) v1.

## What it does (protocol coverage)

| Spec | Feature | Module |
|---|---|---|
| §1 | WS connect, exp-backoff reconnect (1→30s), re-hello + re-sync on reconnect | `websocket_client.py` |
| §2/§3 | Signed envelopes, HMAC-SHA256 verify, ts-window + msg_id dedup | `envelope.py` |
| §4 | `hello` with persistent `device_id`, first-boot `device_name`, ip/screen/caps/group | `main.py`, `config.py` |
| §5 | `status` every 1–2s (state/current/pos/dur/vol/mute/audio_master/cache/offset/`push_id`) | `main.py` |
| §6.2 | `cache_prefetch` → resumable HTTP-Range download + sha256 verify | `downloader.py` |
| §6.3 | `playlist` store + eager prefetch | `main.py` |
| §6.4 | ~5s frame screenshot → ≤320px JPEG → `thumb_meta` + binary frame | `thumbnailer.py` |
| §7 | UDP 8772 discovery responder (`discover`→`announce`, signed) | `discovery.py` |
| §8 | SNTP-style `time_sync` on connect + every 30s, min-rtt offset | `clock.py`, `websocket_client.py` |
| §9.1–9.2 | three-way handshake: `prepare`→`ready` echoing `prepare_id/group_id`, `play_at` folded to local clock | `main.py` |
| §9.3 | pause/resume/stop/next/prev/set_volume/set_mute/set_audio_master/assign_group | `main.py`, `mpv_controller.py` |
| §10 | `ack`, `resume_last` (local last-task persistence) | `main.py`, `config.py` |
| §11 | mpv borderless-fullscreen-ontop, black/placeholder when idle, taskbar hidden | `mpv_controller.py`, `kiosk_win.py` |
| §11 | watchdog: restart mpv within 5s on crash/hang + resume_last | `watchdog.py` |
| §19 (v1.4) | `configure_device` → set display name / group / volume for this device, persisted | `main.py`, `config.py` |
| §21 (v1.4) | prefetch-barrier `prepare(prefetch:true)`: don't answer `ready:false` when uncached — defer, await cache complete, then `ready:true` (120s timeout → `ready:false`) | `main.py` |
| §24 (v1.13.8) | targeted `debug_snapshot` / `download_logs` with bounded `diagnostic_status` / `download_logs_result` replies | `main.py` |

The Windows player reads its app version from the same
`remote_flutter/pubspec.yaml` source as Android and Flutter. The Windows cloud
bundle includes that file, so `hello` and diagnostic replies report the release
version instead of a stale hard-coded value.

## Architecture

```
main.py ── orchestrator (asyncio)
 ├─ websocket_client.py   WS + envelopes + time_sync           (asyncio)
 ├─ clock.py              offset (min-rtt), play_at folding     (pure)
 ├─ downloader.py         resumable Range + sha256 + cache map  (threads)
 ├─ mpv_controller.py     JSON IPC over named pipe / unix sock  (threads)
 ├─ watchdog.py           owns mpv.exe; crash/hang restart      (thread)
 ├─ thumbnailer.py        screenshot → JPEG                     (Pillow)
 ├─ kiosk_win.py          taskbar hide / window topmost         (win32)
 ├─ discovery.py          UDP announce responder                (thread)
 └─ config.py             config.yaml + persistent state.json
```

Blocking mpv IPC runs in a thread executor (`asyncio.to_thread`) so the event
loop never stalls. The watchdog owns the mpv **process**; `mpv_controller`
only speaks the wire protocol to it.

## Install

```powershell
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

### mpv.exe must ship with the app
Download a recent mpv build (https://mpv.io / shinchiro builds) and place
`mpv.exe` next to the app, or set `mpv.path` in `config.yaml` to its full path.
The player drives mpv via its **JSON IPC** named pipe — `python-mpv` is listed
as optional and is not required for IPC control.

## Configure

```powershell
copy config.example.yaml config.yaml
# edit broker.host, group_id, device.name
# set the shared secret out-of-band (recommended):
$env:LMW_PSK = "the-32+byte-shared-key"
```

`LMW_PSK` (env) overrides `psk` in the file so the secret stays out of config.

## Run

```powershell
python main.py --config config.yaml
# or:  python main.py -c config.yaml --log-level DEBUG
```

On first run a `device_id` is generated and persisted to
`<state_dir>/state.json` together with `device_name`, current `group_id`, and
the `last_task` used for crash/reboot recovery.

## Packaging (kiosk deployment)

- Bundle with PyInstaller (`pyinstaller --onefile main.py`) and copy `mpv.exe`
  + `config.yaml` alongside the produced exe.
- Auto-start: add the exe to the per-user Startup folder or a Scheduled Task
  set to run at logon (highest privileges, restart on failure).
- For true kiosk: a dedicated local user with shell replacement is ideal; at
  minimum this app hides the taskbar and keeps mpv fullscreen-topmost so the
  desktop is never exposed (§11).

## Tests

```powershell
pytest tests/ -q
```

Covers the pure logic that must be exactly right: HMAC sign/verify +
replay/staleness/dedup, clock offset (min-rtt) + `play_at` folding, download
Range math + sha256 + cache-state rendering, thumbnail scaling, and state
persistence. `test_configure_and_barrier.py` covers the v1.4 `configure_device`
targeting/persistence and the §21 prefetch barrier (defer → ready-on-cache →
timeout). mpv/win32 paths are import-guarded so the suite runs on any OS.

## Platform notes

- mpv full-screen control, the Windows named pipe, and `pywin32` taskbar
  hiding only execute on Windows. On other platforms those paths are guarded
  (`sys.platform == "win32"` / soft imports) and degrade to no-ops, so the app
  imports and the test suite runs anywhere for CI/static checking.
- The POSIX unix-socket mpv IPC path lets you smoke-test playback on Linux/Mac
  with a locally-installed mpv if desired.
