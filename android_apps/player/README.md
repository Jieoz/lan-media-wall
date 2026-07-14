# LAN Media Wall — Android Player (被控端)

> **v1.15.3 Phase A — 缓存清理内核(仅内核,未接线):**新增 Kotlin 缓存清理内核
> `cache/CacheHash.kt` / `cache/CacheReferenceSnapshot.kt` / `cache/CacheCleanup.kt`
> 及其单元测试,与 Windows 播放端 (`windows_player/cache_*.py`) **协议等价、逐字节
> 同构**(见 [`../../protocol_spec.md`](../../protocol_spec.md) §25–§29):canonical
> 节目单哈希、引用快照/保护并集、dry-run/commit 同一规划器、代次 fail-closed、
> `request_id` 幂等(有界 FIFO 日志,上限 128)、结构化逐项结果。全部走 API 19 兼容的
> 纯 JVM 逻辑,不引入现代文件系统 API。**这不是用户可见/已部署的行为:**入站请求路由、
> `status.cache_summary` 发射、broker/P2P 回传、Flutter UI、以及 `hello.capabilities`
> 能力声明(`cache_cleanup_v1`)都属 Phase B,尚未接线。Kotlin 编译/真机验证仍需按
> exact-SHA GitHub Actions 完成,本仓库不据此声称清理已上线。

> **v1.15.3 诊断刷新：**设置页若先于异步 `PlayerService.onCreate` 打开，服务就绪边沿会触发一次完整诊断重绘，因此播放/缓存/错误/探针不再一直停留于 `service not ready`；平稳状态不会每秒重复 root daemon 探测。

> **v1.15.2 导出完整性：**覆盖已存在的诊断文件时使用截断写入，避免旧文件更长时尾部残留；系统文档提供器若错误地返回成功但没有目标 Uri，设置页会明确显示失败，不再静默无响应。

> **v1.15.1 启动诊断导出：**设置页的“选择路径并导出诊断”调用 Android 系统文档选择器，操作者可选择下载目录、内部存储或已挂载 U 盘；导出仍不依赖播放服务和局域网连接，内容包含启动阶段、设置、播放/缓存/更新状态及持久化 `player.log` 尾部。

> **v1.15.0 推送任务边界：**每次 `playlist mode=replace` 采纳后在 `status.push_id` 回显控制端生成的唯一任务标识，不能再用可复用的 `playlist_id` 误认新任务。下载阶段进度封顶 99%，仅校验并原子落盘成功后进入 `ready`(100%)。空 `replace` 是明确的「清空并停播」：取消 prepare/dwell/定时起播，停止解码器、清活动列表和恢复任务，并显示 idle 画面；缓存文件本身仍保留。

> **v1.14.12 P2P 调度与恢复：**下载器保持单台 2 个 active worker、最多 64 个 pending，但不再使用普通 FIFO：`playlist/cache_prefetch` 进入后台队列，当前 `prepare` 项进入前台并可提升已排队的同 item；同 item 去重。控制端过载返回的 `429/503` 会按有上限的 `Retry-After`/指数退避重试，保留 `.part` 后继续 Range 续传；stop 会取消排队任务和活动 OkHttp call。prepare generation 隔离保证旧 waiter 不能 prime 解码器或发送过期 `ready`。

> **v1.14.11 批量 P2P 传输边界：**单台播放端最多并发下载 2 项，等待队列最多 64 项；超限项目通过 `status.cache[item_id]=error:queue-full` 明确上报，不再用无界线程池放大网络、内存和闪存争用。Range 断点续传、SHA-256 校验和缓存播放合同不变。

> **v1.14.9:** API19 单 VDEC 的视频切换不再直接露出
> MediaPlayer 重建阶段：切换前复用当前项目已缓存的 JPEG 到既有 ImageView，
> 新视频真实首帧或失败回调后撤下覆盖层。该路径不用 PixelCopy、不并行开启
> 第二解码器，单视频循环仍走 `setLooping(true)`。

**双视频内核 A/B(v1.14.2,§backend-ab)**:视频播放现有**两个一等公民内核**,同一份 `VideoBackend` 合同、可在同一台盒子 + 同一素材上 A/B 对比:① `ExoPlayer`(Media3,仅硬解,v1.14.0 路径);② **原生 `android.media.MediaPlayer`**(走盒子 OEM 自己的 Stagefright/OMX 管线——厂商固件真正调优的那条,在这批 HiSilicon 上可能优于 ExoPlayer 通用编解码链)。`PlayerController` 收敛为**门面**:只持一个内核 + 与解码器无关的图片/缩略图路径,故 service/协议层完全与内核无关,`load/play_at/pause/resume/stop/seek/volume/playlist/status/heartbeat` 在两内核上行为一致。内核选择走**设置页单选(自动/ExoPlayer/原生 MediaPlayer)**,`自动`=旧稳定默认(ExoPlayer,经纯逻辑 `BackendSelector` 决策,**无 evidence 不擅自切全网、无 `Build.MODEL` 机型分支**);`/data/local/tmp/lmw_video_backend` 覆盖文件(测试用)优先于设置。当前内核 + 原因(如 `mediaplayer(override)`)写进 `status.video_backend`、设置页与诊断包。A/B 指标**只记两内核都能诚实提供的值**(prepare/首帧延迟、buffering/stall、completion、error、分辨率;dropped-frame 仅 ExoPlayer 有,原生记 `n/a` 而非假 0)。一键真机对比见根 `scripts/qzx_ab_backend.sh` / `.bat`。

**视频硬解 + root 守护进程(v1.14.0)**:视频输出用 `SurfaceView` 让 API 19/HiSilicon 硬解走 HWC/overlay;ExoPlayer 经 `MediaCodecSelector` **只选硬件视频解码器**(排除 `OMX.google.*`/`c2.android.*`/API 报告的 softwareOnly),无硬件解码器时显式失败并记日志,绝不静默软解(音频照常)。导出日志含所选解码器名 + 硬/软分类 + 初始化耗时。控制端缩略图改为一次性缓存帧复用——**视频正在播放时绝不再开第二个解码器抽帧**。远程重启/推送升级改由 root 守护进程 `lmw_root_daemon`(见下),弃用 setuid helper(目标机 `no_new_privs` 下失效)。

Native Android (Kotlin + Media3/ExoPlayer) player for the LAN Media Wall. It is
behaviorally **on par with the Windows player** (`../../windows_player/`) — same
protocol, same roles, different playback kernel (Media3 instead of mpv).

Implements the shared contract in [`../../protocol_spec.md`](../../protocol_spec.md)
**v1.5** (auth/topology/pairing §13–§15, derived keys §17, device config §19,
prefetch barrier §21, remote self-update §23).

> **Current build: `versionName 1.15.3 / versionCode 65`** — derived from
> `remote_flutter/pubspec.yaml`'s `version:` line at Gradle-config time (see
> `app/build.gradle.kts` lines 27–40), so bumping pubspec syncs every end at once;
> **do not hardcode the version in Gradle**.
>
> **v1.14.8** — control-plane + composition fixes. **(1) Ordered playlist
> replace/append**: the `playlist` frame now carries an explicit `mode`
> (`replace` default = swap-and-restart, byte-for-byte legacy; `append` = merge
> onto the current ordered sequence de-duped by `item_id`, keeping the current
> position). This separates the ordered `active_playlist` (sequence + current
> index) from the cache inventory (files on disk), fixing "cache 2/2 ready but
> prev/next both play the last pushed item". The merged sequence persists under
> the retained `playlist_id` so restart restores order + index; `status` reports
> additive `current_index`/`playlist_count`. Pure rules in `PlaylistOps`.
> **(2) Multi-device content clock** (`ContentClock`): late-start compensation —
> when `prepareAsync` pushes the real start past `play_at` beyond the 40ms jitter
> threshold, seek forward by the lateness so this box lands on the same frame as
> on-time peers; authoritative `sync_start target_wall_ms=… actual_wall_ms=…
> late_ms=… compensate_seek_ms=…` log. **(3) Loop/transition** (`TransitionPolicy`):
> single-item loop uses OEM continuous `setLooping(true)` (no teardown seam);
> playlist transitions hold-last-frame only on API≥21 multi-VDEC, else
> immediate-swap on the API≤19 single-VDEC QZX box (a brief documented black gap,
> never a second decoder). **(4) Thumbnail restoration**: v1.14.7 returned
> `SUPPRESS` for any actively-playing video so previews went permanently blank;
> now one-shot-per-item extraction bounded by the permanent cache +
> `alreadyAttempted` (at most one MMR open per item, ever). **(5) Update
> diagnostics**: every `update_app` decision/failure is logged to `player.log`
> and the daemon's real `detail` propagates through `reportUpdate` instead of
> flattening to `install-failed`.
> The **Settings screen shows this version** at the top of the device-info line
> (`版本: v<name> (build <code>)`), read from `BuildConfig` — single source of truth,
> so what you see on-screen always matches the installed build.
> `versionCode` MUST increment on every release — it's how Android decides "this is
> newer". Bumping `versionName` alone can cause the update to be rejected as the same
> version. See the release checklist in the root README.

> **HOME/SETUP 物理键回播放墙(v1.13,HOME 绑定 v1.13.7 根因修复).** QZX_C1 等盒子的物理
> 「回主页」键实测发的是 `KEY_SETUP` = `KEYCODE_SETTINGS`(176),**不是** `KEY_HOME`。
> `MainActivity.onKeyDown` 新增 `KEYCODE_SETTINGS` 分支:消费该键(不让它弹系统设置/漏进
> 播放器)并 `goToWall()` 把播放墙(`MainActivity`,`launchMode=singleTask`)以
> `FLAG_ACTIVITY_REORDER_TO_FRONT | SINGLE_TOP` 重新拉到前台。`KEY_HOME` 由 `MainActivity`
> 自身声明的 `category.HOME` intent-filter 兜底——**双键兜底**,哪种键位的盒子都能回墙。
> **v1.13.7 起 HOME 能力直接挂在真 Activity(`MainActivity`)上,不再用 `activity-alias`**:
> 这批 HiSilicon/YunOS 4.4 固件的 PackageManager 不把 activity-alias 注册进隐式
> `category.HOME` 解析表(`am -c HOME` 恒 `unable to resolve`),迁到真 Activity 后
> 4.4 stock 框架才认它作 HOME 候选。

> **`restart` 命令(v1.14.2).** 遥控端可对单台下发 `restart`,被控端 `PlayerService`
> 命令白名单含 `"restart"` → `hRestart` 分支**只重启播放 App**。经 root 守护进程
> `lmw_root_daemon`(抽象套接字 `@lmw_root_daemon`)向 daemon 发
> `RESTART_APP`;执行前真实 `probe` 必须回 `ready ... daemon_euid=0`(证明对端确为 root)。
> 守护进程用 `SO_PEERCRED` 反向校验本 App 的 UID。**无 `su`/setuid 回退**——目标机
> zygote `no_new_privs` 让二者均失效,那是死路径,只会添乱。若 probe/执行失败,只上报
> 错误,绝不杀掉播放端进程。
>
> **远程日志下载 + 调试快照(v1.13.4).** `PlayerService` 处理控制端发来的
> `download_logs` / `debug_snapshot`:前者读取持久化 `player.log` 的滚动尾段并通过
> `download_logs_result` 回传,后者把版本、播放态、缓存、最近错误、helper 探针等聚合为
> `diagnostic_status`。这两个功能依赖全链路同版:控制端发请求、Android Player 处理请求、
> broker/P2P 协调端转发请求和回包;只升级控制端配旧 Player 会超时。

> **黑屏根因修复 + 诊断可观测(v1.13.11).** 两个长期被吞掉的黑屏根因:
> **B1** — `PlayerService` 过去**从未订阅** `PlayerController.onPlayerError`,ExoPlayer
> 报解码错误(如 `OMX_ErrorStreamCorrupt`)时 `playState` 仍无条件停在 `"playing"`,
> 控制端看到「推送成功、播放正常」的假象。现在 `onPlayerUiReady()` 幂等接线 controller,
> 错误一发生即写 `player.log`、推进 `errors` 队列、翻 `playState="error"`,watchdog 恢复逻辑
> 同步识别 `playState=="error"` 作触发(5s 兜底不变)。
> **B2** — `Downloader.restoreReadyFromDisk`(重启恢复)与 `ensureEntryAndStart` 的
> `quickOk` 捷径(预取命中旧文件)两处同源路径过去**只比 size** 就标 `ready`,截断/损坏但
> 长度恰好相符的文件被当可播 → 坏码流黑屏。现在带 `sha256` 的 item 恢复前必须校验通过才认
> `ready`,不符删文件回退完整下载;无 sha256 时保留 size-only 并记 `UNVERIFIED`。
> **诊断** — `PlayerController`/`Downloader` 各接 `logSink`,把状态转移(`BUFFERING/READY/ENDED`)、
> **首帧渲染**(`onRenderedFirstFrame`,「解码成功但黑屏」的决定信号)、分辨率、错误码+cause、
> load 源描述(本地缓存文件名/大小 vs 远端 URL)、cache 命中来源、SHA 校验结果统一经
> `logEvent` 落到**导出的 player.log**,不再只进被 4.4 盒截断的 logcat。

> **Release signing (v1.11.0, §根因B — 覆盖升级/远程 update_app 的前提).** The
> `release` buildType signs with a **fixed production certificate** decoded by CI
> from GitHub Actions Secrets (`ANDROID_KEYSTORE_BASE64` / `_PASSWORD` / `KEY_ALIAS`
> / `KEY_PASSWORD`) into a `key.properties` that points at a `$RUNNER_TEMP`
> keystore. A constant fingerprint across versions is what makes overwrite-install
> and remote `update_app` (§23) work — the old per-build debug key changed
> fingerprint every release and forced `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
> (uninstall-reinstall). The expected fingerprint is a **public** value resolved by
> `scripts/resolve_release_cert.sh` from the checked-in canonical file
> `android_apps/player/release-cert-sha256.txt` (the repository variable
> `ANDROID_RELEASE_CERT_SHA256` is an optional operator override, not required).
> Release builds **fail closed** if any signing Secret is absent or no valid
> fingerprint resolves; CI also verifies the produced APK against that fingerprint,
> so no debug-signed release can be published silently. **Keystore and plaintext
> credentials never enter the repo** — `key.properties`, `*.keystore`, `*.jks` are
> git-ignored; only `${{ secrets.X }}` + `$RUNNER_TEMP` are used. Fixed cert SHA256:
> `69:EC:70:E5:92:AE:D4:6C:4E:B1:41:2F:E7:66:8F:41:51:46:81:10:1A:CD:0D:D9:DB:B0:98:D1:E2:6D:6D:54`.

## What it does

- **§1–§3 transport + auth** — one long-lived WebSocket to the broker over
  OkHttp, exponential-backoff reconnect (1→2→…→30s cap), every message wrapped
  in a signed envelope. Signing is **byte-for-byte aligned** with the Python
  ends (see below). Inbound messages are verified (HMAC + freshness window +
  5-min replay dedup). PSK is stored in `EncryptedSharedPreferences`.
- **§4 hello / welcome / presence** — persistent `device_id` (`and-` + 10 hex),
  first-boot custom `device_name`, reports `platform=android`/ip/screen/
  capabilities/`group_id`. Honors broker-authoritative `group_id` from
  `welcome`, and gates thumbnails on `controllers_online` /
  `controller_presence`.
- **§5 status** — every 1.5s: state, current item position/duration, volume,
  muted, audio_master, cache map, clock offset.
- **§6 cache + playlist** — background **resumable** downloads (OkHttp HTTP
  `Range`, WebDAV/HTTP GET) into the app's private cache dir, sha256-verified,
  atomic publish; progress reflected in `status.cache`. Playlists persisted.
- **§6.4 thumbnails** — when a controller is online (or `always_collect`),
  asynchronously extracts the current frame from the locally cached video,
  scales it to ≤320px JPEG, and sends `thumb_meta` + a binary frame. Playback uses
  an independent `SurfaceView`; thumbnail extraction never reads back that surface.
- **§8 clock sync** — SNTP-style `time_sync` on connect + every 30s, min-rtt
  offset selection, `play_at` folded to a local target instant.
- **§9 three-phase handshake** — `prepare` → cache-ready + preload/seek →
  `ready` (echoes `prepare_id` + `group_id`, per v1.1) → `play_at`, started at
  the exact local instant (coarse sleep + final-ms spin for ±50–100ms). Plus
  pause/resume/stop/next/prev/set_volume/set_mute/set_audio_master/assign_group.
- **§19 configure_device (v1.4)** — one message sets this device's display name
  / group / volume (targeted by `device_id`, omitted fields untouched), applied
  to the live player and persisted so it survives reboot.
- **§21 prefetch barrier (v1.4)** — under `prepare(prefetch:true)` an uncached
  item does **not** answer `ready:false` immediately; a coroutine defers, awaits
  the download+verify to finish, then sends `ready:true` (falling back to
  `ready:false` after the 120s barrier timeout) so a synced group starts only
  once everyone is cached.
- **§23 remote self-update (v1.5 / v1.10)** — `update_app` lets a box update its
  own APK with no per-device adb. Guardrails gate it (`update/UpdateGuard`):
  (1) broker-mode frames MUST be authenticated (`Envelope.authed == true`), while
  an accepted local P2P controller link can authorize bootstrap updates;
  (2) the target `version_code` MUST be strictly greater than the running
  `BuildConfig.VERSION_CODE`; (3) the APK URL + 64-hex `sha256` are required and
  the downloaded bytes are re-hashed before install; (4) same-signer is enforced
  by Android's package scanner. Install path is the root `/data/app/<pkg>-1.apk`
  + reboot flow used by the deployment script.
  `deploy_player.sh` — `su` copies the APK into `/data/app/<pkg>-1.apk`, `chmod
  644`, `reboot` (the only path that works on the 4.4 boxes, whose faked install
  location breaks `pm install`). Progress/outcome is reported back via
  `update_status`. **Internal LAN only** — keep the box off the public internet.
- **§11 kiosk + watchdog** — fullscreen immersive (system bars hidden, re-
  asserted), screen kept on, BOOT_COMPLETED autostart, optional Lock Task Mode
  (when Device Owner), idle/stop shows pure black overlay (never the desktop),
  resident foreground service + `resume_last` after restart/crash.
- **§7 discovery** — UDP 8772 responder: verifies `discover`, unicasts a signed
  `announce`.

## Cache-lifecycle cleanup core (Phase A, §25–§29 — core only, not wired)

`app/src/main/kotlin/.../player/cache/` holds the proven-safe cache cleanup
core, **behaviorally on par with the Windows player** (`windows_player/cache_*.py`)
and frozen against the same cross-language fixture so the contract can't drift:

- **`CacheHash.kt`** — `CacheHash.canonicalHash(playlist)` over **playback
  semantics only** (§25), excluding `playlist_id`/`push_id` so a controller can
  distinguish "same content / different generation" from a fork. Item order
  matters; missing sha/duration normalize to empty; sha lower-cased. Its
  `CacheHashTest` asserts the identical digest that the Python
  `test_cache_hash.py` pins from `windows_player/tests/fixtures/playlist_canonical.json`.
- **`CacheReferenceSnapshot.kt`** — resolves item id → physical `content_key`
  and computes the **protection union** (§27): playing / active / prepared /
  `last_task`-resume / inflight+`.part` / pin, plus **shared physical content**
  referenced by any still-protected item. Playlist metadata history alone no
  longer hard-pins an unreferenced blob (root-cause fix). `classifyItem` returns
  a distinct `Kind`/reason with a defined precedence.
- **`CacheCleanup.kt`** — one candidate planner for both `dry_run` (mutates
  nothing) and commit; commit re-reads the adopted generation inside the cleanup
  boundary and fails closed (`generation_mismatch` pre-plan, `generation_changed`
  at delete). A committed destructive `request_id` is journaled in a bounded FIFO
  (`JOURNAL_MAX = 128`, a `LinkedHashMap` with `removeEldestEntry`) so a repeat
  replays the terminal result and never deletes twice. Structured per-item
  `Deleted`/`Skipped`/`Failed` results, `freed_bytes` counted once per
  `content_key`, `summary_after` — never an optimistic ACK.

All pure JVM, **API 19-safe** (no modern-only filesystem APIs), so it unit-tests
off-device. **Deliberate Phase B boundary (not done here, not user-visible):**
inbound `cache_cleanup`/`cache_inventory` request routing in `PlayerService`,
`status.cache_summary` emission, the broker/P2P return path, Flutter UI, and
`hello.capabilities` advertisement of `cache_cleanup_v1` are all Phase B. Kotlin
compilation and real-device verification still require exact-SHA GitHub Actions;
this repo does not claim live cleanup is deployed.

## HMAC / canonical JSON alignment (the critical interop point)

The signing string (§3) is

```
{v}|{type}|{msg_id}|{ts}|{from}|{to}|{canonical_json(payload)}
```

where `canonical_json` must equal Python's

```python
json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
```

The broker **re-signs every forwarded message**, so the Android canonical form
must match Python's byte-for-byte for both inbound verification and outbound
signing. We hand-roll it (`net/Json.kt`, `JsonParser.kt`, `CanonicalJson.kt`)
to control: lexicographic key sort, compact separators, `ensure_ascii=False`
(non-ASCII like Chinese device names emitted raw, not `\uXXXX`), C0-control
escaping, and integer formatting. `EnvelopeTest` pins this against reference
vectors generated by the **actual** `windows_player`/`broker` Python code.

## Build

Standard single-module Gradle project (Gradle wrapper, AGP 8.6, Kotlin 1.9):

```bash
./gradlew assembleDebug      # → app/build/outputs/apk/debug/app-debug.apk
./gradlew assembleRelease    # → app/build/outputs/apk/release/app-release-unsigned.apk
./gradlew testDebugUnitTest  # JVM unit tests (envelope/clock/range math, cache/*)
```

> On an arm64 build host the Maven-distributed aapt2 is x86_64 and can't exec, so
> `testDebugUnitTest` needs the SDK's arm64 aapt2. Supply it **environmentally**
> (`~/.gradle/gradle.properties` or `-Pandroid.aapt2FromMavenOverride=<sdk>/build-tools/<ver>/aapt2`) —
> it is intentionally **not** committed to `gradle.properties` because the absolute
> path would break x86_64 CI and developer machines (see the note in that file).

- `minSdk 19` (Android 4.4.2 — §6, fixes `INSTALL_FAILED_OLDER_SDK` on the
  target 1688 外贸盒), `targetSdk 34` (modern-OS runtime behavior), `compileSdk 35`.
- **4.4 install chain** (see §6 / `docs/player-tv-ux-redesign.md`): the low
  `minSdk` alone isn't enough. To actually install on 4.4 the release build also
  needs, and now has:
  - **R8 shrink + DCE**: `isMinifyEnabled = true` with **narrow keeps only** in
    `proguard-rules.pro`. The old blanket `-keep class …exoplayer2.**/okhttp3.**`
    defeated DCE and bloated the primary dex; they're replaced by `-dontwarn`
    (libraries ship their own consumer rules) so R8 prunes unused ExoPlayer/OkHttp
    classes and the merged dex shrinks back toward a single dex.
  - **legacy multidex**: `multiDexEnabled = true` + the pre-21 multidex loader,
    so even if a second dex remains, 4.4's install-time dexopt/LinearAlloc holds.
  - **traditional PNG launcher icons**: `mipmap-{m,h,xh,xxh,xxx}dpi/ic_launcher.png`
    (generated by `scripts/gen_legacy_icons.py`). A raw `<vector>` launcher icon
    can't be rasterized on API 19 — density PNGs outrank `mipmap-anydpi`, so 4.4
    finally shows an icon (fixes "装包图标不显示").
- `local.properties` points at the SDK; CI provides its own.

## First-boot setup

On first launch `SettingsActivity` collects device name, broker host/port (and
WSS toggle), group id, PSK, and the always-collect-thumbnails flag. Saved
settings mark the device configured; subsequent boots go straight to the
fullscreen player and the BootReceiver brings it up automatically.

**Zero-config broker (v1.8).** The broker host defaults to **empty**, not a
hard-coded `192.168.1.10`. Transport selection keys off `Settings.hasBroker`
(`brokerHost.isNotBlank()`), *not* `isConfigured`: a box with a blank broker —
whether never set up or saved through the zero-config path — auto-discovers a
broker on the LAN and, if none answers, becomes the P2P WS server so the
controller can scan its QR and dial in directly. `save()` persists the host
unconditionally (trimmed, including empty) so an operator can *clear* a bad
broker and fall back to auto-discovery. `192.168.1.10` survives only as the
input-field hint. The old default was a trap: a blank field silently kept the
phantom host, `isConfigured` flipped true, and the box dead-dialed a broker
nobody runs (the "连接断开" after scanning).

**Diagnostics & self-check on the settings screen (v1.8).** Grouped at the top
so a single screenshot tells the whole story (redesign §2 "一眼可核对"):

- **Connection phase** — `ConnState` (a process-static breadcrumb the service
  publishes, mirroring `KioskState`) surfaces `STARTING / DISCOVERING /
  CONNECTING_BROKER / CONNECTED_BROKER / P2P_WAITING / P2P_CONNECTED /
  DISCONNECTED (+reason)`. The screen polls it every second; `PlayerService`'s
  status loop reconciles it against the live link so a silent drop/reconnect is
  reflected instead of a stale "已连接".
- **Hardware self-check** — real `MemTotal` (parsed from `/proc/meminfo`) plus
  `/data` free/total (`StatFs`), via `SystemInfo`. Pure display, never blocks
  setup; lets Jay judge cheap-box hardware remotely from a screenshot.
- **Junk/miner warning** — `SystemInfo.scanBloatware()` flags known preinstalled
  PCDN-miner / background-daemon packages (`SystemInfo.KNOWN_BLOATWARE`, an
  extensible constant) and advises manual disable. It never uninstalls or kills
  (4.4 permissions + risk) — visible warning only.

**Reset connection config (v1.8).** A "重置连接配置" button (`Settings.reset
Connection()`) wipes the broker endpoint, port, WSS flag, group, and key
material back to the unconfigured zero-config state, restarts the service to
re-select a transport, and re-shows the pairing QR — self-recovery without adb.
Device identity (device_id/name) and cached media are deliberately kept.

## Kiosk / Device Owner notes

Full lockdown (Lock Task without the "screen pinned" prompt, blocking the
status bar pull-down, surviving as HOME) requires provisioning this app as a
**Device Owner** via ADB on a factory-fresh / unprovisioned device:

```bash
adb shell dpm set-device-owner com.jieoz.lanmediawall.player/.admin.DeviceAdminReceiver
```

> A DeviceAdminReceiver/policy class is **not** bundled (no admin features are
> needed beyond lock-task allowlisting, which the provisioning step grants).
> Without Device Owner the app still runs as a robust kiosk: HOME-category
> launcher, immersive fullscreen re-asserted by the watchdog, back suppressed,
> screen kept on, autostart on boot. See "Residual risks" below.

## Video backend A/B (§backend-ab, v1.14.2)

Two interchangeable video kernels sit behind one `media/VideoBackend` contract:

- **`ExoVideoBackend`** — Media3/ExoPlayer 2.19 with the hardware-only
  `MediaCodecSelector` (the v1.14.0 path). Rich diagnostics (decoder name,
  hardware/software class, init/first-frame timing, dropped frames).
- **`MediaPlayerVideoBackend`** — the platform `android.media.MediaPlayer`, i.e.
  the OEM's own Stagefright/OMX pipeline on 4.4. It runs a defensive state machine
  (`prepareAsync`, latched synced-start, illegal-state guards, `SurfaceHolder`
  (re)bind) and reports every metric BOTH kernels can honestly give.
  `dropped_frames` and the decoder name are `n/a` (the platform exposes neither) —
  never faked.

`PlayerController` is now a thin facade owning exactly one kernel plus the
decoder-independent image (`BitmapFactory`) and thumbnail (`MediaMetadataRetriever`)
paths, so the entire service/protocol layer is kernel-agnostic.

**Selecting a kernel (explicit + observable):**

- **Settings radio** — `视频内核 (A/B)`: `自动` (default → ExoPlayer, the
  legacy-stable path) / `ExoPlayer` / `原生 MediaPlayer`. Persisted; takes effect
  when the kiosk Activity rebuilds the player (the Save flow does this).
- **Pure policy** — `media/BackendSelector.decide(override, configured)` resolves
  the kernel + a greppable source (`override` > `config` > `auto-default`). The
  fleet default (`BackendSelector.AUTO_DEFAULT`) stays ExoPlayer **until real-QZX
  A/B evidence justifies flipping it** — one constant, no device-name branching.
  Unit-tested off-device (`BackendSelectorTest`, `BackendMetricsTest`).
- **Override file** — `/data/local/tmp/lmw_video_backend` (contents `exoplayer` /
  `mediaplayer`) beats the saved choice. A **test affordance** the A/B tool uses to
  flip kernels + restart without settings surgery; delete it to return to config.

The live kernel + why is visible in `status.video_backend` (e.g.
`mediaplayer(override)`), the settings-screen playback line (with the A/B metrics
line), and the `download_logs` / `debug_snapshot` bundle.

**One-action real-device A/B** (`scripts/qzx_ab_backend.sh`, Windows
`scripts/qzx_ab_backend.bat`): for each kernel it writes the override file,
restarts the kiosk (the box replays its last pushed item via `resume_last`), lets
it play, and pulls `player.log` (+ rotated), a logcat tail, and meminfo into one
folder; then removes the override and relaunches so the box returns to its
configured kernel. **Read-only except the single override file + restarting our own
app, both reverted at the end** — it never installs, reboots, or touches media /
config. Compare `first_frame`, `buffering`/`stall`, `dropped_frames`, and `error`
lines between the two kernel folders.

## Residual risks (real-device only)

These can't be exercised in a headless CI/container and need a device:

- Media3 **and** native-MediaPlayer actual decode/render + frame-accurate synced
  start (±50–100ms target) — the A/B tool above exists precisely to measure this
  on the real QZX_C1; host tests only cover the pure selection + metrics logic.
- Native MediaPlayer cannot report a decoder name or dropped-frame count on 4.4
  (reported `n/a`), and offers no hardware-only guarantee the way ExoPlayer's
  selector does — the OEM pipeline picks the codec. This is a deliberate,
  documented semantic difference, not a regression.
- Thumbnail capture from the live surface (returns null with no surface).
- Lock Task Mode behavior depends on Device Owner provisioning.
- OEM background-activity-start / autostart restrictions vary by vendor.
- `EncryptedSharedPreferences` needs a working Keystore (falls back to plain
  prefs if unavailable, logged — acceptable degradation).

## CRITICAL: fix crash-on-exit + real default-HOME on KitKat (1.10.4)

- **上上下下不再崩溃退出软件(真正修好)。** v1.10.3 把退出改成 `openSettings()`,但里面
  的 `stopLockTask()` 是 API 21+ 方法,4.4 盒子上 dalvik 解析即抛 **`NoSuchMethodError`
  ——那是 `Error` 不是 `Exception`**,`catch(Exception)` 拦不住 → openSettings 崩溃、进程被
  `Force finishing` → 表现为"上上下下退出软件"。现加 `SDK_INT >= LOLLIPOP` 版本守卫 +
  `catch(Throwable)` 双保险,并对 `tryLockTask()` 整条 Lock Task 链(start/stop/
  isInLockTaskMode/lockTaskModeState/setLockTaskPackages)在 4.4 上整体早返回跳过。
- **遥控主页键真正回到播放墙。** ~~仅 manifest 启用 `HomeAlias` 不够——4.4 框架保留 preferred-HOME
  关联。provision 脚本新增:禁用 OEM(youku)桌面后,用 `cmd package set-home-activity`(高版本)
  或 `pm clear-preferred-activity`(4.4 回退)把播放端设为默认 HOME。设置页「设为主页」开关随之默认勾选。~~
  **(v1.13.7 已被根因修复取代)** 真机验证证明:这批 4.4 固件根本不把 `activity-alias` 注册进隐式
  `category.HOME` 解析表,任何 `set-home-activity` / preferred 手段都无效。现把 `category.HOME` 直接挂
  到 `MainActivity`(真 Activity),4.4 stock 框架即认它作 HOME;`activity-alias` 与「设为主页」开关一并删除。

## D-pad→Settings, HOME key→wall, kiosk-exit no longer kills the app (1.10.3)

- **UP UP DOWN DOWN 现在打开设置页,而不是退出软件。** 之前 `exitKiosk()` 会 `finish()`
  掉唯一的 kiosk Activity,在 YunOS 盒子上导致进程被回收 → 看起来像"软件直接退出"。
  改为 `openSettings()`:挂起 kiosk 看门狗 + 把设置页压在播放 Activity 之上,不 finish,
  进设置稳定可靠。左上角连点 7 下同样走这条路径。
- **遥控主页键(HOME)现在回到播放墙。** `HomeAlias` 由默认禁用改为 `android:enabled="true"`,
  盒子成为 HOME 候选;配合 provision 脚本已禁用 youku 桌面 → 主页键直达播放墙(唯一候选)。
- 控制端按钮文案去歧义:`①仅下发缓存 (不播)` / `②推送并播放`(见 remote_flutter)。

## Settings shows version + bidirectional connection logging (1.10.2)

- Settings screen now displays `版本: v<name> (build <code>)` (from `BuildConfig`).
- `lmw.P2pServer` now logs the **TX** side too (`TX welcome/hello/…`), not just RX,
  and names the **disconnect cause** (`CLOSE frame` / `clean EOF` / `read error …`).
  This closes the "only see RX, never see TX / why did it drop" blind spot when a
  controller connects, handshakes, then disconnects in a loop without pushing media.

## Inbound-frame observability & p2p clock fix (1.10.1)

### Stale P2P controller lease takeover (1.14.10)

`P2pServer` keeps the single-controller rule, but no longer lets a half-open old
socket own it forever. It uses API19-compatible `SystemClock.elapsedRealtime()`,
a 5s socket read tick/ping, and a 15s inactivity lease. Any received WS frame
renews the lease. A genuinely active second controller still gets close `1013`;
after expiry a new controller atomically replaces and closes the stale socket.
Ownership generations prevent the old receive thread/finally from clearing the
replacement. Controller close logs expose code/reason. Real-device validation
of takeover timing and Wi-Fi jitter tolerance remains pending.

Diagnoses the "shows connected but push does nothing, with no logs" class of
bug (typically after a FORCE reinstall wipes `/data/data` and re-pairing):

- **`P2pServer` now logs the full inbound path** under tag `lmw.P2pServer`:
  WS handshake (with `authMode`/`keyMode`), controller connect/disconnect, every
  received frame (`RX <type> from=… authed=…`), and — critically — **every
  dropped frame with its reason** (`DROP inbound: reason=SHAPE|SIG|STALE|DUP …`).
  Previously a failed `Envelope.verify` was `return`ed silently, which is why the
  box was a black box. Grep the device with:
  `adb shell "logcat -d | grep lmw.P2pServer"`.
- **Freshness is now checked against the controller's master clock**
  (`ClockSync.masterNow()`), not the box's raw wall clock. A box whose clock
  legitimately differs from the controller no longer STALE-drops every frame.
- **Replay cache + first-connect window reset on each (re)connect**, so a fresh
  pairing after a wipe is never rejected as a `DUP`.
- **`onInboundDrop` surfaces persistent drops to the UI**: `ConnState` shows
  `已连接但丢帧: <reason>` instead of a bare "connected", so an operator (or a
  remote screenshot) can self-diagnose auth/clock mismatch on-screen.
- `Envelope.peekTypeFrom` gives callers a verify-free peek at a raw frame's
  `type`/`from`/`sig` length purely for the drop log (Envelope stays
  Android-free; only the caller Logs).
> 当前状态：legacy 更新激活与单解码器循环边界遮罩的机制实现已完成；云编译和 QZX 真机验证待完成。不得据此声称视觉故障已在真机解决。
> Legacy `/data/app` fallback note: the success reply means **staged and reboot
> pending**, not version-verified.  The `.lmw-backup` is deliberately retained
> across reboot.  Package/version verification followed by backup commit/cleanup
> is a separate startup integration and remains a real-device release gate; this
> repository does not claim that cross-lifecycle verification is implemented.
