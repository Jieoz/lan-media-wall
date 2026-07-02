# LAN Media Wall · 局域网多设备群控播放系统

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
| 拓扑(可选,v1.1) | 三模式 `topology`:`dedicated` 独立 broker / `cohosted` 被控端兼职 broker(零额外机器)/ `p2p` 无 broker 纯直连(遥控端兼协调,适合 ≤8 台小场景) |
| 二维码配对(v1.1;v1.4.2 配置反转) | 无摄像头 TV 盒被控端**展示自己的** `lmw://pair?...` 二维码(首启/设置页),遥控端手机扫码入组,免手输;摄像头扫码栈按 minSdk 19 已整组删除 |
| 派生密钥(v1.3) | `required`/`optional` 下各端不再共享 PSK:broker 持唯一 PSK,各端经配对二维码只拿到自己那把 `device_key = HMAC(PSK, 设备身份)`。攻破一台只暴露该台,伪造不了 broker 或别台。`key_mode` 协商 `derived`(默认)/`global`(兼容老端),部署体验与单 PSK 完全一致,零额外配置 |
| 设备发现 | UDP 广播自动发现 + 手动 IP 直绑 + 上次清单持久化兜底;找不到 broker 自动退化 p2p |
| 音频 | 组内可指定一台/多台出声，其余静音(默认全部出声) |
| 设备墙预览 | 被控端周期回传当前帧缩略图，遥控端缩略图墙 |
| 数字标牌 kiosk(v1.4) | Android Device Owner / Lock Task 真锁定 + 开机自启;隐藏退出后门(左上 7 连击或遥控 ↑↑↓↓ + PIN)供实机调试,与正式 kiosk 隔离 |
| 播放硬解(v1.4) | Windows mpv `--hwdec=auto-safe` 默认硬解(可关/指定);Android ExoPlayer/MediaCodec。缓存 LRU 配额防爆盘 |
| 运维(Phase 2) | OTA 远程更新 / 远程重启 / 断电恢复上次任务 / 定时编排 |

完整通信协议见 [`protocol_spec.md`](./protocol_spec.md)。

### 下载(预编译产物)

每打一个 `v*` tag，CI 会云编译四端并把产物挂到对应 [Release](https://github.com/Jieoz/lan-media-wall/releases/latest)，目标机无需装 Python / Flutter / Android SDK：

| 端 | 产物文件名 | 说明 |
|---|---|---|
| 中枢 Broker(Linux) | `LANMediaWall-<版本>-Broker-Linux` | PyInstaller onefile，独立可执行，无需 Python |
| 中枢 Broker(Windows) | `LANMediaWall-<版本>-Broker-Windows.exe` | 同上，Windows 版 |
| Windows 被控端 | `LANMediaWall-<版本>-Player-Windows-Setup.exe` | Inno Setup 安装包，已内置 mpv 运行时 |
| Android 被控端 | `LANMediaWall-<版本>-Player-Android.apk` | 原生 Kotlin 播放器，装在每块屏上 |
| 遥控端(新手机) | `LANMediaWall-<版本>-Controller-ARM64-v8a.apk` | 手机/平板遥控,近几年的机型选这个 |
| 遥控端(旧手机) | `LANMediaWall-<版本>-Controller-ARMv7.apk` | 老旧 32 位机型 |
| 遥控端(模拟器) | `LANMediaWall-<版本>-Controller-x86_64.apk` | x86 模拟器/极少数 x86 平板 |

> 文件名一眼区分**端(被控/遥控/中枢)+ 平台/架构 + 版本号**;遥控端按手机架构选一个装即可,绝大多数人选「新手机 ARM64」。

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
4. **两种开机自启(默认只开模式1,互斥,绝不同时生效)**:
   - **模式1(默认,推荐)**:`BootReceiver` 监听 `BOOT_COMPLETED`,开机后台拉起 `PlayerService` + 前台全屏播放,与盒子原桌面共存不冲突。`startForegroundService` 按 `Build.VERSION` 分支(<26 走 `startService`),4.4 原生可用。
   - **模式2(兜底,默认关)**:设置页的「设为桌面」开关运行时启用一个默认禁用的 HOME `activity-alias`(`PackageManager.setComponentEnabledSetting`,4.4 可用),把本应用注册为 Launcher/HOME。仅当模式1 在某盒 ROM 失灵时再手动开,之后在系统里选本应用为默认桌面一次。
5. **验证开机自启**:`adb reboot` 后跑 `adb logcat | grep BootReceiver`,看到 `boot self-start on android.intent.action.BOOT_COMPLETED (sdk=…)` 日志即自启成功。

> **仅限内网**:被控端 PSK/device_key 以**明文 SharedPreferences** 存储(4.4 无 EncryptedSharedPreferences),默认 `auth_mode=open` 零配置直连。这在公网会是漏洞——**切勿把被控端暴露到公网**。首启页顶部亦有此中文警告。

### 目录结构

```
.github/workflows/   # windows-build / android-build(被控端APK) / flutter-build(遥控端APK) / broker-build / ci
broker/              # Python broker
windows_player/      # Windows10 被控端 (Python + mpv IPC + 看门狗 + 缓存)
android_apps/        # Android 原生 Kotlin 被控端 (Media3, kiosk)
remote_flutter/      # Flutter 遥控端
docs/                # 文档与效果截图
protocol_spec.md     # 通信协议合同 (所有端共同遵守)
CHANGELOG.md         # 版本变更记录
```

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

Synchronized playback via WS clock-offset handshake (no system NTP dependency) + three-phase handshake (prepare→ready→play_at), targeting ±50–100ms. Unified **group** model toggles sync vs independent; unified **playlist[]** model covers single-file and rotation. NAS pre-distribution (WebDAV/HTTP) with resumable cached downloads + sha256 verification. **Optional auth (v1.1)**: three `auth_mode` levels — `open` (zero-config, no key, default) / `optional` / `required` (PSK + HMAC-SHA256); msg_id dedup + ts window always on. **Topology modes (v1.1)**: `dedicated` / `cohosted` (a player doubles as the broker) / `p2p` (broker-less direct, controller coordinates — best for ≤8 screens). **QR pairing (v1.1)**: the controller renders an `lmw://pair?...` QR so players (esp. Android) join by scanning — no typing. **Per-device derived keys (v1.3)**: under `required`/`optional`, endpoints no longer share the PSK — the broker holds the single PSK and each endpoint receives only its own `device_key = HMAC(PSK, identity)` via the pairing QR. Compromising one screen exposes only that screen; it cannot forge the broker or other devices. `key_mode` negotiates `derived` (default) / `global` (legacy-compatible); deployment stays a single PSK with zero extra config. UDP discovery + manual IP binding, auto-falls back to p2p when no broker is found. Per-group audio master selection. Thumbnail device-wall preview. **Digital-signage kiosk (v1.4)**: Android true kiosk via Device Owner / Lock Task + boot auto-start, with an isolated hidden exit backdoor (top-left 7-tap or D-pad UP UP DOWN DOWN + PIN) for on-device debugging. **Hardware decode (v1.4)**: Windows mpv defaults to `--hwdec=auto-safe`; media cache gains LRU quota eviction. **Android 4.4 signage (v1.4.2)**: the player targets minSdk 19 (ExoPlayer 2.x, OkHttp 3.12, plain LAN-only prefs); the camera scan stack is removed and the camera-less TV box now **displays its own** `lmw://pair?...` QR for the controller to scan (configuration reversal). Boot auto-start branches on `Build.VERSION` (`startService` under API 26); a default-disabled HOME `activity-alias` is toggled at runtime for the kiosk-launcher fallback. (Phase 2: OTA, remote reboot, power-loss resume, scheduling.)

See [`protocol_spec.md`](./protocol_spec.md) for the full wire protocol.

### Downloads (prebuilt)

Each `v*` tag triggers CI to cloud-build all four ends and attach the binaries to the matching [Release](https://github.com/Jieoz/lan-media-wall/releases/latest) — target machines need no Python / Flutter / Android SDK:

| End | Artifact filename | Notes |
|---|---|---|
| Broker hub (Linux) | `LANMediaWall-<ver>-Broker-Linux` | PyInstaller onefile, standalone, no Python required |
| Broker hub (Windows) | `LANMediaWall-<ver>-Broker-Windows.exe` | same, Windows build |
| Windows player | `LANMediaWall-<ver>-Player-Windows-Setup.exe` | Inno Setup installer, mpv runtime bundled |
| Android player | `LANMediaWall-<ver>-Player-Android.apk` | native Kotlin player; install on each screen |
| Controller (modern phone) | `LANMediaWall-<ver>-Controller-ARM64-v8a.apk` | phone/tablet remote; pick this for recent devices |
| Controller (old phone) | `LANMediaWall-<ver>-Controller-ARMv7.apk` | legacy 32-bit devices |
| Controller (emulator) | `LANMediaWall-<ver>-Controller-x86_64.apk` | x86 emulators / rare x86 tablets |

> Each filename states **role (player/controller/broker) + platform/arch + version** at a glance. For the controller, install one matching your phone — most people want the modern ARM64 build.

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
