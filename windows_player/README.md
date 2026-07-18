# LAN Media Wall — Windows 10 Player

> **v1.17.6 — 版本对齐:**与全端 `1.17.6+1176` 同步(本端无 OTA daemon 变更;
> Android 二次 legacy OTA 见 player/daemon 说明)。
>
> **v1.17.5 — 远程改名回显:**`status` 上报 `device_name`;`configure_device`
> 改名后 `DiscoveryResponder.update_name` + 立即 `_send_status`,控制端墙面
> 不再卡在 `device_id`。回归见 `tests/test_configure_and_barrier.py`。
>
> **v1.17.4 — §19 远程 broker 配置:**`configure_device` 现接受 `broker_host` /
> `broker_port` / `use_wss` / `psk`;写入 `PersistentState` 后 `apply_state_transport`
> 叠加到运行时 cfg,再 `_rebuild_transport`(只换 WS,不叠 status 循环)。空 host
> 清空覆盖并 `topology.auto=True` 回发现/P2P;PSK 需签名帧。测试见
> `tests/test_configure_and_barrier.py`。
>
> **v1.17.0 Phase B — 缓存清理已接线:**入站 `cache_cleanup` / `cache_inventory`
> 已接到 live adapter,发射 `status.cache_summary`,并在 `hello.capabilities`
> 广告能力位。删除仍只在播放端发生(item id,代次 fail-closed,受保护不删)。
> Phase A 纯内核与跨语言夹具保持不变。
>
> **v1.16.0 Phase A — 缓存清理内核(仅内核,未接线):**新增经证明安全的缓存清理
> 内核 `cache_hash.py` / `cache_refs.py` / `cache_cleanup.py`,与 Android
> (`android_apps/player/.../cache/`) **协议等价、逐字节同构**(见
> [`../protocol_spec.md`](../protocol_spec.md) §25–§29)。当前仅落地纯逻辑核心与测试:
> canonical 节目单哈希、引用快照/保护并集、dry-run/commit 同一规划器、代次
> fail-closed、`request_id` 幂等(有界 FIFO 日志,上限 128)、结构化逐项结果。
> 物理 blob 删除后按 `content_key` 修剪**其全部别名 item id**(不止被请求的候选),
> 索引不再残留指向已删文件的行;`deleted` 仍只如实回报被请求的候选 id,dry-run 与
> 删除失败不修剪任何条目,重复的候选 id 只删除/修剪/回报一次。
> **这不是用户可见/已部署的行为:**请求路由、`status` 摘要发射、broker/P2P 回传、
> Flutter UI、以及 `hello.capabilities` 能力声明都属 Phase B,尚未接线。不得据此
> 声称清理已上线。

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
| §19 (v1.4 / v1.17.4) | `configure_device` → name/group/volume **and** remote broker transport (`broker_host`/`port`/`use_wss`/`psk`), persisted + transport rebuild | `main.py`, `config.py` |
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

## Cache-lifecycle cleanup (Phase A core + Phase B live wiring, §25–§29)

Three pure modules implement the proven-safe cache cleanup contract. They are
**byte-for-byte equivalent** to the Kotlin core in `android_apps/player`; both
sides are frozen against the same fixture so the contract can't drift silently.
Phase B connects them to the live request path; safety semantics are unchanged.

- **`cache_hash.py`** — `canonical_playlist_hash(playlist)` =
  `sha256(canonical_playlist_string(...))` over **playback semantics only**
  (§25). Excludes `playlist_id` and `push_id` so a controller can tell
  "same content / different generation" from a genuine fork. Item order is part
  of the hash; missing sha/duration normalize to empty, sha is lower-cased.
  The frozen cross-language value lives in
  `tests/fixtures/playlist_canonical.json` and both language test suites assert
  the same digest — changing the rule is a protocol change requiring both
  fixtures to move together.
- **`cache_refs.py`** — `CacheReferenceSnapshot` resolves each item id to a
  physical `content_key` and computes the **protection union** (§27): playing /
  active / prepared / `last_task`-resume / inflight+`.part` / explicit pin, and
  **shared physical content** referenced by any still-protected item. Playlist
  *metadata* history alone no longer hard-pins an otherwise unreferenced blob
  (the root-cause fix — metadata retention is decoupled from media references).
  Skip reasons are distinct wire-facing constants with a defined precedence
  (`PLAYING > ACTIVE > …`).
- **`cache_cleanup.py`** — `CacheCleanup` runs one **candidate planner** for
  both `dry_run` (reports candidates, mutates nothing) and commit. `commit`
  re-reads the adopted generation *inside* the cleanup boundary: an
  `expected_push_id` mismatch fails closed before planning
  (`generation_mismatch`); a generation that moves between plan and delete
  aborts deleting nothing stale (`generation_changed`). A committed destructive
  `request_id` is journaled in a **bounded FIFO (max 128)** so a repeated
  terminal request replays the original result (`idempotent_replay:true`) and
  never deletes twice. Results are structured per-item
  (`deleted` / `skipped` / `failed` with distinct reasons, `freed_bytes` counted
  once per physical `content_key`, `summary_after`) — never an optimistic ACK.
  **Locking:** the SHARED generation lock (also held by playlist handlers) is
  taken only for the fast generation re-check + the delete hand-off, **never**
  for the O(N) scan/plan — a private transaction lock serializes cleanups and
  guards the journal, so a running cleanup never stalls the receive loop or
  playback transitions for the whole scan (design req. 10). The pre-delete
  re-check under the generation lock keeps deletes fail-closed regardless.
- **Idle device (Phase B limitation, by design):** an idle player has **no
  adopted generation** (`current_push_id()` is `None`). A destructive commit
  requires a **non-empty** `expected_push_id`; a non-empty token can never equal
  the idle `None`, so it fails closed with `generation_mismatch` and deletes
  nothing. This is deliberate: Phase B has no generation-token mechanism for an
  idle device, so **destructive cleanup on an idle device is not possible** — no
  sentinel is invented and the non-empty-generation safety contract is not
  weakened. A `dry_run` (non-destructive) still works on an idle device.

**Phase B (live):** inbound request routing, `status.cache_summary` emission,
terminal result frames, and capability advertisement are wired. Safety contracts
(item-id only, generation fail-closed, protected union, idempotent journal)
remain identical to Phase A.

## Tests

```powershell
pytest tests/ -q
```

Covers the pure logic that must be exactly right: HMAC sign/verify +
replay/staleness/dedup, clock offset (min-rtt) + `play_at` folding, download
Range math + sha256 + cache-state rendering, thumbnail scaling, and state
persistence. `test_configure_and_barrier.py` covers the v1.4 `configure_device`
targeting/persistence and the §21 prefetch barrier (defer → ready-on-cache →
timeout). `test_cache_hash.py` / `test_cache_refs.py` / `test_cache_cleanup.py`
cover the Phase A cleanup core above: the frozen canonical hash, the protection
union (including shared-blob and metadata-only cases), dry-run vs commit,
generation fail-closed, and `request_id` idempotency. mpv/win32 paths are
import-guarded so the suite runs on any OS.

## Platform notes

- mpv full-screen control, the Windows named pipe, and `pywin32` taskbar
  hiding only execute on Windows. On other platforms those paths are guarded
  (`sys.platform == "win32"` / soft imports) and degrade to no-ops, so the app
  imports and the test suite runs anywhere for CI/static checking.
- The POSIX unix-socket mpv IPC path lets you smoke-test playback on Linux/Mac
  with a locally-installed mpv if desired.
