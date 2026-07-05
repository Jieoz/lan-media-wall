# LAN Media Wall — Android Player (被控端)

Native Android (Kotlin + Media3/ExoPlayer) player for the LAN Media Wall. It is
behaviorally **on par with the Windows player** (`../../windows_player/`) — same
protocol, same roles, different playback kernel (Media3 instead of mpv).

Implements the shared contract in [`../../protocol_spec.md`](../../protocol_spec.md)
**v1.5** (auth/topology/pairing §13–§15, derived keys §17, device config §19,
prefetch barrier §21, remote self-update §23).

> **Current build: `versionName 1.10.1 / versionCode 21`** (see `app/build.gradle.kts`).
> `versionCode` MUST increment on every release — it's how Android decides "this is
> newer". Bumping `versionName` alone can cause the update to be rejected as the same
> version. See the release checklist in the root README.

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
  grabs the current frame off the video `TextureView`, scales to ≤320px JPEG,
  sends `thumb_meta` + a binary frame.
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
  own APK with no per-device adb. FOUR guardrails gate it (`update/UpdateGuard`):
  (1) the frame MUST be **authenticated** (`Envelope.authed`; an `open`/unsigned
  box refuses — `rejected:unauthenticated`); (2) the target `version_code` MUST be
  **strictly newer** (blocks downgrade/replay); (3) `url` + a 64-hex `sha256` are
  required and the downloaded bytes are **re-hashed** before install (mismatch →
  `failed:sha256-mismatch`, file deleted, never half-installs); (4) the Android
  platform enforces **same-signer** at boot-scan time (free). Install mirrors
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
./gradlew testDebugUnitTest  # JVM unit tests (envelope/clock/range math)
```

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

## Residual risks (real-device only)

These can't be exercised in a headless CI/container and need a device:

- Media3 actual decode/render + frame-accurate synced start (±50–100ms target).
- Thumbnail capture from the live `TextureView` (returns null with no surface).
- Lock Task Mode behavior depends on Device Owner provisioning.
- OEM background-activity-start / autostart restrictions vary by vendor.
- `EncryptedSharedPreferences` needs a working Keystore (falls back to plain
  prefs if unavailable, logged — acceptable degradation).

## Inbound-frame observability & p2p clock fix (1.10.1)

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
