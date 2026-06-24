# Changelog

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/); versions are git tags that trigger CI cloud-builds and Release artifact attachment.

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
