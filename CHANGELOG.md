# Changelog

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/); versions are git tags that trigger CI cloud-builds and Release artifact attachment.

## [v1.9.0] — 2026-07-05

### Added
- **分组增删改 (group CRUD)**: broker/controller 支持 `update_group`/`delete_group`,遥控端可重命名分组、解散分组回收成员到未分组池;registry 落地 CRUD 并广播拓扑变更。
- **设备远程配置 (`configure_device`)**: 遥控端下发 `configure_device` 直接改被控端运行参数(broker host/端口/分组/WSS/密钥),免 adb 上盒子,配合已有的自诊断与重置连接。
- **本地文件上传到媒体库**: controller 通过 broker 媒体库(HTTP PUT/GET,带 Range 断点续传)推本地文件,盒子从 broker 拉取带缓存续传 + sha256 校验;不再强依赖 NAS。
- **预缓存栅栏 (prefetch barrier)**: `prepare` 新增 prefetch 语义与更长的 barrier 超时,多屏在真正 `play_at` 前先把媒体拉全,减少首帧不同步。
- **横屏 UI 重构**: 遥控端设备墙横屏布局重排,适配横向大屏操作。

### Changed
- **版本对齐 1.9.0**: player `versionName 1.9.0 / versionCode 19`;controller `pubspec 1.9.0+19`,`flutter build apk` 传 `--build-name=1.9.0 --build-number=19`。修复 v1.9.0 tag 内部版本号仍烧成 1.8.0 的漂移。

### Verified
- broker + windows_player 全套 pytest 绿(含新增 `test_group_mgmt`/`test_media_server`/`test_configure_and_barrier`)。
- 四端(broker/flutter/android/windows)云编译走同一 tag SHA,GitHub Actions 全绿方视为发布。
- README 同步门槛 `scripts/check_readme_sync.sh` 通过:模块代码改动均有对应 README 更新。

## [v1.8.0] — 2026-07-04

### Fixed
- **未配置被控端不再死连示例 broker (§2)**: `Settings.brokerHost` 默认从硬编码 `192.168.1.10` 改为**空串**;传输选择改以 `hasBroker`(`brokerHost.isNotBlank()`)为准而非 `isConfigured`——broker 留空的盒子先自动发现、发现不到就进 P2P 服务端等遥控端扫码,修复扫码后一直「连接断开」。`SettingsActivity.save()` 无条件写 host(含空、已 trim),使坏 broker 可被清空回自动发现。`192.168.1.10` 仅保留为输入框占位提示。

### Added
- **连接自诊断 (§8)**: 新增进程内 `ConnState`(仿 `KioskState`),`PlayerService` 发布 `STARTING/DISCOVERING/CONNECTING_BROKER/CONNECTED_BROKER/P2P_WAITING/P2P_CONNECTED/DISCONNECTED(+原因)`;设置页每秒刷新,status loop 对账 live link,断线/重连不再显示过期状态。
- **硬件自检 (§5)**: 设置页显示真实 `MemTotal`(读 `/proc/meminfo`)+ `/data` 可用/总容量(`StatFs`),远程截图即可判断盒子硬件。纯展示。
- **挖矿/垃圾包提示 (§6)**: `SystemInfo.scanBloatware` 检测已知预装包(`com.youku.taitan.tv`/`com.youku.cloud.dog` 等,列表常量可扩展),提示手动禁用;不自动卸载/杀进程。
- **重置连接配置 (§9)**: 设置页新增按钮,`Settings.resetConnection()` 清空 broker/端口/WSS/分组/密钥回到未配置态并重启服务重选传输、重显配对二维码;保留设备身份与缓存,免 adb 自救。
- **批量装机脚本 (§7)**: `scripts/deploy_player.sh` 遍历 root 盒子推 APK 到 `/data/app` → chmod → reboot 采纳 → 校验版本,绕开假容量闪存的 `INSTALL_FAILED_INVALID_INSTALL_LOCATION`,支持多设备循环与 `SKIP_REBOOT`/`BOOT_TIMEOUT` 等环境变量。

### Changed
- **退出 kiosk 取消 PIN (§4)**: 暗键手势(左上 7 连击 / 遥控 ↑↑↓↓)命中后**直接退出**,移除 PIN 弹窗与 `kioskExitPin`/`DEFAULT_KIOSK_EXIT_PIN` 等死代码。手势本身不变。
- **控制端应用名 (§3)**: `flutter-build.yml` 在生成 android/ 后把 `android:label` 注入为**媒体墙遥控**(不动 pubspec name / Dart import,副作用最小)。
- **版本对齐 1.8.0 (§2)**: player `versionName 1.8.0 / versionCode 18`;controller `pubspec 1.8.0+18`,并在 `flutter build apk` 传 `--build-name=1.8.0 --build-number=18` 确保进入最终 APK。

### Verified
- `python3 -m py_compile broker/*.py windows_player/*.py` 通过;`pytest -q broker/tests windows_player/tests` = **221 passed**(broker 84 + windows_player 137)。Dart 端 `remote_flutter/test` 走云 CI。
- Android 源码级引用完整性自检:新增 `R.string`/`R.id`/binding id、`ConnState`/`SystemInfo`/`resetConnection`/`hasBroker`/`deviceIp`/`brokerHintFromWsUrl`/`isConnected` 均已定义;color/style 资源齐全。
- Android/Flutter 编译走 GitHub Actions 云 CI(ARM 容器不跑 gradle/flutter)。

## [v1.7.0] — 2026-07-03

### Added
- **Flutter 遥控端真·摄像头扫码入组 (§15)**: 邀请页新增“扫码添加”，用 `mobile_scanner` 扫被控端展示的 `lmw://pair?...`，与粘贴链接/手填 IP 共用 `addDeviceFromPairUri` 入组路径。
- **设备墙即时可见性 (§14.5)**: 发现/扫码/手填的设备立即以占位卡出现，显示“已发现/连接中/已连接/失败+原因”，WS 回传 `DeviceStatus` 后覆盖占位，不再静默吞连接失败。
- **未配置被控端 broker 发现广播**: Android player 即使未配置但已通过局域网发现 broker，也常驻 8772 announce 并广播实际连上的 broker hint，修复“有 broker 但两台互不发现”。

### Fixed
- **Android 4.4 安装链路补齐**: R8 规则去掉 ExoPlayer/OkHttp 宽 keep，保留窄入口 + dontwarn，恢复 DCE；补传统 PNG launcher mipmap，避免 API 19 矢量图标/图标空白问题。

### Verified
- release_readiness_review: PASS（py_compile 25 files；broker 84 passed；windows_player 137 passed；联跑 221 passed；Kotlin R 引用/required_wired/contract checks pass）。
- Android/Flutter/Windows/Broker 编译验收走 GitHub Actions 云 CI。

## [v1.4.0] — 2026-07-02

### Added
- **Android 扫码配对 UI (§15)**: 设置页新增 Scan pairing QR 按钮，拉起 CameraX 后置摄像头预览 + ZXing 解码，扫到 `lmw://pair?...` 后自动回填 broker host/port/group/WSS/name/密钥字段，真正免手输。
- **Android 数字标牌加固**: Device Owner/Lock Task 真 kiosk 注册、无 Device Owner 时不弹屏幕固定确认；隐藏退出后门(左上 7 连击或遥控 ↑↑↓↓ + PIN)；缓存 LRU 配额/保护当前 playlist；心跳补充 app_version/内存/温度字段。
- **Windows player 硬解参数**: mpv 默认 `--hwdec=auto-safe`，支持显式关闭/指定解码器，配套 pytest 覆盖。

### Changed
- Android `APP_VERSION` 改为读取 Gradle `BuildConfig.VERSION_NAME`，避免协议上报版本与 APK 版本漂移。
- Android PSK 输入遵循 open 语义：空 PSK 表示无密钥/open 模式，不再强制填写。

### Verified
- windows_player pytest: 137 passed。
- windows_player py_compile: pass(使用独立 pycache 前缀；仅保留既有 mpv docstring escape warning)。
- Android 本地仅做引用/资源/manifest/CameraX API 静态核对；APK 编译按项目约束走 GitHub Actions 云端。

## [v1.1.0] — 2026-06-24

### Added (易用性 / 上手门槛大幅降低)
- **可选鉴权 `auth_mode` (§13)**: `open`(默认,零配置、不验签)/ `optional` / `required`。默认不再强制 PSK——开箱即用,安全需求再切档。ts-window + msg_id 防重放在所有模式下保持。
- **拓扑三模式 `topology` (§14)**: `dedicated`(独立 broker，现状)/ `cohosted`(被控端兼职 broker，零额外机器)/ `p2p`(彻底无 broker，遥控端兼协调者 + 时钟主)。自动发现找不到 broker 自动退化到 p2p。
- **二维码配对 `lmw://pair?...` (§15)**: 遥控端生成配对二维码，被控端(尤其 Android)扫码免手输入组；`open` 模式不含 psk。
- **关联 id 澄清 (§16)**: fallback 匹配(group_id+playlist_id / 回显 t1)固化为正式契约，显式 id(prepare_id / req_msg_id)列为可选推荐——全部向后兼容。

### Implementation
- broker: auth-mode 门控、`run_broker()` 可嵌入入口(cohosted)、announce 携带 topology/auth_mode、pairing URI 生成 + 终端 QR。
- windows_player: auth 自适应、cohosted broker host、p2p server 角色翻转、`lmw://` 解析。
- android player: 扫码配对解析、auth 自适应、p2p server + 自动发现。
- remote_flutter: auth 自适应、二维码生成、完整 p2p 协调器(时钟主 / 三段握手 / 组扇出 / 设备墙聚合)。

### Verified
- broker pytest 59 passed + 端到端同步链 smoke 5/5 PASS;windows_player pytest 100 passed;android Gradle BUILD SUCCESSFUL;四端云 CI 全绿。

### Compatibility
- 完全向后兼容 v1.0.x：默认行为等价于 `dedicated` + `required`(若配了 PSK)；新模式均为附加项。

## [v1.0.2] — 2026-06-24

### Fixed
- **broker-build release path**: the broker lane runs with `working-directory: broker`, so PyInstaller emits to `broker/dist/...`, but the upload + release-attach steps still pointed at `dist/...`. The two broker binaries never attached on v1.0.1. Paths corrected to `broker/dist/...`.

### Result
- All four CI lanes green (`ci`, `windows-build`, `android-build`, `flutter-build`, `broker-build`).
- Release v1.0.2 attaches all 7 artifacts: 4 controller/player APKs, the Windows installer, and both `lmw-broker` (Linux ELF) + `lmw-broker.exe`.

## [v1.0.1] — 2026-06-24

### Added
- `flutter-build.yml` — cloud-build the `remote_flutter` controller APK (per-ABI release splits, ~14–19 MB instead of the 141 MB debug).
- `broker-build.yml` — PyInstaller onefile lane for standalone `lmw-broker` binaries.
- Slimmed all artifacts: split-per-ABI release APKs, Windows installer measured under the 60 MB ceiling.

### Fixed
- Robust mpv runtime download in `windows-build` (GitHub mirror primary, SourceForge fallback with a proper UA); avoid self-copy when mpv extracts to the runtime root.

### Known issue (fixed in v1.0.2)
- broker binaries did not attach to the release due to a `dist/` vs `broker/dist/` path mismatch.

## [v1.0.0] — 2026-06-23

### Added
- **Phase 1** — protocol contract (`protocol_spec.md` v1) plus three ends against it:
  - **broker** (Python, asyncio): WS/WSS server, signed-envelope auth (HMAC-SHA256 + ts window + msg_id dedup), device registry + grouping with atomic `state.json`, master clock + SNTP-style `time_sync`, three-phase `prepare→ready→play_at` sync state machine, UDP discovery, thumbnail relay. 27 unit tests + end-to-end smoke.
  - **windows_player** (Python + mpv via JSON IPC): reconnect, resumable Range downloads + sha256, kiosk fullscreen-topmost + taskbar hide, watchdog crash recovery + `resume_last`. 34 unit tests, OS-coupled paths import-guarded for cross-platform CI.
  - **remote_flutter** (Flutter controller): device wall, playlist editor, prefetch, synced play, per-group volume/mute/audio-master, group assignment; byte-for-byte canonical-JSON HMAC alignment with the Python ends.
- **Phase 2** — native **Android Kotlin player** (Media3/ExoPlayer), behaviorally on par with the Windows player; protocol bumped to **v1.1** (backward-compatible additions: `prepare_id` sync-session correlation, `wall.devices[]` field set, `welcome` fields, `controller_presence`, `time_sync_ack.req_msg_id`).
- GitHub Actions cloud-build for the Windows exe and Android APK.

[v1.0.2]: https://github.com/Jieoz/lan-media-wall/releases/tag/v1.0.2
[v1.0.1]: https://github.com/Jieoz/lan-media-wall/releases/tag/v1.0.1
[v1.0.0]: https://github.com/Jieoz/lan-media-wall/releases/tag/v1.0.0

[v1.7.0]: https://github.com/Jieoz/lan-media-wall/releases/tag/v1.7.0
