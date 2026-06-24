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
| 单文件 / 轮播 | playlist[] 统一模型，长度 1 = 单文件，>1 = 轮播;图片带 duration |
| NAS 预分发 | 媒体存 NAS(WebDAV/HTTP GET)，被控端断点续传缓存 + sha256 校验，本地秒开 |
| 鉴权防重放 | 全员预置 PSK + HMAC-SHA256 签名 + msg_id 去重 + ts 时效;可叠加 WSS |
| 设备发现 | UDP 广播自动发现 + 手动 IP 直绑 + 上次清单持久化兜底 |
| 音频 | 组内可指定一台/多台出声，其余静音(默认全部出声) |
| 设备墙预览 | 被控端周期回传当前帧缩略图，遥控端缩略图墙 |
| 运维(Phase 2) | OTA 远程更新 / 远程重启 / 断电恢复上次任务 / 定时编排 |

完整通信协议见 [`protocol_spec.md`](./protocol_spec.md)。

### 下载(预编译产物)

每打一个 `v*` tag，CI 会云编译四端并把产物挂到对应 [Release](https://github.com/Jieoz/lan-media-wall/releases/latest)，目标机无需装 Python / Flutter / Android SDK：

| 端 | 产物 | 说明 |
|---|---|---|
| broker | `lmw-broker`(Linux ELF) / `lmw-broker.exe` | PyInstaller onefile，独立可执行，无需 Python |
| Windows 被控端 | `lan-media-wall-player-setup.exe` | Inno Setup 安装包，已内置 mpv 运行时 |
| Android 被控端 | `app-release.apk` | 原生 Kotlin 播放器(被控端) |
| Flutter 遥控端 | `app-arm64-v8a / armeabi-v7a / x86_64-release.apk` | 分 ABI 的遥控端 APK，按手机架构装一个即可 |

### 端到端快速上手

1. **起 broker**(群晖 / 任意 Linux):
   ```bash
   LMW_PSK=$(python3 -c "import secrets;print(secrets.token_hex(32))")  # 生成共享密钥，记下来
   ./lmw-broker            # 或 docker 跑,见 broker/README.md
   ```
   记下 broker 的局域网 IP(如 `192.168.1.10`)和这把 `PSK`,全系统共用。
2. **装被控端**(每块屏):装 `lan-media-wall-player-setup.exe`(Windows) 或 `app-release.apk`(Android);首次启动填 broker IP + 端口 `8770` + **同一把 PSK** + 分组名,之后开机自启、全屏置顶。
3. **装遥控端**(手机/平板):装对应 ABI 的遥控 APK,设置里填同样的 broker IP / 端口 / PSK,回到设备墙就能看到上线的屏。
4. **播放**:控制页选分组 → 编辑 playlist(单文件或多文件轮播)→ 预缓存 → 一键同步播放;同组走三段握手同步起播,`sync=false` 则各播各的。

> **安全前提**:整套系统的信任边界就是这把 PSK——谁拿到 PSK + 在同一局域网,就能完全控制设备墙。务必保密,且不要把 broker 暴露在不可信网络上;需要机密性时在 broker 放证书启用 WSS(8771)。

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

Synchronized playback via WS clock-offset handshake (no system NTP dependency) + three-phase handshake (prepare→ready→play_at), targeting ±50–100ms. Unified **group** model toggles sync vs independent; unified **playlist[]** model covers single-file and rotation. NAS pre-distribution (WebDAV/HTTP) with resumable cached downloads + sha256 verification. PSK + HMAC-SHA256 auth with replay protection. UDP discovery + manual IP binding. Per-group audio master selection. Thumbnail device-wall preview. (Phase 2: OTA, remote reboot, power-loss resume, scheduling.)

See [`protocol_spec.md`](./protocol_spec.md) for the full wire protocol.

### Downloads (prebuilt)

Each `v*` tag triggers CI to cloud-build all four ends and attach the binaries to the matching [Release](https://github.com/Jieoz/lan-media-wall/releases/latest) — target machines need no Python / Flutter / Android SDK:

| End | Artifact | Notes |
|---|---|---|
| broker | `lmw-broker` (Linux ELF) / `lmw-broker.exe` | PyInstaller onefile, standalone, no Python required |
| Windows player | `lan-media-wall-player-setup.exe` | Inno Setup installer, mpv runtime bundled |
| Android player | `app-release.apk` | native Kotlin player (the controlled screen) |
| Flutter controller | `app-arm64-v8a / armeabi-v7a / x86_64-release.apk` | per-ABI controller APK; install the one matching your phone |

### End-to-end quickstart

1. **Run the broker** (Synology / any Linux):
   ```bash
   LMW_PSK=$(python3 -c "import secrets;print(secrets.token_hex(32))")  # generate the shared key
   ./lmw-broker            # or via Docker, see broker/README.md
   ```
   Note the broker LAN IP (e.g. `192.168.1.10`) and this `PSK` — shared system-wide.
2. **Install players** (each screen): run `lan-media-wall-player-setup.exe` (Windows) or `app-release.apk` (Android); on first launch enter broker IP + port `8770` + the **same PSK** + a group name. They then autostart fullscreen on boot.
3. **Install the controller** (phone/tablet): install the ABI-matching controller APK, set the same broker IP / port / PSK; the device wall lists online screens.
4. **Play**: on the control page pick a group → edit a playlist (single file or multi-file rotation) → prefetch → one-tap synced play. Synced groups go through the three-phase handshake; `sync=false` plays each screen independently.

> **Security premise**: the trust boundary of the whole system is this one PSK — anyone holding it on the same LAN can fully control the wall. Keep it secret, keep the broker off untrusted networks, and enable WSS (8771) by dropping certs into the broker for confidentiality.

### License

MIT. Design informed by [Syncplay](https://github.com/Syncplay/syncplay) and [Anthias](https://github.com/Screenly/Anthias) (both GPLv3); this is an independent implementation that does not copy their code.
