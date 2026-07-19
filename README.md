# LAN Media Wall · 局域网多设备群控播放系统

> **v1.18.2 (safe remote configuration):** `configure_device` is now restricted
> to display name, group, volume, and mute. Players publish a revisioned,
> redacted configuration snapshot and return per-field results through Broker or
> P2P. Network transport changes use `transport_configure`; PSK replacement uses
> `rotate_device_key`, and neither is exposed in ordinary snapshots or results.
>
> **v1.18.1 (Windows no-Python OTA detector):**
> QZX Update Tools now includes the UTF-8-BOM/CRLF launcher `OTA检测.bat`
> and a standalone Windows x64 `android_ota_diag.exe`. Operators can
> double-click the launcher on a stock Windows machine, select a diagnostic
> bundle, and receive an evidence-honest Chinese report beside that bundle.
> A lone PackageManager `Success` without matching version/stage evidence stays
> inconclusive. Build and promotion both fail closed if the ZIP lacks the PE,
> launcher, source, profiles, or exact launcher byte contract. This release
> changes diagnostic packaging only; protocol, transport, routing, and OTA
> installation contracts are unchanged.
>
> **v1.17.7 (profile-driven Android OTA diagnostics):**
> QZX Update Tools now ships `android_ota/` — a product-agnostic offline
> classifier (`android_ota_diag.py`) plus profiles (`standard-pm`,
> `qzx-yunos-4.4`) and a host simulator that compiles production legacy
> staging with sandbox paths. Vendor fallbacks are profile data, not hard-coded
> product logic. Android CI packages and verifies the ZIP payload.
>
> **v1.17.6 (second legacy OTA / leftover `.lmw-backup`):**
> Root daemon no longer fail-closes forever when a previous legacy stage left
> `/data/app/<pkg>-1.apk.lmw-backup`. Second remote OTA on legacy-path boxes
> (field: `and-b2b90f28f7` 1174→1175 → `legacy_activation_failed`) auto-commits
> the leftover backup, restores orphan backups, then re-stages. **Boxes that
> already took the legacy path need the new `lmw_root_daemon` via QZX Update
> Tools / `lmw_setup`**, not APK-only.
>
> **v1.17.5 (remote rename wall-echo + OTA install honesty):**
> Player `status` now carries `device_name`; `configure_device` renames update
> Discovery and push status immediately so the wall no longer sticks on
> `device_id`. Root daemon treats pm `Success` line as install success on noisy
> 4.4/YunOS exit codes and surfaces real Failure/Error detail instead of a bare
> `pkg:` stage path. **Fail-class OTA boxes need the new `lmw_root_daemon` via
> QZX Update Tools / `lmw_setup`**, not APK-only.
>
> **v1.17.4 (player experience):** Selected cache cleanup no longer StackOverflows
> on Android (`cacheSummary` → outer `buildCacheSummaryMap`). API19 single-
> decoder media swaps use a near-fullscreen freeze JPEG hold frame. Settings binds
> the physical “回主页” key (`KEYCODE_SETTINGS`=176). Its former
> `configure_device` connection/PSK path was replaced by the v1.18.2 safe patch,
> `transport_configure`, and `rotate_device_key` split above.
>
> **v1.17.0 (Phase B cache-cleanup wiring — live end-to-end):**
> Phase A core is now wired for operators. Players handle live `cache_cleanup` /
> `cache_inventory` off the receive loop and emit only terminal results; broker
> routes request/result role-safely and unicasts results; Flutter converges
> broker + P2P into one `CacheOpsReducer` and exposes device **缓存管理**
> (inventory → dry-run → explicit confirm → commit). Deletion remains player-
> authority only (item ids, never paths), generation fail-closed, protected set
> preserved. Playlist-row removal still never deletes cache files.
>
> **v1.16.0 (Phase A cache-lifecycle core — protocol + core only, not wired):**
> `protocol_spec.md` gains an **additive, legacy-safe** cache-lifecycle contract
> (§25–§29): a canonical playback-only playlist hash, an optional
> `status.cache_summary`, and the `cache_cleanup` / `cache_inventory` /
> `structured_health` message shapes with new `hello.capabilities`
> (`cache_cleanup_v1` etc.). Both players ship the **proven-safe cleanup core**
> that backs it — Windows (`windows_player/cache_*.py`) and Android
> (`android_apps/player/.../cache/`) are byte-for-byte equivalent and frozen
> against one shared fixture: canonical hash, protection union (playing/active/
> prepared/resume/inflight/pin/shared-blob), one planner for dry-run and commit,
> generation fail-closed, bounded-FIFO `request_id` idempotency, and structured
> per-item results. The player is the sole authority for physical deletion and
> accepts item ids, never paths. Deleting a physical blob prunes **every** alias
> item id that resolves to that `content_key`, not just the requested candidate,
> so no index row is left pointing at a deleted file; the `deleted` response
> still reports only the requested candidates. **This is not live or
> user-visible:** request
> routing, status emission, the broker/P2P return path, Flutter UI, and
> capability advertisement are Phase B; Android compile/device verification
> remain exact-SHA cloud-CI gates. Playlist/status compatibility is preserved —
> old ends ignore the additive fields.

> **v1.15.3:** The Flutter controller now reads the selected player's exact active playlist, current item and loop mode, shows/reorders/deletes/appends that ordered list, and applies it back to that device while preserving cache files and current-item identity during edits. Legacy players cannot inherit another device's stale draft. Android Player settings diagnostics also refresh once when the asynchronously started service becomes available, eliminating stale `service not ready` text while avoiding repeated root-daemon probes.

> **v1.15.2:** Android Player diagnostic export now truncates an existing document selected for overwrite and visibly reports a malformed document-provider result with no destination Uri.

> **v1.15.1:** Android Player startup diagnostics can be exported through the system document picker to an operator-selected internal/Downloads/USB location. Android Controller cold/process relaunch discards native saved route state before Flutter starts, always entering the ready-to-use wall; configuration opens only through the explicit settings button, while ordinary background/resume preserves a live dialog.

> **v1.15.0:** playlist editing now supports replace/append/remove/reorder/clear and explicit `none/all/one` loop modes across Android, Windows, Broker and P2P. Media-push progress is end-to-end truthful: downloading is capped at 99%, only checksum + atomic finalize + `ready` reaches 100%, every replace has a unique `push_id` task boundary, and aggregation ignores cache files outside that command's expected item set. The Flutter controller also builds for Windows without exposing the Android-only camera scanner.

> **v1.14.9:** controller composition now defaults to adding items to the active ordered playlist; explicit whole-list replacement remains a clearly labelled operation. On QZX API19 single-VDEC devices, MediaPlayer video-to-video switches reuse the existing ImageView and an already cached JPEG as a temporary hold frame, rebuilding only one decoder and removing the overlay on first frame or error. No PixelCopy (unavailable on API19) and no concurrent decoder are used.

The controller orchestration pane can load and edit the active playlist reported by an online device. Ordinary composition adds items by `item_id`; the separately labelled whole-list operation replaces that device's active playlist. Cache inventory and cache files remain separate. Beyond the single-device read-back, **「载入分组当前清单」** (v1.17.1-field-fix) loads a group's active playlist from a representative online member and reports how many members are consistent / divergent / missing an active playlist.

[![ci](https://github.com/Jieoz/lan-media-wall/actions/workflows/ci.yml/badge.svg)](https://github.com/Jieoz/lan-media-wall/actions/workflows/ci.yml)
[![windows-build](https://github.com/Jieoz/lan-media-wall/actions/workflows/windows-build.yml/badge.svg)](https://github.com/Jieoz/lan-media-wall/actions/workflows/windows-build.yml)
[![android-build](https://github.com/Jieoz/lan-media-wall/actions/workflows/android-build.yml/badge.svg)](https://github.com/Jieoz/lan-media-wall/actions/workflows/android-build.yml)
[![flutter-build](https://github.com/Jieoz/lan-media-wall/actions/workflows/flutter-build.yml/badge.svg)](https://github.com/Jieoz/lan-media-wall/actions/workflows/flutter-build.yml)
[![broker-build](https://github.com/Jieoz/lan-media-wall/actions/workflows/broker-build.yml/badge.svg)](https://github.com/Jieoz/lan-media-wall/actions/workflows/broker-build.yml)
[![release](https://img.shields.io/github/v/release/Jieoz/lan-media-wall)](https://github.com/Jieoz/lan-media-wall/releases/latest)
[![license](https://img.shields.io/github/license/Jieoz/lan-media-wall)](./LICENSE)

[English](#english) · [中文](#中文)

---

## 中文

局域网内集中控制 **多台(≈30)** Windows / Android 屏幕，**同步或各自**播放图片与视频(单文件或轮播 playlist)的群控系统。面向数字标牌 / 视频墙 / 展厅场景。

### 架构

```
  遥控端(Flutter)──→ broker(群晖 Docker)──→ 被控端 ×N (Windows10 / Android)
```

- **broker**(Python)：中央协调，设备注册 / 分组 / playlist 下发 / 状态汇总 / 时钟同步基准 / 命令扇出。遥控端只连 broker，不直连 30 台。
- **被控端 player**：Windows10 = Python + mpv 内核;Android = 原生 Kotlin + Media3(ExoPlayer)。无边框全屏置顶，看门狗守护，空闲黑屏防呆。
- **遥控端 controller**：Flutter，设备墙可视化 + 一键下发缓存/播放/同步。

### 核心特性

| 能力 | 说明 |
|---|---|
| 同步播放 | WS 时钟 offset 握手(不依赖系统 NTP)+ 三段握手(prepare→ready→play_at)，目标 ±50–100ms |
| 同步 / 各播各的 | 统一 group 模型:同组同步同一 playlist，不同组各播各的。`sync` 标志切换 |
| 单文件 / 轮播(v1.6) | playlist[] 统一模型，长度 1 = 单文件，>1 = 轮播。图片按 `duration_ms` 到时**自动进位**(缺省 5000ms),视频**播完自动进位**,末项 loop 回绕;Android/Windows 两端行为一致 |
| NAS 预分发 | 媒体存 NAS(WebDAV/HTTP GET)，被控端断点续传缓存 + sha256 校验，本地秒开 |
| 鉴权(可选,v1.1) | 三档 `auth_mode`:`open` 默认零配置免密钥 / `optional` / `required`(PSK + HMAC-SHA256)。msg_id 去重 + ts 时效在所有档位常开;可叠加 WSS |
| 拓扑(可选,v1.1) | 三模式 `topology`:`dedicated` 独立 broker / `cohosted` 被控端兼职 broker(零额外机器)/ `p2p` 无 broker 纯直连(遥控端兼协调,适合 ≤8 台小场景；控制端最多并发 6 条媒体流/64 个 waiter，每台播放端最多并发下载 2 项/64 个 pending；v1.14.12 起当前 `prepare` 项可提升为前台，`429/503` 有界重试并 Range 续传，stop 确定性解除队列) |
| 二维码配对(v1.1;v1.4.2 配置反转;v1.7 遥控端扫码) | 无摄像头 TV 盒/Windows 被控端**展示自己的** `lmw://pair?...` 二维码(首启/设置页),遥控端手机用 `mobile_scanner` 真摄像头扫码入组;同时保留粘贴链接/手填 IP 兜底 |
| 派生密钥(v1.3) | `required`/`optional` 下各端不再共享 PSK:broker 持唯一 PSK,各端经配对二维码只拿到自己那把 `device_key = HMAC(PSK, 设备身份)`。攻破一台只暴露该台,伪造不了 broker 或别台。`key_mode` 协商 `derived`(默认)/`global`(兼容老端),部署体验与单 PSK 完全一致,零额外配置 |
| 设备发现 | UDP 广播自动发现 + 手动 IP 直绑 + 上次清单持久化兜底;找不到 broker 自动退化 p2p |
| 音频 | 组内可指定一台/多台出声，其余静音(默认全部出声) |
| 设备墙预览 | 被控端周期回传当前帧缩略图，遥控端缩略图墙；Android 4.4 播放视频时直接复用 320px 小 Bitmap 并限频，避免 1080p Java Bitmap 与高频 GPU 读回 |
| 数字标牌 kiosk(v1.4) | Android Device Owner / Lock Task 真锁定 + 开机自启;隐藏退出手势(左上 7 连击或遥控 ↑↑↓↓)**暗键即退、无需 PIN**,供实机调试,与正式 kiosk 隔离 |
| 播放硬解(v1.4) | Windows mpv `--hwdec=auto-safe` 默认硬解(可关/指定);Android ExoPlayer/MediaCodec。缓存 LRU 配额防爆盘 |
| 零配置直连(v1.8) | 被控端 broker 地址**留空即默认**:先自动发现 broker,找不到就进 P2P 服务端模式等遥控端扫码直连。不再硬编码示例 IP 逼未配置设备死连(`192.168.1.10` 只作输入框占位提示) |
| 连接自诊断 & 硬件自检(v1.8) | 设置页显示连接阶段(查找中 / 连接 broker / P2P 待连 / 握手失败原因),连不上能自诊断;同页显示真实 `MemTotal` + `/data` 容量,截图即可判断盒子够不够格;检测已知挖矿/垃圾包(如 `com.youku.taitan.tv`)并提示手动禁用 |
| 一键重置连接(v1.8) | 设置页「重置连接配置」清空 broker/密钥/分组,让盒子回到未配置态重走自动发现 / 扫码配对,免 adb 自救 |
| 批量装机(v1.8) | `scripts/deploy_player.sh` 遍历 root 盒子推 APK 到 `/data/app` 重启采纳,绕开假容量闪存的 `INSTALL_FAILED_INVALID_INSTALL_LOCATION`,支持多设备循环 |
| 遥控端应用名(v1.8) | 装到手机上显示正式中文名**媒体墙遥控**(CI 在 `flutter create` 生成 `AndroidManifest.xml` 后注入 `android:label`,不改 pubspec 包名/Dart import) |
| 横屏平板控制台(v1.9) | 遥控端 UI 按横屏平板为主场景重构:≥900dp 双栏并置(**左设备墙 \| 右编排**),窄屏降级底部导航。设备墙卡显示缩略图/相位/缓存态,内置分组增删改与「配置盒子」(改显示名/设组/设音量),编排栏一体化选组→编列表→预缓存进度→同步起播/传输/音量/出声台 |
| 操作员 UX 重构(v1.18.0) | **P2P 优先的连接真相**:设置页新增「自动发现 / P2P（推荐）」vs「连接 Broker（高级）」显式切换并持久化(存过 broker 地址的老用户自动迁到 Broker 模式,否则默认 P2P);P2P 模式隐藏 broker host/port/WSS/上传 token;连接标签由**实际拓扑 + 对端/连接态**派生(`P2P · 已连接 N 台` / `P2P · 正在发现设备` / `Broker · 已连接` / `Broker · 重连中`),绝不因保存成功乐观显示已连;端口严格校验 1–65535,非法输入**绝不静默回落 8770**;保存只提示「设置已保存，正在重新连接」。**统一单台推送**:编排栏「推送到此设备」与设备卡「推送内容」共用同一 `showPushToDeviceDialog`,确认摘要写明目标/条目数/替换或追加/缓存/是否起播,最终二选一「仅下发并缓存 / 缓存完成后播放」。**措辞真相**:本地草稿清空改名「清空本地草稿」(明示未动设备);远程清空改名「停止播放并清空设备列表」并加红色二次确认(写明精确目标、已知在线台数、停播+黑屏、缓存文件保留);ACK 前一律「命令已发送，等待设备确认」,不再谎报 已清空/已暂停/已停止。**Android 播放端设置页重构**:主「播放端设置」卡(设备名/版本/IP/device_id、实时连接态、一键「刷新连接」、大号 P2P 配对二维码、保存并启动)置顶,二维码在诊断之前;高级 broker/WSS/PSK、硬件自检、诊断、root 守护、导出、重置折叠进「高级网络与诊断」(API19 安全的 GONE/VISIBLE 切换,不引入高版本依赖,保 4.4 与遥控焦点);主界面文案默认与 zh-rCN 双份中文,原始 token/英文只留在折叠诊断与导出 |
| 零配置发现修复(v1.9) | 修复遥控端「绑完 socket 就干等、从不主动广播」导致的自动发现失效:启动即广播 discover 并**周期重发**,同时补发**子网定向广播**(如 `192.168.1.255`,绕开部分 AP 丢弃全局广播),被控端开箱即被发现 |
| 本地媒体上传(v1.9) | 遥控端可直接选手机/平板本地图片视频下发:有 broker 走**模式 B**(PUT 到 broker 媒体库,`/media/<sha256>` 断点续传 + sha256 去重校验),无 broker(p2p)走**模式 A**(遥控端起临时 HTTP 服务供各屏拉取)。sha256 流式摘要,不整文件进内存 |
| 预缓存栅栏(v1.9) | 同步起播前的「全员缓存好再一起从头播」栅栏:`prepare(prefetch:true)` 下被控端**不立刻回 ready:false**,而是后台等下载+校验完成再回 `ready:true`(默认 120s 超时降级),避免个别屏没缓存完就黑屏/追帧。Windows + Android 两端一致 |
| 真实推送进度(v1.15) | Android/Windows 下载阶段最多上报 99%，校验成功并原子落盘为 `ready` 后才是 100%。每次非空 replace 携带唯一 `push_id`，即使复用同一个 `playlist_id` 也不会继承旧任务的完成态；控制端只聚合本次任务的预期条目，设备历史缓存库存不参与均值或完成判断。Broker/P2P 在 `WallState` 共用同一状态机。 |
| P2P 栅栏修复(v1.11.1) | 无 broker/P2P 下「②推送并播放」现在也会把 `prefetch:true` / `barrier_timeout_ms` 透传到被控端；控制端诊断日志会显示 `ready:false`、ready 命中数量与 `play_at` 下发结果，避免看起来 ACK 正常但一直不起播 |
| 盒子远程配置(v1.18.2) | `configure_device` 仅允许显示名 / 分组 / 音量 / 静音，带 `base_revision` 并返回逐字段 `config_patch_result`；播放端广告 capabilities 与脱敏 snapshot。连接参数只能走 `transport_configure`，PSK 只能走 `rotate_device_key`，两者均不回显密钥并独立持久化/重连。Windows + Android + Broker/P2P 一致 |
| 远程自更新(v1.10) | `update_app`(§23):遥控端选 APK → broker 模式上传媒体库 / P2P 模式启动控制端临时 HTTP 服务(得 url+sha256)→ 下发给某台/某组/全部;被控端自己拉取校验后交给 **root 守护进程 `lmw_root_daemon`**,经 `pm install -r` 激活后只重启播放 App(不整机 reboot),**免逐台 adb 刷机**。护栏:broker 帧需鉴权,P2P 直连控制链路可授权本地更新;`version_code` 必须严格更新,`sha256` 下载后重算比对,同签名由 Android 平台强制。仅内网使用 |
| 运维(root 守护进程,v1.14.0) | 远程重启 / 推送升级走 **root 守护进程 `lmw_root_daemon`**(以 root 启动并常驻,监听抽象命名空间 AF_UNIX 套接字 `@lmw_root_daemon`)。目标机 zygote 置了 `no_new_privs`,setuid 位被内核忽略,旧的 setuid helper 架构行不通;守护进程用 `SO_PEERCRED` 内核对端凭证校验请求方 UID(取自 root-only 的 uid 文件),只接受唯一 canonical 更新路径,`O_NOFOLLOW`+常规文件+非空校验,原子安装,不执行任何 shell。QZX setup 安装 + 立即启动 + 用守护进程自带 `-probe` 协议探测(必须回 `ready ... daemon_euid=0`)后才写完成标记,失败即终止 |
| Android 4.4 视频硬解与稳定性(v1.14.0) | 播放输出用 `SurfaceView` 让 HiSilicon 硬解走 HWC/overlay;ExoPlayer 经 `MediaCodecSelector` **只选硬件视频解码器**(排除 `OMX.google.*`/`c2.android.*`/API 报告的 softwareOnly),无硬件解码器时显式失败并记日志,绝不静默软解(音频照常)。导出日志含所选解码器名+硬/软分类+初始化耗时+dropped-frame 统计。控制端缩略图只用一次性缓存帧,**视频正在播放时绝不再开第二个解码器抽帧** |
| Android 双视频内核(v1.14.7) | 视频播放两个内核共用同一 `VideoBackend` 合同。QZX_C1 真机同素材 A/B 已确认 ExoPlayer 可见掉帧、实际重建后的原生 MediaPlayer 顺畅，因此 `自动` 默认采用 **MediaPlayer**；仍可显式选择 ExoPlayer。设置保存会清空旧播放任务、释放旧 controller 并按新配置重建，避免“选中 MediaPlayer 但实际仍跑旧 ExoPlayer”。临时诊断覆盖仍具最高优先级；当前内核与来源进入状态和日志。MediaPlayer 无可靠 dropped-frame/decoder-name API，对应指标诚实记 `n/a`。 |
| 有序播放列表 replace/append(v1.14.8) | `playlist` 帧带显式 `mode`:`replace`(默认,整列替换从头播,字节级等价旧行为)/ `append`(按 `item_id` 去重合并到当前有序序列尾部,保留当前播放位置)。修「cache 报 2/2 ready 但 prev/next 都停在最后一条」——有序 `active_playlist`(序列+`current_index`)与 cache inventory(磁盘文件集)是两个独立概念。合并序列按被控端保留的 `playlist_id` 持久化,重启恢复顺序与索引;`status` additive 上报 `current_index`/`playlist_count`(老遥控端忽略未知字段,不带 `mode` 即 `replace`)。编排面板新增「③追加到当前列表」按钮。 |
| 多机内容时钟同步(v1.14.8) | 纯函数 `ContentClock` 统一「给定 `play_at`+基准 seek,此刻内容应处于哪一帧」的算法(含循环回绕、有界漂移判定)。`MediaPlayer.prepareAsync` 可能把真实起播推过 `play_at`;超过抖动阈值(40ms)即按迟到量前向 seek,让本盒与准点起播的盒子落在同一帧,并把 target-vs-actual 起播时刻+补偿量写权威日志(`sync_start …`)。 |
| 循环/切换黑帧策略(v1.14.8) | 纯函数 `TransitionPolicy`:单条循环用 OEM 连续 `setLooping(true)`(解码器内部重启、无 onCompletion 拆建、无接缝);播放列表切换按解码器能力选策略——API≥21 且多 VDEC 才 hold-last-frame,API≤19 单 VDEC 盒(QZX_C1)诚实取 immediate-swap(短暂黑帧 ~300ms 是有据可查的平台限制,绝不用第二解码器冒险搞崩已验证顺畅的播放)。 |
| 控制面拓扑诊断诚实化(v1.14.8) | 修「汇总说 `topology=dedicated,p2p_peers=0` 而日志说 `topology=p2p`」自相矛盾:区分 **operating**(本端实际连接方式)与 **declared**(协调端 welcome 声明)两个拓扑,诊断汇总同时打印二者,冲突变可解释事实。broker 路径收到本应被 broker 聚合的 `status/time_sync/ready` 时显式记「落到 broker 路径被丢弃」而非静默,`online=null` 变可归因。缩略图恢复:v1.14.7 曾对任何在播视频一律 `SUPPRESS` 导致预览永久空白,现改为按 `item_id` 一次性抽帧(永久缓存+`alreadyAttempted` 各限一次开 MMR)。更新诊断:`update_app` 每个决策/失败都落 `player.log`,守护进程真实 `detail` 透传到 `reportUpdate`。配套只读一键诊断脚本 `scripts/qzx_control_plane_diag.sh`。 |
| 遥控键位与设置入口(v1.10.3) | 被控端 **上上下下(或左上角连点7下)= 打开设置页**(不再 `finish()` 杀进程,YunOS 盒不再"看着像退出软件");**遥控主页键 = 回到播放墙**(v1.13.7 起 `MainActivity` 直接声明 `category.HOME` 为 HOME 候选,配合禁用 OEM 桌面即直达;旧 `HomeAlias` 别名已废弃)。控制端播放编排按钮去歧义:`①仅下发缓存 (不播)` / `②推送并播放` |
| P2P 目标隔离与连接层投递结果(v1.13.8) | 组或单机目标匹配为空时**拒绝投递并向 UI 报错**,绝不扩大成全部已连接设备;普通命令返回成功写入活连接的目标数(不冒充设备执行 ACK),同步起播在零目标时不创建空握手。P2P `update_status` 与 Broker wall 的 `update_state/update_detail/update_version_code` 汇入同一升级状态缓存;Windows `ready` 回显 `prepare_id/group_id`,日志与调试快照也有确定回包 |
| P2P 拓扑迁移与无效 Broker 地址(v1.13.9) | `0.0.0.0` / `::` 仅可用于服务端监听,不能作为控制端远端地址。控制端会自动清理历史通配地址设置并在发现设备后进入 P2P;Broker 未连接时命令明确失败,分组和设备配置不再静默丢弃 |
| 黑屏根因修复 + 诊断可观测(v1.13.11) | **B1**:`PlayerService` 过去从未订阅 `PlayerController.onPlayerError`,ExoPlayer 解码错误时 `playState` 仍停在 `"playing"`,黑屏被伪装成「播放正常」。现在错误一发生即写 `player.log`、推进 `errors`、翻 `playState="error"`,watchdog 同步识别为恢复触发。**B2**:重启恢复(`restoreReadyFromDisk`)与预取命中(`quickOk` 捷径)两处同源路径过去**只比 size** 就标 `ready`,截断/损坏文件被当可播 → `OMX_ErrorStreamCorrupt` 黑屏;现在带 `sha256` 的 item 恢复前必须校验通过,不符删文件回退完整下载。**诊断**:`PlayerController`/`Downloader` 各接 `logSink`,把状态转移、**首帧渲染**、分辨率、错误码、load 源描述、cache 命中来源与 SHA 校验结果落到**导出的 player.log**(不再只进被截断的 logcat);控制端 P2P `_sendTo`/`send` 记出站 `msgId`+payload 摘要+扇出 `delivered/targets`,汇入可复制的 `logLines` |
| P2P 缩略图 & 主动重连(v1.12) | 无 broker/P2P 直连下也能看到设备墙缩略图:把 `thumb_meta`+紧跟二进制帧的两帧配对逻辑抽成共享 `ThumbPairing` 状态机,broker 与 p2p 两路复用同一实现(此前 p2p 路径把 `thumb_meta` 丢进 default 分支丢弃)。P2P 断线新增指数退避主动重连(1s→30s)+ 端点去重防双连接,不再干等下一轮 UDP discover |
| P2P 半开接管与关闭可观测(v1.14.10) | Player 用 monotonic 15s inactivity lease + 5s read tick/ping 管理唯一 controller；活跃第二控制端仍以 `1013` 拒绝，半开旧连接过租约后允许 generation-safe 原子接管并关闭旧 socket。Controller 日志/UI 失败原因带 WS close code/reason；仅收到验过的 `welcome`/有效帧后重置 backoff，upgrade→`1013` 连续失败保持 1s→2s→4s 指数退避。真机验收待完成。 |
| 重启自动恢复播放(v1.12) | 被控端(Android player)重启后 `Downloader` 按 last_task playlist 从磁盘按内容寻址文件名重建 ready 索引,`readyPath` 命中本地已缓存文件而非回退到已失效的临时 url,修「重启丢内容黑屏」。纯读、幂等,不额外写盘 |
| 假容量闪存写安全(v1.12,红线) | 扩容/假容量盒子 `df` 报的巨大剩余是假的:配额重构为 `min(configuredMax, 保守绝对上限)`,空间百分比只能**往下收紧绝不放大**;下载前做「真实可写」探针(小文件写+fsync+读回+删,低频);投新内容前主动回收不再被最近 playlist 引用的孤儿媒体(保护当前/`.part`/last_task 引用文件不误删),防写穿真实颗粒变砖 |
| 升级入口可发现性(v1.12) | 遥控端顶部远程更新按钮从纯图标改为带「更新固件」文字标签;单设备详情弹窗新增「推送升级」入口,走同一 `update_app` 流程但目标预锁定该台(协议不变,仅改可达性) |
| 单台设备面板 · 四控(v1.13) | 遥控端单设备详情弹窗新增只针对**这一台**的四类操作:①单台**播放控制**(暂停/恢复/停止,`WallState.pause/resume/stop(deviceId:)`);②**单播推送内容**(上传+下发 playlist/prepare-play 只锁该台);③**状态/版本一览**(`_DeviceStatusView` 展示 `appVersion`/相位/当前播放项/缓存/组/音量);④**restart 按钮**(二次确认)——下发 `restart` **只重启播放 App**,被控端 `PlayerService` 白名单 `hRestart` 分支经 root 守护进程 `lmw_root_daemon`(套接字 `@lmw_root_daemon` 发 `RESTART_APP`);独立高风险 `REBOOT` 命令才会整机重启。无 `su`/setuid 回退,守护进程不可达时只上报错误,不杀播放端进程 |
| HOME/SETUP 键回播放墙(v1.13;HOME 绑定 v1.13.7 根因修复) | QZX_C1 等盒子物理「回主页」键实测发的是 `KEY_SETUP`=`KEYCODE_SETTINGS`(176) 而非 `KEY_HOME`。`MainActivity.onKeyDown` 新增该键分支:消费掉并 `goToWall()`(`FLAG_ACTIVITY_REORDER_TO_FRONT\|SINGLE_TOP`)把播放墙拉回前台;`KEY_HOME` 由 `MainActivity` 自身声明的 `category.HOME` 兜底——**双键兜底**,哪种键位盒子都能回墙。**v1.13.7 根因修复**:真机验证证明这批 HiSilicon/YunOS 4.4 固件的 PackageManager **不把 `activity-alias` 注册进隐式 `category.HOME` 解析表**（`am -c HOME` 恒 `unable to resolve`，即便组件 enabled + 已被系统当 HOME 坐进栈）。把 HOME 能力从 `.HomeAlias` 迁到**真 Activity**（`MainActivity` 的 intent-filter），4.4 stock 框架才认它作 HOME 候选；`activity-alias` 与设置页「设为桌面」开关一并删除 |
| 远程日志下载 + 调试快照(v1.13.5, 协议 §24) | 单设备详情弹窗在保留「推送升级」的同时新增两个只针对**这一台**的按钮:①**下载日志**——下发 `download_logs`,被控端返回的不是单薄 `player.log`,而是排障用**诊断日志包**:版本/设备/组/IP/传输/播放态/cache/errors/helper/root/update 探针、helper usage/uid 文件、player.log 与滚动尾段、可读 logcat 尾部。控制端收到后追加自己的 controller_summary/controller_log,优先写入 Android 公共 `Download/LANMediaWall/logs` 或桌面 `~/Downloads/LANMediaWall/logs`,失败才回退临时目录,并提示真实路径;②**调试快照**——下发 `debug_snapshot`,被控端 `buildDebugSnapshot` 聚合版本/播放态/缓存/最近错误/helper 探针经 `diagnostic_status` 回传,控制端用可选择文本对话框展示并提供「复制全部」。控制端请求侧用按 `deviceId` 归键的 pending completer,回调命中即完成、超时即释放;broker 和 P2P 协调端必须显式转发请求/回包,不再永久挂起 |
| peer 身份归一 · 根治黑屏+双卡(v1.11.0) | 扫码直连的连接以拨号端点 `host:port` 当占位 key,收到 `welcome`/`status` 拿到**真实 device_id** 后把连接**重绑定**到真实 id,使 `connectedIds` 与 `WallAggregator`/`GroupExpander` 同命名空间:组扇出正常命中、握手目标集匹配 `ready` → `play_at` 正常下发(**不再黑屏**),设备墙**同一盒子只剩一张卡**。v1.13.8 起异常空目标明确失败,不再以广播兜底 |
| 稳定 release 签名 · 根治覆盖升级(v1.11.0) | player release 改用 CI 从 Secret 解码的**固定 keystore** 签名(替换每版指纹都变的 debug 签名),覆盖安装不再 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`、远程 `update_app`(§23)可升级。无 secret 优雅降级为 debug 签名;公开仓 keystore/密码绝不入库(只走 `${{ secrets.X }}` + `$RUNNER_TEMP`) |

完整通信协议见 [`protocol_spec.md`](./protocol_spec.md)。

### 下载(预编译产物)

`main` 上每个精确提交只云编译四端一次并运行五条发布门禁。打 `v*` tag 后，`release-promote` 必须找到**同一 commit SHA** 的全部成功 run，下载其不可变 Actions artifacts，核验版本、文件集合与 SHA-256 后晋级到对应 [Release](https://github.com/Jieoz/lan-media-wall/releases/latest)；tag 阶段不再重复编译。缺任一门禁、产物过期、SHA/版本不一致都会硬失败。Release 同时附带 `SHA256SUMS` 和 `RELEASE_PROVENANCE.json`（tag、commit、version/build、五条 workflow run ID），目标机无需装 Python / Flutter / Android SDK：

| 端 | 产物文件名 | 说明 |
|---|---|---|
| 中枢 Broker(Linux) | `LANMediaWall-<版本>-Broker-Linux` | PyInstaller onefile，独立可执行，无需 Python |
| 中枢 Broker(Windows) | `LANMediaWall-<版本>-Broker-Windows.exe` | 同上，Windows 版 |
| Windows 被控端 | `LANMediaWall-<版本>-Player-Windows-Setup.exe` | Inno Setup 安装包，已内置 mpv 运行时 |
| Android 被控端 | `LANMediaWall-<版本>-Player-Android.apk` | 原生 Kotlin 播放器，装在每块屏上 |
| Windows 遥控端 | `LANMediaWall-<版本>-Controller-Windows-x64.zip` | Flutter 桌面控制器完整目录；解压后运行 `lan-media-wall-controller.exe`，不含摄像头扫码入口 |
| 遥控端(新手机) | `LANMediaWall-<版本>-Controller-ARM64-v8a.apk` | 手机/平板遥控,近几年的机型选这个 |
| 遥控端(旧手机) | `LANMediaWall-<版本>-Controller-ARMv7.apk` | 老旧 32 位机型 |
| 遥控端(模拟器) | `LANMediaWall-<版本>-Controller-x86_64.apk` | x86 模拟器/极少数 x86 平板 |
| QZX 装机/升级工具 | `LANMediaWall-<版本>-QZX-Update-Tools.zip` | 4.4 外贸盒一键装机/升级/清理脚本包(`lmw_setup` / `lmw_restore` / `lmw_audit` + root 守护进程),非运行时二进制 |

> 文件名一眼区分**端(被控/遥控/中枢)+ 平台/架构 + 版本号**;遥控端按手机架构选一个装即可,绝大多数人选「新手机 ARM64」。共 **9 个程序/工具资产**,外加 `SHA256SUMS`、`RELEASE_PROVENANCE.json` 两个校验/溯源文件(合计 11 个发布文件)。

### 端到端快速上手

1. **起 broker**(群晖 / 任意 Linux):
   ```bash
   # 下载到的中枢文件名是 LANMediaWall-<版本>-Broker-Linux，赋可执行权后直接跑
   chmod +x LANMediaWall-*-Broker-Linux
   ./LANMediaWall-*-Broker-Linux          # 默认 open 模式零配置;或 docker 跑,见 broker/README.md
   # 需要鉴权时:LMW_PSK=$(python3 -c "import secrets;print(secrets.token_hex(32))") LMW_AUTH_MODE=required ./LANMediaWall-*-Broker-Linux
   ```
   记下 broker 的局域网 IP(如 `192.168.1.10`)和这把 `PSK`,全系统共用。
2. **装被控端**(每块屏):装 Windows 安装包或 Android 被控端 APK。**默认 `open` 模式零配置**——同一局域网自动发现 broker 即可上线,无需手填密钥。需要鉴权时再切 `required` 并填同一把 PSK。
3. **装遥控端**(手机/平板):装对应架构的遥控 APK(多数人选「新手机 ARM64」)。最省事的入组方式是**用遥控端扫描被控端首启页展示的配对二维码**,免手输 IP/PSK;也可手动填 broker IP / 端口 / PSK。
4. **播放**:控制页选分组 → 编辑 playlist(单文件或多文件轮播)→ 预缓存 → 一键同步播放;同组走三段握手同步起播,`sync=false` 则各播各的。

> **安全说明(v1.1 默认开放,v1.3 派生密钥隔离)**:为最快上手,默认 `open` 模式**不验签**——同一局域网内任何人都能控制设备墙,仅适合可信内网。在不完全可信的网络请切到 `auth_mode: required` 启用 PSK + HMAC。**v1.3 起(`key_mode: derived`,默认)**:你仍只在 broker 配**一把 PSK**、各端照旧扫码入组,但二维码里装的是该端专属的 `device_key`(broker 用 PSK 现场派生),**各端不再持有 PSK**——任一被控端(常年裸放展厅)被导出密钥也只暴露它自己,伪造不了 broker 指令或别台设备。需要机密性时在 broker 放证书启用 WSS(8771)。

### Android 被控端首启与开机自启(4.4+ 数字标牌)

Android 被控端锁定 minSdk 19(Android 4.4.2),纯内网 kiosk。装机与自启务必按以下流程,否则「装不上」或「开机不自启」:

1. **装内部存储**:`adb install -r LANMediaWall-<版本>-Player-Android.apk`(adb 默认装内部存储)。**切勿装到 SD 卡**——装 SD 卡收不到开机广播。
2. **首启必须手动打开一次**:安卓 3.1+ 的 stopped-state 规则规定,APK 装后处于 stopped 状态,**从未被手动打开过就收不到 `BOOT_COMPLETED`**。所以流程必须是:装 → **手动打开一次**(完成首启配对)→ 之后开机才会自启。首启页顶部有中文提示。
3. **配置反转(免手输)**:被控端(无摄像头 TV 盒)**不再扫码**,而是在首启页**展示自己的配对二维码**(含本机 LAN IP / device_id / 分组),用**遥控端手机扫这个码**入组。首启页也大字显示本机 IP / device_id / 分组,便于肉眼核对。
   - **零配置直连(v1.8)**:broker 地址**默认留空**。留空时被控端先自动发现 broker,发现不到就自己当 P2P 服务端等遥控端扫码直连——未配置设备开箱即可入组,不再被硬编码的示例 IP(`192.168.1.10`,现仅作输入框占位)逼着死连一个没人跑的 broker。误填了坏 broker 也可在设置页**「重置连接配置」**一键清空回到此状态,免 adb 自救。
   - **连接自诊断 + 硬件自检(v1.8)**:设置页顶部显示实时连接阶段(启动中 / 局域网查找协调者 / 连接 broker / P2P 待遥控端接入 / 已连接 / 断开原因),连不上时能一眼看出卡在哪;同屏显示真实 `MemTotal` 内存与 `/data` 分区可用/总容量(远程截图即可判断盒子硬件够不够格),并检测已知挖矿/后台垃圾包(如 `com.youku.taitan.tv` PCDN 带宽挖矿、`com.youku.cloud.dog` 云狗)提示手动禁用(不自动卸载/杀进程)。
4. **两种开机自启(默认只开模式1,互斥,绝不同时生效)**:
   - **模式1(默认,推荐)**:`BootReceiver` 监听 `BOOT_COMPLETED`,开机后台拉起 `PlayerService` + 前台全屏播放,与盒子原桌面共存不冲突。`startForegroundService` 按 `Build.VERSION` 分支(<26 走 `startService`),4.4 原生可用。
   - **模式2(兜底,默认关)**:设置页的「设为桌面」开关运行时启用一个默认禁用的 HOME `activity-alias`(`PackageManager.setComponentEnabledSetting`,4.4 可用),把本应用注册为 Launcher/HOME。仅当模式1 在某盒 ROM 失灵时再手动开,之后在系统里选本应用为默认桌面一次。
5. **验证开机自启**:`adb reboot` 后跑 `adb logcat | grep BootReceiver`,看到 `boot self-start on android.intent.action.BOOT_COMPLETED (sdk=…)` 日志即自启成功。

> **仅限内网**:被控端 PSK/device_key 以**明文 SharedPreferences** 存储(4.4 无 EncryptedSharedPreferences),默认 `auth_mode=open` 零配置直连。这在公网会是漏洞——**切勿把被控端暴露到公网**。首启页顶部亦有此中文警告。

**批量装机(v1.8,买一批同款盒子时)**:这类 YunOS/AliOS 盒子默认 `adb root`,但假容量闪存会喂错 `recommendAppInstallLocation`,直接 `adb install` 报 `INSTALL_FAILED_INVALID_INSTALL_LOCATION`。用 `scripts/deploy_player.sh` 绕开:它遍历 `adb devices`(或指定序列号列表),把 APK 推到 `/data/app` → `chmod 644` → 重启让开机包扫描采纳 → 校验安装成功并打印每台 PASS/FAIL。用法见脚本头注释:`scripts/deploy_player.sh <player.apk> [serial ...]`。

**单台一键设置 = 安装升级 + 清理(Windows,无需 bash)**:给盒子装/升级并把它变成"只跑媒体墙"的一体机,用 `scripts/lmw_setup.bat "路径\player.apk"`。一条命令依次:推 APK + helper + 脚本 → 装/升级 player(触发一次重启,脚本用 `adb wait-for-device` **自动跨过**)→ arm 推送升级 helper → **禁用媒体墙之外的一切程序** → 把媒体墙设为默认桌面,直到 `SETUP COMPLETE`。
- 装 APK 必须重启让系统收编,而重启会杀掉盒子内正在跑脚本的 shell,所以**盒子端** `lmw_setup.sh` 天然分两相位(装+重启 / arm+清理+设桌面),靠 `/data/local/tmp/lmw_phase` 接力;`lmw_setup.bat` 只是在 PC 端把两相位自动焊起来。
- **清理用动态白名单**:`pm list packages` 里除硬白名单(SystemUI/设置/输入法/蓝牙/Provider/装包器/player 等 OS 地基)外**其余全禁**,未来盒子里的新垃圾也会被自动扫掉,绝不误伤系统件变砖。可选参数:`FORCE`(签名变更清装) `NOCLEAN`(只装不清) `KEEPDEBUG`(留文件管理器) `NOUNINST`(只禁不卸)。
- **root 守护进程 `lmw_root_daemon`**:盒子 `su` 拒绝 App uid、且 zygote `no_new_privs` 让 setuid 位失效,所以推送升级/远程重启改由一个**以 root 启动并常驻**的守护进程完成。它监听抽象套接字 `@lmw_root_daemon`,用 `SO_PEERCRED` 校验 App uid(取自 root-only 的 `/data/local/tmp/lmw_root_daemon.uid`),只接受唯一 canonical APK 路径；升级经 `pm install -r` 激活后派发 `RESTART_APP`，普通 restart 也只重启播放 App，不整机 reboot。独立高风险 `REBOOT` 命令才会整机重启。`lmw_setup.bat` 每次重新推送 + 重装 + 用协议 `-probe` 验证守护进程确实以 root 起来了才写完成标记。App 侧只会 request/probe,永不自行提权。
- 还原:`scripts/lmw_restore.bat` / `lmw_restore.sh`(`pm enable` 把禁用项全部启用回来;已卸载的需重装或刷机)。只读盘点:`scripts/lmw_audit.bat` / `lmw_audit.sh`。详见 `scripts/QZX-KIOSK-TOOLS.md`。

### 发版清单(release checklist)

**当前版本:`v1.18.2`**(单一真相源 `remote_flutter/pubspec.yaml` = `1.18.2+1182`;player `build.gradle.kts` 与 flutter-build 都从它派生 versionName/versionCode,tag 名也据此,四处不再手动同步、不再漂移)。

> **`1.18.2+1182` 发布安全远程配置合同。**普通 `configure_device` 只允许低风险字段并采用 revision/逐字段回执；连接与密钥分别走独立命令，所有状态快照和回执均脱敏。

1. **改一处版本号(单一真相源)**:
   - `remote_flutter/pubspec.yaml` — `version: X.Y.Z+N`(**`+N` 每次 +1**,安卓靠它判新旧)。player `build.gradle.kts` 与 flutter-build 均从这里派生 versionName/versionCode,tag 名也据此,无需再手改其它文件。
   - `CHANGELOG.md` — 顶部加 `## [vX.Y.Z]` 段落
2. **跑 README 同步门槛**:`bash scripts/check_readme_sync.sh`(退出 0 才继续;模块有代码改动却漏改对应 README 会红)。
3. **先验 main 精确 SHA**:提交推到 `main` 后,等 `ci`、Flutter、Android、Windows、Broker 五条 workflow 在**同一 SHA 全绿**并产出完整候选制品;本地"能编译"不算数。
4. **打 tag 只晋级**:`git tag -a vX.Y.Z -m "LAN Media Wall vX.Y.Z" && git push origin vX.Y.Z`。`v*` 只触发 `release-promote`:核对 tag/commit/version 与五条成功 run,下载同 SHA artifacts,生成 checksum/provenance 并挂 Release,不再编译。最后确认 9 个程序/工具资产 + `SHA256SUMS` + `RELEASE_PROVENANCE.json` 齐全且可下载。
5. **上盒子**:`scripts/deploy_player.sh <player.apk>`(4.4 外贸盒的特殊装法,见上)。

### 目录结构

```
.github/workflows/   # windows-build / android-build(被控端APK) / flutter-build(遥控端APK) / broker-build / ci
broker/              # Python broker
windows_player/      # Windows10 被控端 (Python + mpv IPC + 看门狗 + 缓存)
android_apps/        # Android 原生 Kotlin 被控端 (Media3, kiosk)
remote_flutter/      # Flutter 遥控端
docs/                # 文档与效果截图
scripts/             # 运维脚本:批量装机 deploy_player.sh、单台一键设置(装升级+清理)lmw_setup.bat/.sh(+还原 lmw_restore / 盘点 lmw_audit / root 守护进程 lmw_root_daemon.c + 主机测试)、通用 Android OTA 诊断 android_ota_diag.py + profiles/、README 同步门槛 check_readme_sync.sh 等
protocol_spec.md     # 通信协议合同 (所有端共同遵守)
CHANGELOG.md         # 版本变更记录
```

> **发布前硬门槛**:任一模块代码改动都必须同步更新对应 README。提交/发版前跑
> `scripts/check_readme_sync.sh [base_tag]` 校验(代码改了但 README 没改 → 退出码 1
> 挡下),避免文档滞后于代码。

### 开发阶段

- **Phase 1**:协议 + broker + Windows 被控端 + 最小 Flutter 遥控端，先把时钟同步与鉴权真机验通。
- **Phase 2**(当前):Android Kotlin 被控端 + GitHub Actions 云编译(Windows exe / Android APK / broker 二进制)+ OTA 占位。

### 许可

MIT。架构参考 [Syncplay](https://github.com/Syncplay/syncplay)、[Anthias](https://github.com/Screenly/Anthias) 的设计思路(均 GPLv3)，本项目为独立实现，不复制其代码。

---

## English

A LAN group-control system to centrally drive **~30** Windows / Android screens, playing images and videos **in sync or independently** (single file or rotating playlist). Built for digital signage / video walls / showrooms.

### Architecture

```
  Controller (Flutter) ──→ broker (Synology Docker) ──→ Players ×N (Windows10 / Android)
```

- **broker** (Python): central coordinator — device registry, grouping, playlist dispatch, status aggregation, clock-sync reference, command fan-out. Controllers connect only to the broker.
- **player**: Windows10 = Python + mpv core; Android = native Kotlin + Media3 (ExoPlayer). Borderless fullscreen always-on-top, watchdog-guarded, black-screen-when-idle.
- **controller**: Flutter — device-wall UI + one-tap prefetch / play / sync.

### Key features

Synchronized playback via WS clock-offset handshake (no system NTP dependency) + three-phase handshake (prepare→ready→play_at), targeting ±50–100ms. Unified **group** model toggles sync vs independent; unified **playlist[]** model covers single-file and rotation. NAS pre-distribution (WebDAV/HTTP) with resumable cached downloads + sha256 verification. **Optional auth (v1.1)**: three `auth_mode` levels — `open` (zero-config, no key, default) / `optional` / `required` (PSK + HMAC-SHA256); msg_id dedup + ts window always on. **Topology modes (v1.1)**: `dedicated` / `cohosted` (a player doubles as the broker) / `p2p` (broker-less direct, controller coordinates — best for ≤8 screens). **QR pairing (v1.1; reversed in v1.4.2; controller scan in v1.7)**: camera-less TV/Windows players show their own `lmw://pair?...` QR, and the Flutter controller can scan it with the phone camera (`mobile_scanner`); paste/manual-IP fallbacks remain. **Per-device derived keys (v1.3)**: under `required`/`optional`, endpoints no longer share the PSK — the broker holds the single PSK and each endpoint receives only its own `device_key = HMAC(PSK, identity)` via the pairing QR. Compromising one screen exposes only that screen; it cannot forge the broker or other devices. `key_mode` negotiates `derived` (default) / `global` (legacy-compatible); deployment stays a single PSK with zero extra config. UDP discovery + manual IP binding, auto-falls back to p2p when no broker is found. Per-group audio master selection. Thumbnail device-wall preview. **Digital-signage kiosk (v1.4)**: Android true kiosk via Device Owner / Lock Task + boot auto-start, with an isolated hidden exit gesture (top-left 7-tap or D-pad UP UP DOWN DOWN) for on-device debugging — **the gesture exits directly, no PIN** (v1.8; removed per operator request). **Hardware decode (v1.4)**: Windows mpv defaults to `--hwdec=auto-safe`; media cache gains LRU quota eviction. **Android 4.4 signage (v1.4.2)**: the player targets minSdk 19 (ExoPlayer 2.x, OkHttp 3.12, plain LAN-only prefs); the camera-less TV box now **displays its own** `lmw://pair?...` QR for the controller to scan (configuration reversal). Boot auto-start branches on `Build.VERSION` (`startService` under API 26); a default-disabled HOME `activity-alias` is toggled at runtime for the kiosk-launcher fallback. **Controller onboarding (v1.7)** adds true camera scanning, paste/manual entry, and immediate device-wall placeholder cards with connecting/connected/failed state. **Zero-config & self-diagnostics (v1.8)**: the player's broker host now **defaults to empty** — a fresh box auto-discovers a broker and, finding none, becomes the p2p server for the controller to scan (no more phantom `192.168.1.10` dead-dial; the IP survives only as an input hint). The settings screen surfaces a live connection phase (discovering / connecting-broker / p2p-waiting / disconnected+reason), a real hardware self-check (`MemTotal` from `/proc/meminfo` + `/data` capacity via `StatFs`), and a warning for known PCDN-miner/junk packages; a **Reset connection config** button clears broker/keys/group back to zero-config without adb. A `scripts/deploy_player.sh` helper batch-pushes the APK into `/data/app` on rooted 4.4 boxes (reboot-adopt) to sidestep `INSTALL_FAILED_INVALID_INSTALL_LOCATION`. The controller installs under the Chinese label **媒体墙遥控**. (Phase 2: OTA, remote reboot, power-loss resume, scheduling.)

See [`protocol_spec.md`](./protocol_spec.md) for the full wire protocol.

### Downloads (prebuilt)

Every exact commit on `main` is built once across all four targets and must pass all five release gates. A `v*` tag runs only `release-promote`: it verifies that the tag, commit SHA, pubspec version, successful main runs, artifact set, and SHA-256 checksums all match, then promotes those immutable artifacts to the corresponding [Release](https://github.com/Jieoz/lan-media-wall/releases/latest) without rebuilding. Each Release also includes `SHA256SUMS` and `RELEASE_PROVENANCE.json`; target machines need no Python / Flutter / Android SDK:

| End | Artifact filename | Notes |
|---|---|---|
| Broker hub (Linux) | `LANMediaWall-<ver>-Broker-Linux` | PyInstaller onefile, standalone, no Python required |
| Broker hub (Windows) | `LANMediaWall-<ver>-Broker-Windows.exe` | same, Windows build |
| Windows player | `LANMediaWall-<ver>-Player-Windows-Setup.exe` | Inno Setup installer, mpv runtime bundled |
| Android player | `LANMediaWall-<ver>-Player-Android.apk` | native Kotlin player; install on each screen |
| Windows controller | `LANMediaWall-<ver>-Controller-Windows-x64.zip` | complete Flutter desktop controller bundle; unzip and run `lan-media-wall-controller.exe`; camera scanning is omitted |
| Controller (modern phone) | `LANMediaWall-<ver>-Controller-ARM64-v8a.apk` | phone/tablet remote; pick this for recent devices |
| Controller (old phone) | `LANMediaWall-<ver>-Controller-ARMv7.apk` | legacy 32-bit devices |
| Controller (emulator) | `LANMediaWall-<ver>-Controller-x86_64.apk` | x86 emulators / rare x86 tablets |
| QZX provisioning / update tools | `LANMediaWall-<ver>-QZX-Update-Tools.zip` | one-tap install/upgrade/cleanup script bundle for the 4.4 export boxes (`lmw_setup` / `lmw_restore` / `lmw_audit` + root daemon); not a runtime binary |

> Each filename states **role (player/controller/broker) + platform/arch + version** at a glance. For the controller, install one matching your phone — most people want the modern ARM64 build. That is **9 program/tool assets** in total, plus `SHA256SUMS` and `RELEASE_PROVENANCE.json` (11 release files).

### End-to-end quickstart

1. **Run the broker** (Synology / any Linux):
   ```bash
   # the downloaded hub is named LANMediaWall-<ver>-Broker-Linux; mark it executable and run
   chmod +x LANMediaWall-*-Broker-Linux
   ./LANMediaWall-*-Broker-Linux          # default open mode, zero-config; or via Docker, see broker/README.md
   # with auth: LMW_PSK=$(python3 -c "import secrets;print(secrets.token_hex(32))") LMW_AUTH_MODE=required ./LANMediaWall-*-Broker-Linux
   ```
   Note the broker LAN IP (e.g. `192.168.1.10`) and this `PSK` — shared system-wide.
2. **Install players** (each screen): run the Windows installer or the Android player APK. **Default `open` mode is zero-config** — players auto-discover the broker on the same LAN and come online with no key to type. Switch to `required` and set a shared PSK when you need auth.
3. **Install the controller** (phone/tablet): install the arch-matching controller APK (most people want the modern ARM64 build). Easiest onboarding: **scan the pairing QR the player shows on its first-boot screen** — no IP/PSK typing; or enter broker IP / port / PSK manually.
4. **Play**: on the control page pick a group → edit a playlist (single file or multi-file rotation) → prefetch → one-tap synced play. Synced groups go through the three-phase handshake; `sync=false` plays each screen independently.

> **Security note (v1.1 default is open)**: for fastest setup the default `open` mode does **no signature check** — anyone on the same LAN can control the wall. Use it only on trusted networks. On any less-trusted network switch to `auth_mode: required` for PSK + HMAC (the PSK then is the trust boundary), and enable WSS (8771) with certs for confidentiality.

### License

MIT. Design informed by [Syncplay](https://github.com/Syncplay/syncplay) and [Anthias](https://github.com/Screenly/Anthias) (both GPLv3); this is an independent implementation that does not copy their code.
> 当前状态：legacy 更新激活与单解码器循环边界遮罩的机制实现已完成；云编译和 QZX 真机验证待完成。不得据此声称视觉故障已在真机解决。
