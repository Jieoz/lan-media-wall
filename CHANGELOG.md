# Changelog

## [v1.17.6] — 2026-07-18

- Field fix for **second legacy OTA on and-b2b90f28f7-class boxes** (versionCode **1176**, versionName `1.17.6`). Single-sourced from `remote_flutter/pubspec.yaml` (`1.17.6+1176`). Mapping: `versionCode = major×1000 + minor×10 + patch`.
  - **Root daemon — leftover `.lmw-backup` no longer permanently blocks re-stage.** First legacy activation (`legacy_staged` / `legacy_activation_dispatched`) leaves `/data/app/<pkg>-1.apk.lmw-backup` until commit. The daemon never auto-committed after reboot, so the next remote push hit fail-closed `legacy_activation_failed` even though the first OTA had worked. `lmw_legacy_stage` now auto-commits when target+backup both exist, restores orphan backup when target is missing, then stages the new APK. Host unit tests lock the pure commit/restore decision.
  - **Ops note:** install logic lives in `/system/xbin/lmw_root_daemon`. Boxes that already took a legacy path (e.g. `and-b2b90f28f7` on 1174) need **QZX Update Tools / `lmw_setup`** (or push the new daemon ELF) before another remote OTA; APK-only is not enough for this fix. Temporary operator workaround on a stuck box: delete `/data/app/com.jieoz.lanmediawall.player-1.apk.lmw-backup` as root, then retry.

## [v1.17.5] — 2026-07-18

- Field closeout for **remote rename** + **push-upgrade on fail-class boxes** (versionCode **1175**, versionName `1.17.5`). Single-sourced from `remote_flutter/pubspec.yaml` (`1.17.5+1175`). Mapping: `versionCode = major×1000 + minor×10 + patch`.
  - **Player — remote rename actually shows on the wall.** Android/Windows `status` now include `device_name` (§5.1/§5.2). `configure_device` hot-updates Discovery announce name and pushes an immediate status so the controller no longer sticks on `device_id` after a successful rename (volume/group already worked).
  - **Root daemon — OTA `pm_failed` false-fail on and-8b0677b40b-class boxes.** Field evidence: same APK hash downloaded+sha256-OK on both boxes; `and-8b0677b40b` failed at install with `detail=pkg: /data/local/tmp/lmw_update_staged.apk`, while `and-b2b90f28f7` took the legacy path and landed 1174. Daemon now treats an exact `Success` line as install success even when popen/exit status is noisy on 4.4/YunOS, and `pm_failed` detail prefers real `Failure`/`Error` lines over the leading `pkg:` path diagnostic. Host unit tests cover summary selection.
  - **Ops note:** the OTA install path runs inside `/system/xbin/lmw_root_daemon`. After this release, re-run **QZX Update Tools / `lmw_setup`** (or push the new daemon ELF) on fail-class boxes so the new install logic is live; only updating the Player APK is not enough for the daemon-side fix.

## [v1.17.4] — 2026-07-18

- Player experience + remote configure closeout (versionCode **1174**, versionName `1.17.4`). Single-sourced from `remote_flutter/pubspec.yaml` (`1.17.4+1174`). Mapping: `versionCode = major×1000 + minor×10 + patch`.
  - **Player — selected cache cleanup StackOverflow.** `PlayerService` `LiveCacheBackend.PlayerView.cacheSummary()` no longer self-recurses (Kotlin same-name resolution); it calls outer `buildCacheSummaryMap()`, so cleanup `summary_after` no longer kills the process.
  - **Player — seamless transition P0.** Near-fullscreen freeze JPEG (`TRANSITION_FREEZE_MAX_WIDTH=1280`) + `cachedFreezeFrame` / `showTransitionFrame` cover the single-decoder swap gap on API19 SurfaceView; `showImage` carries `itemId` for freeze association. Not dual-VDEC zero-seam.
  - **Player — settings remote-home key.** `SettingsActivity` binds QZX_C1-class physical “回主页” (`KEYCODE_SETTINGS`=176) to return to the wall.
  - **§19 configure_device transport fields.** Controller can push `broker_host` / `broker_port` / `use_wss` / `psk` (or clear host → discovery/P2P) with strong UI confirm; Android/Windows persist then **rebuild transport without stacking status/thumbnail loops**; PSK requires authenticated/signed frames. `protocol_spec` §19 + Windows tests extended.

## [v1.17.3] — 2026-07-17

- Operator UX polish + **intuitive upgrade versionCode** (versionCode **1173**, versionName `1.17.3`). Single-sourced from `remote_flutter/pubspec.yaml` (`1.17.3+1173`). Mapping: `versionCode = major×1000 + minor×10 + patch` (e.g. **v1.17.2 → 1172**, **v1.17.3 → 1173**). Legacy small codes (69–72) remain accepted as bare integers for older boxes.
  - **Controller — upgrade dialog.** Accepts `v1.17.3` / `1.17.3` / `1173` / `1.17.3+1173`; removes the hard-coded “正式包=69” text; still rejects non-newer targets and soft-warns on huge jumps.
  - **Controller — orchestration actions.** Renames primary actions to **替换并播放 / 只缓存不播 / 追加到当前列表 / 清空列表并停播**; **应用到此设备 → 下发到此设备** with confirm; **出声台 set_audio_master → 本家出声设备**.
  - **Controller — device dialog layers.** Actions split into 常用 / 维护 / 危险; drops the duplicate “推送内容” twin of “编辑当前列表”; volume notes “仅本机”.
  - **Controller — cache cleanup copy.** Generation-conflict label/subtitle explain idle/no-push cases in plain language.
  - **Player — takeover card on top.** Settings moves battery-ignore + default HOME shortcuts under a top **现场接管（一次性）** section.

## [v1.17.2] — 2026-07-17

- Formal field-ops release (versionCode **72**, versionName `1.17.2`): residual operator UX + no-ADB takeover shortcuts. Single-sourced from `remote_flutter/pubspec.yaml` (`1.17.2+72`). Includes prior field-fix 70/71 forensics/read-back work that had not been promoted to a GitHub Release.
  - **Controller — device wall group filter.** Group chips now **filter** the wall (plus「全部」); edit/rename moved to explicit ✎ buttons so tapping a group no longer only opens rename.
  - **Controller — cache multi-select cleanup.** Inventory list can multi-select reclaimable items (protected rows stay locked); new「清理勾选 N 项」commits `mode=selected` with the device's current `push_id`. Dry-run path remains as「清理演练 N 项」.
  - **Controller — single-device playlist entry.** Device config dialog primary action is「当前列表(编辑/推送)」so operators can manage one box's playlist without hunting the orchestration pane.
  - **Player — takeover shortcuts.** Settings screen adds「打开电池白名单/自启」and「选择默认桌面/HOME」system-intent buttons (no silent `pm disable`) plus live `battery_ignored` / `we_are_default_home` status under diagnostics export.

## [Unreleased]

- field-fix (versionCode **71**, versionName `1.17.1-field-fix`): one combined field build closing two operator gaps, single-sourced from `remote_flutter/pubspec.yaml` (`1.17.1-field-fix+71`, strictly newer than boot-probe 70 / formal 69 / field 67); the controller rebuilds too. No change to the 69 OTA/install logic or the 70 `boot_audit` work.
  - **Controller — group playlist read-back.** The orchestration pane could only import a playlist from a *single* device; selecting a group never filled the draft, so operators reported "group playlist cannot be fetched". A new **「载入分组当前清单」** button under the retitled **目标分组（推送/同步目标）** section picks a representative from the group's online members and loads its exact ordered `active_playlist` into the editable draft. Representative policy (pure, in `lib/state/group_playlist_load.dart`): prefer a member whose `active_playlist.group_id` matches the selected group, else any online member with a non-empty active playlist, tie-broken by `playing`/`buffering` over `idle`, then lexicographic `device_id`. The load reports the truth rather than hiding divergence: a per-member fingerprint (`playlist_id` + ordered `item_id` join) is compared against the representative and the snackbar states how many online members are consistent / divergent / missing an active playlist (e.g. `已从代表 and-xxx 载入；组内 2 台一致、1 台不同、1 台未上报`). The single-device path (now **单台当前播放列表（精确回读某一台）**) is unchanged. No new wire types — it reads the existing `status.active_playlist`.
  - **Player — universal no-ADB takeover forensics.** With no ADB on the heterogeneous field boxes and a competing OEM player that auto-starts and re-grabs the screen, the one-button diagnostics export now includes a `===== takeover_forensics =====` block to design per-device cast takeover. It captures, all best-effort and never-throwing: device identity (manufacturer/brand/model/product/device/hardware, android_release/sdk_int/security_patch, package + versionName/versionCode + first/last install times); HOME/launcher info (preferred/default HOME activity, full MAIN+HOME candidate list with `package/class/priority/default/mine`, whether we are a HOME handler and whether we are the default HOME — `unknown` on API gaps); our boot components (MainActivity enabled state, `PowerManager.isBackgroundRestricted` on API 28+, alongside the existing battery-optimization / boot-receiver / home-candidate lines); a heuristic installed-package list (any MAIN+HOME or MAIN+LEANBACK_LAUNCHER handler, plus packages whose id/label contains `launcher`/`tv`/`home`/`kiosk`/`player`/`media`/`signage`/`youku`/`gallery`/`desk`, each flagged `heuristic` — a hint to look, never proof of guilt) with `enabled`/`system`/`home`/`leanback` booleans and a truncation marker; and best-effort running processes. The forensics are **read-only** — no `pm disable`, no uninstall. The manifest adds `<queries>` for MAIN+HOME and MAIN+LEANBACK_LAUNCHER so competing launchers stay resolvable under Android 11+ package visibility without `QUERY_ALL_PACKAGES`. Existing `===== boot_audit =====`, helper/restart/update, and player.log-tail sections are retained.

- boot-probe (versionCode **70**, versionName `1.17.1-boot-probe`): a forensic-only build that collects durable boot-auto-start evidence for the sdk29 (`and-319413a07c`, Android 10) autostart investigation. A new `BootAudit` sink writes append-only `time_ms=… elapsed_ms=… event=… detail=…` records to `filesDir/logs/boot_audit.log` the instant `BootReceiver` fires — independent of `PlayerService`, so a boot that never reaches the service still leaves evidence. It records `receiver_enter` (with sdk/pid/bg-restricted), `service_start_ok|service_start_fail mode=startForegroundService|startService`, `activity_start_ok|activity_start_fail`, `receiver_exit`, `service_oncreate`, and first-per-process `main_oncreate`/`main_onresume`. The Settings diagnostics export now includes a `===== boot_audit =====` section plus `battery_optimization_ignored=`, `boot_receiver_enabled=`, and `is_home_candidate=`, all safe when the service is null. No change to the 69 OTA/install logic; no daemon or device-reboot changes. Version is single-sourced from `remote_flutter/pubspec.yaml`, so the controller rebuilds too — acceptable for probe delivery.

## [v1.17.1] — 2026-07-17

- Field-driven OTA fixes for the rooted-box update path (versionCode **69**; `remote_flutter/pubspec.yaml` is the single source `1.17.1+69`). Evidence from device `and-6037055a3d` (sdk19): the root daemon staged the APK and returned a reboot-required line, but the player mis-parsed it as `install_daemon_fail` and only a **whole-device reboot** activated the update — dropping Wi-Fi on the way.
- The root daemon now prefers an **App-only install before any whole-device reboot**: `lmw_pm_install` tries `pm install -r` then `pm install -r -f` (force internal), continuing only on `INSTALL_FAILED_INVALID_INSTALL_LOCATION`. On a `Success` line the app is reinstalled in place and only the app restarts — no device reboot. No `-d` downgrade is enabled as policy.
- Only when **both** pm attempts fail does the daemon fall back to the legacy staged-activation path, and it now emits the canonical line `ok install state=legacy_activation_dispatched reboot_required via=data_app_scanner`. The player's `parseInstall` treats this — and the field variant `state=legacy_staged` + `reboot_pending` — as a **non-failure** reboot-required outcome (`LEGACY_ACTIVATION_DISPATCHED`), so a staged-then-reboot update is no longer reported as failed. The controller status wording maps it to 「已就绪·待整机重启生效(非失败)」.
- The controller remote-update dialog now guards the target **versionCode**: it shows the device's known versionName/versionCode when reported, pre-fills current+1, rejects dotted version names and values ≤ current, soft-warns on absurdly large values, and the success snackbar distinguishes an **App restart** from a possible **legacy whole-device reboot**.
- Image dwell UX is now expressed in **seconds** (not raw ms): picking or adding an image prompts a dwell picker (5/8/10/15/30 秒 + 自定义, default 8s), the URL dialog labels the field in 秒, existing image items can have their dwell edited in place, and the list subtitle reads `图片 · N秒`. The wire field `duration_ms` (milliseconds) is unchanged; seconds is a controller-side presentation layer.
- Residual risk: if **both** pm install attempts fail on a given box, the legacy whole-device reboot is still the last-resort activation path (and can still momentarily drop the network on that device). This release makes that path honest and rare, not impossible.

## [v1.17.0] — 2026-07-15

- Phase B wires the Phase A cache-cleanup core into a real end-to-end control flow. The Windows and Android players now handle live `cache_cleanup` / `cache_inventory` requests off the receive loop, emit only terminal `cache_cleanup_result` / `cache_inventory_result` frames (no optimistic generic ACK), carry a lightweight `status.cache_summary`, and advertise `cache_cleanup_v1` / `cache_inventory_v1` in `hello.capabilities` only because the matching handlers exist. The player remains the sole deletion authority: requests carry item ids only (never paths), identity resolves to a physical `content_key` locally, generation is re-checked under the cleanup lock and fails closed, and duplicate `request_id`s replay the journaled terminal result without deleting twice.
- The broker routes `cache_cleanup` / `cache_inventory` controller→player and `cache_cleanup_result` / `cache_inventory_result` player→controller only, rejecting controller-forged results and player-forged requests, and returns results unicast to the initiating controller rather than broadcasting.
- The Flutter controller converges both the broker and P2P result receive paths into ONE `CacheOpsReducer` keyed by `request_id + device_id`, giving per-device isolation, duplicate idempotence, stale/late-result rejection, timeout reaping, and mutually-distinct terminal states (success / partial / failed / timeout / unsupported / offline / generation-conflict). Capability is truthful: an unsupported or offline target settles immediately and is never sent-then-silently-timed-out.
- A new device cache-management flow (inventory → dry-run → explicit confirmation → commit) shows total/reclaimable/protected/in-flight summary, per-item protection reasons, per-device terminal outcome and retry, and stays safe on a 320-wide screen. Committing real deletion always requires an explicit confirmation dialog and sends the reviewed dry-run candidate item ids; dry-run mutates nothing. This is a separate entry from "push content" — existing playlist-row removal continues to mean "remove from playlist only" and never touches cached media.
- Closeout fixes in this candidate: (a) the Flutter controller now labels the **real** wire protection tokens players emit (`playing` / `active` / `prepared` / `inflight` / `last_task` / `pinned` / `shared_content`, plus `not_found` / `delete_failed` / `generation_*`) instead of `protected_*` aliases that never appeared on the wire, covering every emitted reason including `prepared` and `pinned`. (b) the Android player derives the `operation_fingerprint` **target from the request payload** (`group:<gid>` for a group-addressed request, else `device:<did>`, else `all`) byte-identically to the broker and Windows, so a group-addressed cleanup result is no longer rejected by the broker's fingerprint gate. (c) cache cleanup no longer holds the shared generation lock for the whole O(N) scan/plan — a private transaction lock serializes cleanups and guards the journal while the generation lock is taken only for the fast pre-delete re-check + delete hand-off, so a running cleanup never stalls the receive loop or playback transitions; fail-closed generation semantics are unchanged. (d) the idle-device limitation is now explicit: an idle player has no adopted generation, a destructive commit's required non-empty `expected_push_id` can never match the idle `None`, so it fails closed with `generation_mismatch` and deletes nothing — no sentinel invented, non-empty-generation contract intact (dry-run still works on idle).
- Review-closeout polish: Flutter `cache_ops_test` fingerprint-mismatch fixture now passes `summaryAfter: null` (type is `CacheSummary?`, not Map) so the reducer test file compiles under sound null-safety; broker `_cleanup_fingerprint` keeps an explicit empty `reason` (only missing/None falls back to `manual`) and treats null/non-list `item_ids` as empty, matching Windows/Android so an empty-reason or null-item_ids request cannot desync the result-fingerprint gate. (e) `WallState.cacheCleanup` / `cacheInventory` now pass `deviceId` into `Commands.cacheCleanup` / `Commands.cacheInventory` so the wire payload carries `device_id`; broker/player/controller fingerprints all use `device:<id>` instead of the controller storing `device:<id>` while the wire payload silently defaulted to `all` and every result was rejected as `operation_fingerprint_mismatch`.
- Not in this release: Phase C group realtime playlist editing, and any "apply-and-clean" composition that would couple cleanup to a specific `push_id` adoption. Field/P2P validation remains operator-side after install; CI + promote gate the release bytes.

## [v1.16.0] — 2026-07-14

- Phase A cache-lifecycle **core + protocol only** (not wired, not user-visible). Adds a proven-safe cache-cleanup core mirrored on both players — Windows `windows_player/cache_cleanup.py` + `cache_refs.py` and Android `CacheCleanup.kt` + `CacheReferenceSnapshot.kt` — plus the additive protocol contract. The player is the sole deletion authority: requests carry item ids (never paths), identity resolves to a physical `content_key` locally, and a blob is deleted only when NO protected item references it. Protection is a content-keyed union over playing/active/prepared/inflight/last_task/pinned and shared-content, while mere historical playlist metadata no longer hard-pins media. One planner drives both dry-run and commit; commit re-checks the generation under the cleanup lock and fails closed (deletes nothing stale); destructive `request_id`s are journaled for idempotent replay; results are structured per-item deleted/skipped/failed with distinct reasons and once-per-blob freed bytes.
- Fixed a dangling-index defect in that core: when two unprotected item ids resolve to one physical blob and a selected cleanup names only one, deleting the shared blob now prunes **every** alias id that resolves to it, not just the requested candidate, so no index row is left pointing at a deleted file. The `deleted` response still honestly reports only the requested candidate ids; dry-run and delete-failure prune nothing. Duplicate selected ids delete/prune/report exactly once. Mirrored strictly in Python and Kotlin tests.
- Phase B (live request routing, status emission, broker/P2P return path, Flutter UI, and capability advertisement) is deliberately **not** wired in this release. Nothing here is reachable by an operator yet.

## [v1.15.3] — 2026-07-14

- The Flutter controller now imports a selected player's exact active playlist, current item and loop mode into the editable draft. Both the orchestration pane and the per-device push dialog show the active item, support safe reorder/delete/append, preserve current-item identity while reordering, and apply the ordered list plus explicit loop mode back to that device without deleting cached media. Selecting a legacy player that does not report `active_playlist` clears the prior device draft instead of risking a stale cross-device apply; uploads cannot dismiss/dispose the dialog mid-flight.
- Fixed stale Android Player settings diagnostics: if the settings Activity renders before `PlayerService.onCreate`, the one-second status loop now detects the service-availability edge and refreshes playback/cache/error/probe fields once. A live service no longer leaves the screen stuck on `service not ready`; root-daemon probes are not repeated every tick.

## [v1.15.2] — 2026-07-14

- Hardened Android Player document-provider export: overwriting an existing destination now explicitly truncates it, preventing stale trailing bytes from an older longer diagnostic, and a broken provider returning success without a destination Uri now produces a visible failure instead of silently doing nothing.

## [v1.15.1] — 2026-07-14

- Android Player diagnostics now launch the system document picker, so the operator chooses Downloads, internal storage, or a mounted USB destination; stripped Android 4.4/YunOS builds without DocumentsUI fall back to the existing app-external file path instead of losing export. The generated text still includes startup state and persisted `player.log` and remains independent of the player service/LAN link.
- Android Controller cold/process relaunch now discards the Activity saved-state bundle at the native boundary before Flutter initializes, in addition to disabling Flutter state restoration. It always enters the ready-to-use `ResponsiveShell`; settings remains an explicit toolbar-button action and ordinary background/resume keeps an already-open dialog.

## [v1.15.0] — 2026-07-14

- Playlist editing/control now spans add/append, whole-list replace, delete-one, clear-all, arbitrary reorder/up-down and prev/next, driven from one tested `PlaylistDraft`; broker and P2P converge on a single semantic handler.
- Looping is an explicit three-mode `LoopMode {none, all, one}` on a new canonical wire field `loop_mode`, with one legacy fold point per language (`loop_mode` preferred; legacy `loop:true ⇒ all`, absent/false ⇒ none) and dual emission during the compatibility window. `none` holds at completion and clamps prev/next, `all` wraps, `one` repeats the current item seamlessly through the existing single-decoder/OEM-continuous route (no second decoder, no seam) while explicit prev/next still navigates with wrap.
- An empty replace truly clears the target's ACTIVE playlist — stops playback, enters the idle/black safe state, clears current-index/task persistence — while preserving cached media inventory; empty append stays a harmless no-op.
- Real media-push progress is now a truthful shared state machine (`MediaProgressMachine`) consumed identically by P2P and broker at the controller: progress is monotonic 0..100, keyed device+item+generation, reset per push job, and NEVER shows 100 before the player's checksum + atomic finalize + `ready` handshake (both Android and Windows producers cap `downloading` at 99 pre-finalize). Every non-empty replace carries a unique `push_id`, echoed by upgraded players after adopting that exact command; this releases the new-job stale-ready barrier even when the same `playlist_id` is reused, while an old status snapshot remains held at 0. Aggregation is restricted to the command's expected item set, so unrelated historical cache inventory cannot pollute percent/completion/error counts. A device that errors or drops offline mid-job is surfaced as a frozen failure, not a live bar that would read as ongoing success. UI cadence is bounded by the player's 1.5-second status/wall-snapshot cadence.
- Windows desktop CONTROLLER artifact adapts `remote_flutter` with a platform capability that removes the QR/camera scan path on Windows (Android keeps scan), without forking the controller codebase or repurposing the Windows Player.

## [v1.14.13] — 2026-07-13

- Disabled `FlutterActivity` Android instance/navigation restoration through a repository-owned `MainActivity` template that CI installs after `flutter create`; real process restarts now enter `ResponsiveShell`, while an ordinary pause/resume leaves a live settings dialog alone.
- Made Android release lanes and tag promotion fail closed: all signing secrets and the configured production certificate fingerprint are mandatory, missing `apksigner` is fatal, and every promoted APK must carry pubspec `versionName=1.14.13` / `versionCode=61` and exactly the expected signer.
- Normalized duplicate physical `Range` headers to an empty `416 Content-Range: bytes */total` response and added a raw-socket regression test.
- Made the Android player self-diagnosable at 启动中 without adb: startup is now classified (`WAITING_SETUP` fresh install vs `STARTING` vs `START_FAILED`) by a pure, unit-tested `StartupStatusPolicy`; a stalled foreground-service creation flips to an actionable on-screen cause within 8s; a "restart player service" button retries with `Throwable` capture; and an "export diagnostics to a file" button writes the startup phase + settings + `player.log` tail to a USB/file-manager-readable path that works even when no service is running (no LAN link required).
- Hoisted the controller's multi-file playlist out of transient Widget state into a tested `PlaylistDraft` model (multi-select import with `item_id` de-dup + order, reorder/remove/clear, load-from-active-playlist, immutable public view) so the orchestration pane's list, sync/loop options, and push/append actions all read one source of truth.

## [v1.14.12] — 2026-07-13

- Replaced the Android player's fixed FIFO download pool with a bounded two-lane scheduler: 2 active workers, at most 64 pending items, foreground promotion for the current `prepare` item, background FIFO for playlist prefetch, and item-id de-duplication. New prepare generations cancel and invalidate stale cache waiters before they can prime the decoder or report `ready`.
- Made temporary P2P overload recoverable: Android retries bounded `429/503` responses with capped `Retry-After`/exponential backoff and jitter, preserves `.part`, resumes with `Range`, and deterministically cancels queued work plus active OkHttp calls on stop.
- Hardened the controller's local media HTTP contract: strict single byte ranges (`N-M`, `N-`, `-N`), explicit empty `416`/`405`, success headers only after admission, empty `503 Retry-After: 1`, bounded FIFO admission, close/restart generation isolation, and deterministic waiter release on stop. Added loopback HTTP tests for ranges, overload, disconnects, stop, and restart.

## [v1.14.11] — 2026-07-13

- Bounded Android player media downloads to 2 active workers with a finite 64-item queue, preventing a large playlist from creating one thread/socket per uncached item. Queue overflow is reported as `error:queue-full` instead of retaining unbounded work.
- Added P2P controller-side HTTP backpressure: at most 6 media streams are served concurrently, excess requests wait in a bounded FIFO queue, and overload fails explicitly with `503 Retry-After` while Range-resume remains intact. Media is still streamed from disk and never buffered wholesale in memory.
- Added deterministic concurrency/queue regression tests for both ends. The existing per-device cache map continues to expose queued failures, downloading progress, verification, readiness, and errors in device status. P2P remains intended for small deployments (≤8 players); larger walls should use Broker/NAS distribution.

## [v1.14.10] — 2026-07-13

- Fixed half-open P2P controller ownership with an API19-compatible monotonic 15s inactivity lease, 5s read tick/ping, atomic stale takeover, and generation-safe cleanup; an actually active second controller remains rejected with close 1013.
- Exposed WebSocket close code/reason through the Flutter P2P link and peer failure/log paths. Reconnect backoff now resets only after a verified application frame, so repeated upgrade→1013 closes back off 1s→2s→4s instead of storming every second. Real-device validation remains pending.
- Fixed the real P2P control path from the captured v1.14.8 controller log: a player announce that explicitly declares `topology=p2p` no longer lets a compatibility `broker_hint` switch the controller onto `BrokerClient`, where raw `status/time_sync` were intentionally discarded and every device remained “已发现”. The controller now opens per-player P2P links, consumes status, and advances cards to “已连接”.
- Restored per-device configuration on the same path: rename/group/volume commands are delivered to the selected connected player, and the controller now confirms that the configuration command was actually queued instead of closing the dialog silently.

## [v1.14.9] — 2026-07-12

- Fixed controller composition semantics: ordinary “编排/添加项目” now appends by default, while whole-list replacement is explicit in both payload and UI. Sequential A then B composition keeps `[A, B]` so previous/next target distinct content.
- Fixed API19 single-VDEC MediaPlayer transitions without a second decoder: the existing ImageView holds the previous item's cached JPEG while the same MediaPlayer is released/rebuilt, then clears on the new source's real first-frame callback or on failure. Single-item playback still uses `setLooping(true)`.

## [v1.14.8] — 2026-07-12

- Added ordered playlist `replace`/`append` semantics across the Flutter controller, protocol, and Android player. Append de-duplicates by `item_id`, preserves the current item and persisted index, and reports `current_index`/`playlist_count` without conflating the active sequence with cached files.
- Added content-clock late-start compensation for synchronized MediaPlayer playback, continuous OEM looping for a single item, and an explicit API19 single-decoder transition policy with deterministic unit coverage.
- Restored one-shot per-item thumbnail extraction, hardened the verified APK update/install path, and added a read-only QZX control-plane diagnostic bundle for topology, update, playlist, and sync evidence.
- Made topology diagnostics truthful by reporting actual operating transport separately from coordinator-declared topology and explicitly logging broker-path frame mismatches.

## [v1.14.7] — 2026-07-12

- **QZX 真机默认改为原生 MediaPlayer。** 同素材 A/B 已确认 ExoPlayer 可见掉帧，而脚本强制重建后实际运行的 MediaPlayer 顺畅；因此 `auto` 不再回落到 ExoPlayer。仍可显式选择 ExoPlayer 作为运维覆盖。
- **修复设置页解码器“保存但未实际切换”。** 保存后用 `NEW_TASK|CLEAR_TASK` 重建 kiosk 任务：销毁旧 `MainActivity`、释放旧 controller，并按刚持久化的选择重建播放器,消除“设置显示 MediaPlayer、实际仍跑 ExoPlayer”。当前内核与来源进入 `status.video_backend` 与 player.log,不再静默漂移。
- Fix QZX_C1 restart false negatives caused by truncating busy-ROM `ps` output before the Player row; the Windows harness now preserves raw `ps` evidence and parses the PID locally.
- Keep double-clicked field-check windows open even when an inner command aborts before the normal footer.
- Make A/B evidence per-run and fail closed on backend mismatch; never execute a second fallback restart after an authoritative daemon verdict.

## [v1.14.6] — 2026-07-12

- Restart verification now proves that the real daemon worker ran exactly once and actually transitioned the app: `force-stop` must succeed, the post-restart PID must differ from the captured pre-restart PID, and both process-up and activity-resumed signals must pass. Missing daemon, a nonzero worker verdict, unsupported activity evidence, or an unchanged PID all fail closed; manual controller action can no longer be mislabeled as automatic recovery.

## [v1.14.5] — 2026-07-12

- Fixed the immutable QZX Update Tools package manifest to include the new one-click real-device acceptance harness, `qzx_field_check.bat` and `qzx_field_check.sh`. The previous v1.14.4 source and builds passed, but its promoted ZIP omitted these two files; v1.14.5 republishes the same fail-closed app-restart implementation with the complete acceptance bundle.

## [v1.14.4] — 2026-07-12

- **Root-daemon app-restart is now a deterministic verify-and-retry state machine that proves recovery with TWO signals, not a blind shell chain.** Field ground truth on QZX_C1 was that `RESTART_APP` force-stopped the Player but the relaunch did not reliably take, leaving a black kiosk until a manual explicit `am start` (log 16:10). The daemon worker (`lmw_restart_app_run`) now force-stops once, then explicit-launches the allowlisted component (`am start -n <pkg>/.MainActivity`, dropping the unreliable `-a MAIN -c HOME` implicit resolution), waits, and VERIFIES before retrying — up to a bounded attempt budget, with no reboot fallback. Verification distinguishes **PROCESS_UP** (the package's main process appears in `ps`) from **ACTIVITY_RESUMED** (our component is the resumed/focused activity per `dumpsys activity activities`, falling back to `dumpsys window windows` `mCurrentFocus`). Full recovery requires BOTH; a process that came back *behind the launcher* is a partial failure, not success.
- **Fail-closed handling of API19 boxes that can't report activity state.** `lmw_activity_resumed` is a pure, host-tested tri-state — `RESUMED` / `OTHER` / `UNSUPPORTED`. On a ROM that prints no resumed/focus line the daemon records `activity_resumed=unsupported` and fails verification: process-up alone never proves that the kiosk is visible and is never accepted as success.
- **The bounded restart evidence log (`/data/local/tmp/lmw_restart.log`, rotates to `.1` at 64 KiB) now ends with an explicit terminal token.** Each attempt logs `verify attempt=N process_up=B player_pid=P activity_resumed={yes|no|unsupported}`, and the final line is `restart_verified` or `restart_failed` with `attempts=`, `process_up=`, `activity_resumed=`, and `player_pid=`. No secrets are logged (only package name, pids, and `am` tokens).
- **Root-only `-restart` CLI shares the exact socket worker and cannot reboot.** `lmw_root_daemon -restart` runs the SAME `lmw_restart_app_run` the abstract-socket `RESTART_APP` forks, but inline, exiting `0` only on full recovery — so a real-device harness can read a truthful pass/fail. CLI dispatch is driven by pure, host-tested helpers (`lmw_cli_mode` / `lmw_mode_requires_root` / `lmw_mode_can_reboot`): `-restart` and both serve modes require `euid==0` (a non-root `-restart` is refused), `-probe` stays root-free, and NO CLI mode can reach the whole-device reboot — reboot remains reachable only as the `SO_PEERCRED`-authenticated socket `REBOOT` verb. Production socket authorization is unchanged.
- **One-click real-device field harness (`scripts/qzx_field_check.sh` + `.bat`).** Jay plugs in one box and runs it once: it (A) proves the app-only restart brings the Player back automatically within a bounded timeout using the two-signal verdict above — PASS requires both a new PID AND our activity frontmost; process-only, another foreground activity, and unreportable activity state are all FAIL — capturing before/after uptime, Wi-Fi state, versionName/Code, daemon probe, the daemon's restart evidence log, and a logcat tail; then (B) runs an ExoPlayer↔MediaPlayer A/B on the same box + same `resume_last` media for a configurable duration each. It is conservative (never reboots, uninstalls, remounts, clears data/logcat, or deletes broadly), reverts the A/B override + relaunches even on Ctrl-C, and produces one ZIP + `report.txt`.
- **A/B summary reports only metrics each kernel can honestly provide.** Both harnesses parse the authoritative `backend_metrics=` line: ExoPlayer dropped frames as a real number (plus a per-event sum where the log supports it), MediaPlayer `dropped_frames=n/a` (never a fabricated `0`), with first-frame/prepared/stall/GC evidence and an explicit **PLAYBACK-NEVER-STARTED** flag (no first frame AND no prepared/ready) so an absent kernel is inconclusive, not a silent zero. The `.bat` gained a PowerShell summarizer mirroring the shell one.
- Host daemon unit tests extended (96 checks) covering the activity tri-state parser, the two-signal full-recovery verdict, the explicit terminal-token path, and the CLI-mode auth / no-reboot-reachability policy. No Android/Flutter behavior changed; the ELF ship gate and install/`pm` logic are unchanged.

## [v1.14.3] — 2026-07-12

- Fixed ExoPlayer and native MediaPlayer diagnostic snapshots so thread-confined player state is read on Android's main looper, with an explicit conservative timeout result instead of an unsafe nullable cast.
- Fixed native MediaPlayer synchronized start ordering on API 19: a requested start now waits for the asynchronous prepared seek to complete, while pause/release reliably cancel the latched start.
- Hardened root-daemon update/restart results: `pm install -r` now requires both a successful exit status and an exact trimmed `Success` line; app-restart acknowledgements report dispatch acceptance rather than completion and expose dispatch failure.
- Updated restart/update documentation and backend log labels to match the app-only restart contract; whole-device reboot remains a separate high-risk action.

## [v1.14.2] — 2026-07-12

- **Added a first-class native `android.media.MediaPlayer` video backend for the QZX_C1 / HiSilicon / YunOS 4.4.2 boxes, selectable A/B against the existing ExoPlayer path.** The hardware-only ExoPlayer (Media3) kernel can drop frames or black-screen on this legacy HiSilicon silicon; the native player drives the OEM's own Stagefright/OMX pipeline — the path the vendor firmware is actually tuned for — so it can succeed where the generic codec plumbing stalls. Both kernels now implement one `VideoBackend` contract; `PlayerController` became a thin facade that owns exactly one kernel plus the (decoder-independent) image + thumbnail paths, so the whole service/protocol layer is kernel-agnostic and every command (load/play_at/pause/resume/stop/seek/volume/playlist/status/heartbeat) behaves identically on both.
- **The native backend preserves the full command contract with no false-success acks.** It runs a real MediaPlayer state machine (Idle→Preparing→Prepared→Started/Paused→Completed/Error) with `prepareAsync` (never blocks the main thread), latches a synced-start (`play_at`) request so playback begins the instant preparation completes rather than acking early, primes the opening still frame while paused, honors single-item loop via `setLooping`, routes non-looping end-of-stream to the playlist auto-advance, guards every position/seek call against the illegal-state crashes MediaPlayer throws on 4.4, and binds/rebinds the `SurfaceView`'s `SurfaceHolder` across surface create/destroy.
- **Backend selection is explicit and observable, with a safe legacy default.** A new Settings radio (`视频内核 (A/B)` — auto / ExoPlayer / native MediaPlayer) persists the operator's choice; `auto` (the fleet default) resolves to the shipped-stable ExoPlayer path via the pure, unit-tested `BackendSelector` — nothing silently switches the fleet to the native path without real-device evidence, and there is exactly one knob (no `Build.MODEL` device-name branching). A `/data/local/tmp/lmw_video_backend` override file (a documented test affordance) beats the saved choice so the A/B tool can flip kernels without touching config. The live kernel + why (e.g. `mediaplayer(override)`) is reported in `status.video_backend`, the settings-screen playback line, and the diagnostic bundle.
- **A/B diagnostics record only metrics each kernel can honestly provide.** Per-kernel counters/timers (prepare latency, first-frame latency, buffering/stall events, completions, errors, video dimensions, and — ExoPlayer only — dropped frames) render one greppable line into the exported `player.log` and debug snapshot; the native player, which has no dropped-frame callback, reports `dropped_frames=n/a` rather than a fabricated `0`, and never exposes a decoder name so that stays `n/a` too.
- **One-action real-device A/B package (`scripts/qzx_ab_backend.sh` + `.bat`).** For each kernel it writes the override file, restarts the kiosk (the box replays its last pushed item via `resume_last`), lets it play, and pulls `player.log` (+ rotated), a logcat tail, and meminfo into one folder — then removes the override and relaunches so the box returns to its configured kernel. Read-only except the single override file and restarting the app itself, both reverted at the end; it never installs, reboots, or touches media/config.
- Host unit tests added for the pure selection policy (`BackendSelectorTest`) and A/B metrics honesty (`BackendMetricsTest`); the existing ExoPlayer diagnostics / hardware-only-selector behavior is unchanged.
- **Normal `restart` is now app-only and never warm-reboots the device (§restart-semantics).** Field ground truth on QZX_C1: a warm reboot leaves the 8822CS SDIO Wi-Fi card un-init'd (`mmc1: error -110 whilst initialising SDIO card`), `wlan0` never returns, and only a COLD power cycle recovers it — so rebooting to "restart" strands the box off-network. The controller `restart` now drives a new root-daemon `RESTART_APP` verb that force-stops + relaunches ONLY the Player app (preserving Wi-Fi + uptime) from a detached root worker that is not in the app's process group, so force-stopping the caller cannot kill the relaunch. Whole-device reboot is promoted to a **separate, explicitly-named high-risk `reboot` command** with a Wi-Fi-loss warning + confirmation in the controller. The daemon never silently falls back to reboot on restart/update.
- **Remote self-update (`update_app`) activates the new APK via PackageManager, without a whole-device reboot.** The old path overwrote `/data/app/<pkg>-1.apk` and rebooted so the boot scanner would adopt it — rejected because (a) the warm reboot bricks Wi-Fi and (b) overwriting the file behind PackageManager's back leaves the recorded `versionCode` stale (running dex new, platform still reporting the old version — not a verified update contract). The daemon now copies the sha256-verified APK to a world-readable stage (`/data/local/tmp/lmw_update_staged.apk`, 0644, since the app's `cache/update` dir is 0700-private and `system_server`/`installd` cannot read it), runs `pm install -r` (the platform-blessed atomic activation that re-dexopts, swaps, refreshes the recorded `versionCode`, and force-stops the app), and only on a `Success` reply does `RESTART_APP`. On `pm` failure it reports `failed:pm_failed:<detail>` and does NOT reboot.
- **Whether headless `pm install` works on YunOS 4.4.2 cannot be proven in a container, so a one-click real-device acceptance harness ships (`scripts/qzx_verify_update.sh` + `.bat`).** It drives the exact `pm install -r <staged>` the daemon runs and asserts the two properties that define the contract: the package `versionCode` CHANGED (new code activated, PM reports the new version) AND device uptime did NOT reset (no whole-device reboot). Protocol/daemon/RootInstaller/Flutter controller tests updated for the `RESTART_APP` verb and the reboot/restart split.

## [v1.14.1] — 2026-07-12

- **Fixed the QZX root daemon failing to start on the real Android 4.4.2 / API19 box** (`CANNOT LINK EXECUTABLE: cannot locate symbol "signal" referenced by "/system/xbin/lmw_root_daemon"`). Root cause: the v1.14.0 workflow compiled the daemon `-fPIE -pie` (a **dynamic** PIE), so at exec time the loader had to resolve libc symbols against the device's bionic — and API19 bionic never exported `signal` (old `<signal.h>` made it a static-inline shim over `bsd_signal`). The daemon therefore never linked, and remote restart/update were dead.
- The daemon is now built **fully static + non-PIE** (`-static -fno-PIE`). A static binary carries its own libc, so there is nothing to resolve against the device bionic — it runs identically on API19..current and the "which API level exports which symbol" question is moot for every syscall wrapper. On the NDK, `-static` already produces a classic non-PIE `ET_EXEC` (static-PIE would need an explicit `-static-pie`) and `-fno-PIE` fixes codegen to match, avoiding the static-PIE loader path (unreliable on 4.4 kernels); a bare `-no-pie` is intentionally omitted because, under `-static`, the clang driver flags it as "argument unused during compilation" and `-Werror` fails the build. The NDK's min API is 21, so it compiles with the api21 clang (headers only) but links static.
- Replaced `signal(SIGPIPE, SIG_IGN)` with `sigaction()` (a real bionic export since API1) at the source, so even a dynamic build would no longer reference the missing `signal` symbol. SIGPIPE stays ignored — a client that hangs up mid-reply cannot kill the daemon.
- Added a **build-artifact ship gate** (`scripts/check_daemon_elf.sh`) wired into the Android workflow: it fails the build unless the produced armv7 daemon is fully static (no `PT_INTERP`, no `DT_NEEDED`) and free of API19-unsafe undefined dynamic symbols (`signal`/`dprintf`/`vdprintf`). A host regression test (`scripts/tests/test_check_daemon_elf.sh`) proves the gate rejects a dynamic `signal()` binary and accepts a static one, so the field-failure class can never ship again.
- **Cold-boot persistence is now evidence-based and honestly reported.** This ROM ships no `/system/etc/init.d` and no `install-recovery.sh`, so v1.14.0 silently wired nothing. `lmw_setup.sh` now installs a root boot hook ONLY where the ROM's own `init*.rc` demonstrably runs it: a run-parts-wired `init.d`, or an `install-recovery.sh` path an init service already execs as root (created if the ROM references it but the script is absent — a real ROM-sanctioned hook, never a fabricated init.rc edit). The completion summary now separates "daemon PROBE-verified for THIS boot" (remote restart/update live now) from "cold-boot persistence proven" (a real-device reboot + re-probe acceptance gate), and never claims persistence it cannot show offline. `lmw_restore.sh` removes the hooks it created; `lmw_audit.sh` reports which boot-hook mechanisms the ROM actually supports.

## [v1.14.0] — 2026-07-11

- Replaced the setuid root helper with a **root-started local daemon** (`scripts/lmw_root_daemon.c`, `lmw_root_daemon`). On QZX_C1 / YunOS 4.4.2 the box exposes root to adb, but zygote sets `no_new_privs`, so a setuid bit on an app-exec'd binary is ignored — the app keeps `euid=10020`. The daemon is started as root by provisioning, stays root, and exposes a restricted abstract AF_UNIX socket (`@lmw_root_daemon`).
- The daemon authenticates every connection with kernel peer credentials (`SO_PEERCRED`) against a root-owned uid file, accepts only `PROBE` / `REBOOT` / `INSTALL <canonical-path>`, installs only the single canonical cache/update APK path (`O_NOFOLLOW` + regular-file + non-empty checked), copies atomically (temp + fsync + rename + `system:system` 0644), and never executes a shell.
- `RootInstaller` is now a thin `LocalSocket` client of the daemon; the app-side `su`/setuid fallback was removed because it never worked on the target and only added misleading complexity. The pure wire protocol lives in `RootDaemonProtocol` (unit-tested).
- ExoPlayer now selects **hardware video decoders only** via a `MediaCodecSelector` that excludes `OMX.google.*` / `c2.android.*` / API-reported software-only codecs (audio is untouched). When no hardware video decoder exists, playback fails explicitly and logs the reason instead of silently decoding in software. Exported logs record the selected decoder name, hardware/software classification, init duration, and input format.
- Active video playback can no longer trigger recurring `MediaMetadataRetriever` frame extraction: the controller memoizes one thumbnail per item and the thumbnail loop reuses the cache or suppresses extraction while a video is actively playing, so it never opens a second decoder alongside ExoPlayer's live HiSilicon decoder.
- `lmw_setup.sh` / `lmw_setup.bat` now push + install + immediately start the daemon, verify it over its own `-probe` protocol (requires `ready ... daemon_euid=0`), install a ROM-supported cold-boot hook (`/system/etc/init.d`, else an existing `install-recovery.sh`), and only write the completion marker after the protocol probe succeeds. CI builds the armv7 daemon, runs the host daemon unit tests, and packages the daemon (not the old helper) into the QZX update tools zip.

## [v1.13.15] — 2026-07-11

- Moved Android video output from `TextureView` to `SurfaceView`, allowing legacy HiSilicon hardware decode to use the HWC/overlay path instead of forcing every frame through Mali composition.
- Preserved controller thumbnails by extracting low-frequency frames asynchronously from the local cached video; extraction is single-flight and failures retain the previous thumbnail without blocking playback.
- Added ExoPlayer dropped-frame timing diagnostics to exported player logs.
- ~~Moved the setuid root bridge from `/data/local/tmp` (the target mounts `/data` with `nosuid`) to `/system/xbin/lmw_root_helper` and added a real runtime probe requiring the application caller to reach `euid=0`.~~ **Superseded by v1.14.0**: the setuid helper is ignored under zygote `no_new_privs` on these boxes and was replaced by the `lmw_root_daemon` root-started local daemon.
- ~~Remote reboot and pushed APK installation now share the same verified root bridge and force a fresh probe before executing.~~ **Superseded by v1.14.0**: both now route through the root daemon over its local socket.

## [v1.13.14] — 2026-07-11

- Fixed QZX helper provisioning: the on-box script no longer copies the pushed `.new` helper onto itself, which caused `cp: ... No such file or directory` on the target shell.
- Re-running setup with a leftover installed phase now skips the obsolete reboot wait and proceeds directly to verified completion.
- Replaced the KitKat-incompatible `stat` verification in the Windows wrapper with an on-box completion marker; failed provisioning can no longer print `DONE`.

## [v1.13.13] — 2026-07-11

- Android 4.4 video thumbnails keep using direct 320px `TextureView` readback, now reuse one small bitmap, run single-flight, and capture every 15 seconds during legacy video playback to reduce GPU synchronization and Dalvik allocation pressure.
- Exported `player.log` records thumbnail readback/JPEG timing, heap use, media transitions, position discontinuities, and first-frame intervals so loop-boundary stalls can be separated from decoder failures.
- Activity teardown releases the old ExoPlayer, codec, surface, and thumbnail allocation instead of leaking them across recreation.
- Controller discovery fills missing announce IPs from the UDP datagram source, merges IPs into connected wall devices, and always displays them on device cards.
- The landscape device-pane action bar uses labelled stacked controls instead of squeezing three buttons into circular-looking icons.
- QZX setup now fails on every helper provisioning error and verifies numeric `root:<app gid>` ownership, setuid/setgid mode, and the root-owned UID file. The Windows wrapper propagates both setup phase failures.

## [v1.13.12] — 2026-07-11

- Android thumbnails capture directly at a maximum width of 320 pixels, avoiding recurring 1920x1080 Java bitmap allocations and GC pauses during playback.
- Status reports the structured active playlist separately from cache inventory. Orchestration can load a connected device's playlist, reorder/delete entries, and apply it back without claiming cache-file deletion.
- Restart ACKs now wait for helper-first / `su` fallback execution and report failure truthfully.
- Kiosk setup fails if the filesystem strips the root helper's setuid/setgid mode, and PC setup verifies the installed mode.

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/); main commits produce verified CI artifacts and version tags promote the matching commit's artifacts to a Release.

## [Unreleased]

## [v1.13.11] — 2026-07-10

### Fixed
- **黑屏假成功不再被吞(B1 根因)**:`PlayerService` 过去从**未订阅** `PlayerController.onPlayerError`,ExoPlayer 报解码错误(如 `OMX_ErrorStreamCorrupt`)时 `playState` 仍无条件停在 `"playing"`,控制端看到的是「推送成功、播放正常」的假象,黑屏无从感知。现在 `onPlayerUiReady()` 幂等接线 controller,错误一发生即:①即时写导出的 `player.log`(不再等 watchdog 5s 后才记一条泛化 `player:X`);②推进 `errors` 队列;③把 `playState` 翻成 `"error"` 让 §5 status 如实上报。watchdog 恢复逻辑同步识别 `playState=="error"` 作为触发,5s 兜底恢复不受影响。
- **重启/预取恢复跳过 SHA 校验(B2 根因)**:`Downloader.restoreReadyFromDisk`(重启恢复)与 `ensureEntryAndStart` 的 `quickOk` 捷径(预取命中旧文件)过去**只比 size** 就把文件标 `ready`,一个被截断/损坏但长度恰好相符的文件会被当可播,ExoPlayer 拿到坏码流吐 `OMX_ErrorStreamCorrupt` → 黑屏。两处同源路径现在:item 带 `sha256` 时恢复前必须校验通过才认 `ready`,不符则删文件回退完整下载;仅在 item 无 sha256(无法校验)时保留 size-only 旧行为并显式记 `UNVERIFIED`。

### Diagnostics
- **播放端诊断日志进导出包**:`PlayerController` 新增 `logSink`,用 ExoPlayer `Player.Listener` 记录状态转移(`BUFFERING/READY/ENDED`)、**首帧渲染**(`onRenderedFirstFrame` — 「解码成功但黑屏」的决定性信号)、分辨率(`onVideoSizeChanged`)、`onPlayerError` 的 `errorCodeName`+`cause`,以及每次 load 的**源描述**(本地缓存文件名/大小 vs 远端 URL)。`Downloader` 新增 `logSink` 记录 cache 命中来源(全新网络下载 vs 磁盘恢复 vs 预取命中)、SHA256 是否执行与结果。全部经 `PlayerService.logEvent` 落到**导出的 player.log**,不再只进被 4.4 盒截断的 logcat —— 这正是上次黑屏回归查不到根因的盲点。
- **控制端出站日志**:P2P `_sendTo` 成功写入活连接时记 `msgId`+payload 摘要(playlist_id/item 数/start_index 等对账锚点),`send()` 记扇出 `delivered/targets`。过去只在失败分支记日志,推送成功但黑屏时控制端日志一片空白,无法比对「控制端以为发了什么」vs「播放端实际收到/播了什么」。日志汇入既有 `logLines`,可在设置页一键复制。

## [v1.13.10] — 2026-07-10

### CI
- **发布流程改为一次构建、tag 晋级**:`main` 的每个精确 SHA 固定运行 `ci`、Flutter、Android、Windows、Broker 五条门禁并产出 8 个候选制品；`v*` tag 只允许 `release-promote` 查找同 SHA、main push、成功状态的 run，下载并晋级候选制品，不再重跑 Flutter/Gradle/PyInstaller 构建。
- **发布可追溯合同**:晋级器严格要求 8 类 artifact 每类恰好一个非空文件，验证 tag 与 `pubspec.yaml` 版本一致，按正式名称复制后生成并复验 `SHA256SUMS`；Release 附带 `RELEASE_PROVENANCE.json`，记录 tag、完整 commit SHA、版本/build 与五条 workflow run ID。缺失、重复、过期或 SHA/版本不匹配均中止发布。
- **流程回归测试纳入云门禁**:`ci.yml` 新增 `release-contract` job，持续验证构建 workflow 不响应 tag、晋级 workflow 不包含编译命令，以及五条同 SHA 门禁和 checksum 合同不可被意外绕过。

## [v1.13.9] — 2026-07-10

### Fixed
- **P2P 被无效 Broker 配置锁死**:控制端把历史设置中的 `0.0.0.0` / `::` 当作远端 Broker 地址，导致 UDP 虽能发现设备，却持续拨号通配监听地址并永远不进入 P2P。现在加载和保存设置时自动清除此类非法远端地址，发现设备后正常切入 P2P；设置页也明确区分监听地址与可拨号地址。
- **未投递命令不再假成功**:`BrokerClient.send` 返回真实连接层写入结果；Broker 未连接时 `WallState` 抛出可见错误，新建、编辑、删除分组和设备配置均向用户显示失败，不再静默丢弃。

## [v1.13.8] — 2026-07-10

### Fixed
- **P2P 目标隔离**:组目标匹配为空时不再回退广播全部已连接设备;普通发送返回成功写入活连接的目标数(不是设备执行 ACK),同步起播零目标直接报错,控制端只在连接层投递成功后显示成功。此安全合同取代 v1.10.5 引入并在 v1.11.0 保留的“空目标广播全部直连设备”兜底。
- **升级状态贯通**:P2P `update_status` 接入 `P2pCoordinator → WallState`;Broker wall 快照的 `update_state/update_detail/update_version_code` 由 `DeviceStatus` 解析后汇入同一状态缓存,两种拓扑的下载、校验、安装与失败阶段都不再丢失。
- **Windows P2P 同步起播**:`ready` 的立即、缓存就绪和超时三条分支都回显 `prepare_id/group_id`,控制端可以匹配会话并下发 `play_at`。
- **Windows 诊断合同**:实现定向 `debug_snapshot/download_logs` 处理和有界诊断回包,并把 Windows 纳入发布合同矩阵。
- **Windows 版本上报**:移除 `hello` / 诊断中的硬编码 `1.0.0`,开发态和 PyInstaller 包都从版本单一真相源 `remote_flutter/pubspec.yaml` 读取。

### CI
- Android 云构建在 `assembleRelease` 前强制执行 `testDebugUnitTest`;单测失败不再产出发布 APK。

## [v1.13.7] — 2026-07-09

### Fixed
- **遥控物理主页键真正回到媒体墙(QZX_C1 / Hi3798MV300 / HiSTBAndroidV6,Android 4.4.2)—— 根因修复**: 此前 HOME/launcher 能力挂在 `activity-alias`(`.HomeAlias`,`targetActivity=".MainActivity"`)上。真机验证链锁定根因:这批 HiSilicon/YunOS 4.4 阉割固件的 `PackageManager` **不把 `activity-alias` 注册进隐式 `category.HOME` 解析表** —— 即便组件已 `pm enable`、已断电重启、`dumpsys activity activities` 显示 HomeAlias 已被系统当 HOME 坐进 HOME 栈(`mOnTopOfHome=true` / `STACK_STATE_HOME_IN_BACK`)、显式 `am start -n .../.HomeAlias` 也能拉起,但 `am start -a MAIN -c android.intent.category.HOME` 始终 `unable to resolve Intent`,物理主页键 / `input keyevent 3` 从其他 App 回不到墙。**修法**:把 `category.HOME` + `category.DEFAULT` 从 activity-alias 迁到**真正的 Activity**(`MainActivity` 的 intent-filter,与 `MAIN` + `LAUNCHER` 并列),删除 `.HomeAlias` 别名。4.4 的 stock PackageManager 认可真 Activity 作为隐式 HOME 候选;配合已禁用的 OEM 桌面(youku SLauncher),`MainActivity` 成为唯一 `CATEGORY_HOME` 目标,遥控主页键直达媒体墙。
- **`lmw_setup.sh` 的 `bind_home` 改用可用路径**: 4.4 阉割盒无 `cmd package set-home-activity` / `resolve-activity`,原调用永远失败。改为 `pm clear-preferred-activities` + 触发 HOME intent + `dumpsys activity activities` 校验落栈,并在无法从 shell 确认时提示按一次遥控主页键(MainActivity 现声明 category.HOME,OEM 桌面已禁用,必落回墙)。

### Removed
- **播放端设置页「设为桌面(kiosk 兜底)」开关及其 activity-alias 运行时切换逻辑**: HOME 能力现在恒定挂在 `MainActivity` 上(专用媒体墙盒抢 HOME 即预期行为),不再需要运行时开关。移除 `SettingsActivity` 的 `isHomeAliasEnabled` / `setHomeAliasEnabled` / `HOME_ALIAS` 常量、布局 `input_set_as_home` CheckBox、`label_set_as_home` / `hint_set_as_home` 字符串(中英)。

## [v1.13.6] — 2026-07-09

### Changed
- **QZX/YunOS 盒子运维脚本整合为单一 `lmw_setup`(装升级 + 清理一体)**: 原先分离的 `lmw_update.bat`(装升级)+ `lmw_provision.sh`(ON-BOX 相位状态机,含写死 CLEANLIST)合并为 `scripts/lmw_setup.bat` / `lmw_setup.sh`。一条 PC 命令完成:推 APK+helper+脚本 → 装/升级 player(桥接一次重启)→ arm 推送升级 helper → **禁用媒体墙之外的一切程序** → 设媒体墙为默认桌面,直到 `SETUP COMPLETE`。清理改用**动态白名单**(硬白名单 = OS 地基 + player,其余全禁),取代写死清单,未来新增 bloat 也会被自动扫掉且绝不误伤系统件。参数:`FORCE` / `NOCLEAN` / `KEEPDEBUG` / `NOUNINST`。
- **推送升级 helper 修复路径明确化**: `install-failed` 的根因是盒子上 arm 的是旧版 `lmw_root_helper`,而推送升级架构上永远碰不到 helper 自身(只往 `/data/app` 丢 APK)。`lmw_setup.bat` 每次都重新推送 + 重新 arm 当前 CI 编译的 helper(带 reboot 支持),这是修好 `install-failed` 的唯一路径。
- **新增只读盘点与还原脚本**: `scripts/lmw_audit.bat` / `.sh`(toybox 安全的只读盘点)、`scripts/lmw_restore.bat` / `.sh`(动态 `pm enable` 把禁用项全部启用回来)。工具说明见 `scripts/QZX-KIOSK-TOOLS.md`。
- **CI 工具包更新**: `android-build` 的 `QZX-Update-Tools.zip` 改为打包 `lmw_setup` / `lmw_restore` / `lmw_audit` + `QZX-KIOSK-TOOLS.md` + `lmw_root_helper`,移除已废弃的 `lmw_update.bat` / `lmw_provision.sh`。

### Fixed
- **远程日志下载 / 调试快照在 broker + P2P 两种模式下真正闭环**: v1.13.4 引入的功能此前只有控制端与 Android 被控端实现,转发层是断的 —— (1) `broker.py` 的 dispatch 表缺 `download_logs` / `debug_snapshot` / `diagnostic_status` / `download_logs_result` 四个类型,handler 为 None 直接丢弃,broker 模式下请求到 broker 就没了、被控端回传也不转发回控制端 → 必然 30s 超时;(2) P2P 模式下 `P2pCoordinator._onText` 的 switch 没有 `diagnostic_status` / `download_logs_result` 分支,落入 default「忽略入站类型」,同样导致控制端挂起的 completer 永远收不到结果。现在 broker 把两类请求扇出给目标被控端、把两类结果广播回控制端(带 `role=="player"` 校验防伪造);P2P 侧新增 `onDiagnostic` / `onLogDownload` 回调,喂回与 broker 路径相同的 pending completer。新增 `broker/tests/test_debug_routing.py`(5 例)守护双向转发不再回退。

## [v1.13.3] — 2026-07-08

### Fixed
- **`restart` 改为重启整台盒子**: 单台设备面板里的 restart 不再只重启播放软件/服务,Android player 收到 `restart` 后优先调用 provision 过的 `lmw_root_helper reboot`,再回退 `su -c reboot`。若两条 root 路径都失败,只记录 `restart:reboot-failed`,不杀掉当前播放端进程,避免 QZX/YunOS 上 alarm/自启不可靠导致播放墙彻底起不来。

### Changed
- **版本单一真相源升到 `1.13.3+35`**: patch release 专用于把控制端按钮、协议注释、broker 转发说明、Android helper 与 README 统一到“重启整台设备”语义。

## [v1.13.2] — 2026-07-08

### Fixed
- **QZX/YunOS 新盒子 IP 显示与发现慢/失败**: Android player 的局域网 IP 探测从只依赖 `NetworkInterface` 改为 Java 枚举优先,再回退 `dhcp.wlan0.ipaddress` / `dhcp.eth0.ipaddress` / `netcfg` / `ip addr`;命中后短缓存,避免状态循环反复跑 shell。修复真机 `wlan0=10.10.8.137` 但 UI 显示 `0.0.0.0:8770` 的问题。
- **Android 4.4 UDP discovery bind 兼容**: `Discovery` 由 `DatagramSocket(null)+InetSocketAddress(port)` 改为旧 Android 更稳的 `DatagramSocket(port)` 绑定路径,修复 `UDP discovery bind failed on 8772: IllegalArgumentException: port=-1`。
- **旧盒子重启后不恢复播放**: `PlayerService.resumeLast()` 在 `MainActivity` / `PlayerController` 尚未就绪时不再丢掉恢复机会;Activity 创建好播放控制器后主动通知 Service 再执行一次 `resume_last`。
- **QZX HOME/主页键绑定**: provision 脚本在绑定默认 HOME 前显式 `pm enable com.jieoz.lanmediawall.player/.HomeAlias`,避免设置里曾关闭 HomeAlias 后禁用原厂桌面导致主页键无解析目标。
- **控制端删除播放端**: 单台设备面板新增“从控制端移除”,清本机发现缓存、P2P 连接、聚合状态、缩略图和占位卡;不卸载盒子端 App,后续重新广播/扫码/手动添加仍可回来。
- **P2P 模式新建组不显示**: 无 broker 时控制端本地聚合器原先只从设备状态反推分组,空组没有注册表可落,所以“新建组”像没生效。P2P 侧现在维护本地 group meta,`create_group` / `update_group` / `delete_group` 会立即更新本地 wall snapshot,空组也能显示。

### Changed
- **版本单一真相源升到 `1.13.2+34`**: patch release 覆盖两台 QZX/YunOS 盒子的网络发现/恢复播放/HOME 绑定问题,并给控制端补设备移除入口。

## [v1.13.1] — 2026-07-08

### Fixed
- **QZX/YunOS 播放端推送升级失败**: 针对盒子 stock `su` 拒绝普通 App UID(`su: uid N not allowed to su`)导致 `update:install-failed` 的根因,新增一次性 PC/ADB root 引导的 `lmw_root_helper`。`lmw_update.bat` 会把 helper 推到盒子并按 Player Linux UID 设为 root-owned setuid helper;之后 Player 收到 `update_app` 时优先调用 helper 完成 `/data/app` 覆盖+reboot,不再依赖 App 直接 `su`。
- **Release 工具包资产**: `android-build` 云编译现在同时编译 ARM helper,打包 `lmw_update.bat` / `lmw_provision.sh` / `lmw_root_helper` 为 `LANMediaWall-vX.Y.Z-QZX-Update-Tools.zip`,并挂到正式 GitHub Release。用户仍只安装一个 Player APK;helper 是脚本工具包里的辅助二进制,不是第二个 APK。

### Changed
- **版本单一真相源升到 `1.13.1+33`**: patch release 专用于推送升级修复;versionCode +1 保证被控端把新版 APK 识别为可升级目标。

## [v1.13.0] — 2026-07-07

### Added
- **单台设备面板 · 四控(遥控端)**: 设备墙里单击一台盒子的详情弹窗,除既有改名/设组/音量/推送升级外,新增只针对**这一台 `deviceId`** 的操作:①**单台播放控制**——暂停/恢复/停止(`WallState.pause/resume/stop(deviceId:)`,`remote_flutter/lib/ui/device_wall_pane.dart`);②**单播推送内容**——复用编排上传+下发逻辑,目标锁定单台(playlist/prepare-play 走单播);③**状态/版本一览**——内部 `_DeviceStatusView` 展示 `DeviceStatus` 的应用版本(`appVersion`)/在线相位/当前播放项/缓存态/组/音量;④**restart 按钮**(带二次确认)。协议侧 `messages.dart` 新增 `DeviceStatus.appVersion` 字段(+`fromMap` 解析)与 `Commands.restart(...)`,状态侧 `wall_state.dart` 新增 `restart({groupId, deviceId})`。
- **`restart` 命令(Android player 后端)**: `PlayerService.kt` 命令白名单新增 `"restart"` → `hRestart` 分支,**重启播放软件(重进播放墙,非整机 reboot)**;配合 v1.12「重启自动恢复播放」按 last_task 从磁盘内容寻址续播。
- **HOME/SETUP 物理键回播放墙(Android player)**: QZX_C1 等盒子的物理「回主页」键实测发的是 `KEY_SETUP`=`KEYCODE_SETTINGS`(176) 而非 `KEY_HOME`(真机 `getevent` 实证)。`MainActivity.onKeyDown` 新增 `KEYCODE_SETTINGS` 分支:消费该键(不弹系统设置/不漏进播放器)并 `goToWall()` 把播放墙(`MainActivity`,`launchMode=singleTask`)以 `FLAG_ACTIVITY_REORDER_TO_FRONT | SINGLE_TOP` 重新拉到前台;`KEY_HOME` 仍由 `HomeAlias`(category HOME)兜底——**双键兜底**,哪种键位的盒子都能回墙。

### Changed
- **版本单一真相源升到 `1.13.0+32`**: 改 `remote_flutter/pubspec.yaml` 的 `version:` 一行即全端同步——控制端 APK 由 CI `--build-name/--build-number` 派生,播放端 `android_apps/player/app/build.gradle.kts` 在 Gradle-config 时读同一行派生 `versionName/versionCode`,不在 Gradle 里硬编码版本。

## [v1.12.0] — 2026-07-07

### Added
- **P2P 缩略图**: 把 `thumb_meta`(JSON 文本帧)+ 紧跟二进制 JPEG 帧的两帧配对逻辑抽成共享纯 Dart `ThumbPairing` 状态机(`remote_flutter/lib/protocol/thumb_pairing.dart`),broker 直连与 p2p 直连两路复用同一实现(无分叉)。此前 p2p 路径把 `thumb_meta` 丢进 `default` 分支直接丢弃,是「P2P 看不到设备墙缩略图」的根因。`ws_link` 新增 `binaryStream`(广播流拆 text/binary),`wall_state` 接 `onThumb`。
- **P2P 断线主动重连**: p2p 协调端断线后按指数退避(1s→30s)主动重拨同一端点,连上清退避;重连前检查端点是否已有活连接(去重防双连接),对端从发现列表移除后不再重连。补 `fakeAsync` 单测覆盖「drop→退避→重拨、不双连接」与「已移除端点不重连」。
- **重启后自动恢复播放(Android player)**: `Downloader` 启动时按 last_task playlist 从磁盘按内容寻址文件名(`$sha256.$ext`)重建 ready 索引,`readyPath` 重启后命中本地已缓存文件而非回退到已失效的临时媒体 url。纯读、幂等,不额外写盘。
- **升级入口可发现性(遥控端)**: 顶部远程更新按钮从纯图标 `IconButton` 改为带「更新固件」文字标签的 `OutlinedButton.icon`;单设备详情弹窗新增「推送升级」入口,走同一 `update_app` 流程但 target 预锁定该台(`_remoteUpdateDialog` 加可选 `lockDevice`),协议与下发逻辑不变,仅改可达性。

### Fixed (红线)
- **假容量闪存写安全**: 扩容/假容量盒子 `df` 上报的巨大剩余空间不可信。`CacheEviction.effectiveQuota` 重构为 `min(configuredMax, 保守绝对上限 2GiB)`,空间百分比只能往下收紧、绝不把配额抬到硬上限之上;`Downloader.probeWritable()` 下载前做真实可写探针(小文件写+fsync+读回+删,每 prefetch 批次一次,低频);`Downloader.reclaimOrphans` + `MediaStore.pruneAndListReferenced` 投新内容前主动回收不再被最近 N 条 playlist 引用的孤儿媒体,保护当前 playlist/`.part`/last_task 引用文件不误删。防止持续写穿真实闪存颗粒把盒子写坏变砖。补 `CacheEvictionTest` 假容量钳制/百分比只下调/孤儿保护单测。

### CI
- **修复控制端 release 签名注入**: 生成的 `android/app/build.gradle` 用 `signingConfig = signingConfigs.debug`(带 `=`)的新式写法,但 flutter-build 的签名注入正则只匹配旧的无 `=` 空格写法,导致 release keystore 从未接线、APK 一直被 debug 签名,卡在「Verify APK signing identity」门禁。正则改为容忍可选 `= `,替换文本也用 `=` 形式,固定签名恢复生效(跨版本覆盖升级依赖它)。

## [v1.11.2] — 2026-07-07

### Fixed
- **控制端完全搜不出播放端的 UDP 发现断点**: Android 播放端 `Discovery` responder 构造时已经拿到了实际 `authMode/keyMode`(P2P/零配置为 `open/global`),但处理 `discover` 时调用 `Envelope.verify(...)` 没有把这两个参数传进去,导致实际走默认 `REQUIRED` 验签。控制端零配置发现包是空签名 open discover,因此被播放端静默丢弃,表现为控制端周期广播但设备列表为空。
  - 修复: `Discovery.handle()` 按当前 `authMode/keyMode` 验 discover,open 模式正确接受空签名;同时补 `DROP discovery inbound`、`RX discover`、`TX announce` 与 UDP bind 日志,以后 logcat 能直接看出发现包到没到、为何丢、有没有回 announce。
- **Player APK 文件名版本与包内 versionName 漂移**: `v1.11.1` tag 的 Release 文件名是 `LANMediaWall-v1.11.1-Player-Android.apk`,但 Android player 的 `build.gradle.kts` 仍硬编码 `versionName="1.11.0"` / `versionCode=28`,所以盒子无论怎么覆盖安装,`dumpsys package` 都只会显示 `1.11.0`。
  - 修复: Android player 版本号改为从 `remote_flutter/pubspec.yaml` 的 `version: X.Y.Z+N` 派生,controller/player/tag 使用同一真相源;中文设置页补上 `版本:vX.Y.Z (build N)` 显示。

## [v1.11.1] — 2026-07-07

### Fixed
- **P2P「②推送并播放」ACK 正常但不起播的栅栏透传缺口**: 控制端 UI 已按 §21 调用预缓存栅栏,但 P2P 本地编排路径只把 `readyTimeoutMsOverride=120s` 传给协调器,实际发给被控端的 `prepare` 没有携带 `prefetch:true` / `barrier_timeout_ms`。Android 端因此走普通 prepare 分支:首项未缓存时会立刻 `ready:false`,协调端继续等到超时且无就绪目标,最终不下发 `play_at`；日志表面只有 `playlist/cache_prefetch/prepare/resume` ACK,看起来像“功能异常”。
  - 修复: `Commands.prepare` 支持 `prefetch` 与 `barrier_timeout_ms`; `WallState.prepareWithBarrier` 在 P2P 下通过 `P2pCoordinator.startSync(... prefetchBarrier:true ...)` 透传到被控端。Android 端收到后进入已有后台缓存等待逻辑,缓存完成再回 `ready:true`,随后协调端下发 `play_at`。
  - 诊断增强: 控制端现在记录 `ready:false`、ready 命中数量、未匹配 ready 的 `prepare_id` 与最终 `play_at` 下发日志。以后同类问题不再只剩 ACK 盲区。
  - 回归: 新增协议层 `Commands.prepare(prefetch)` 测试与 P2P 栅栏测试，覆盖“携带栅栏参数”和“ready=false 不应点火”。

## [v1.11.0] — 2026-07-06

### Fixed (CRITICAL — 两个根因,真机 logcat + 控制端诊断逐字确认)

- **推送后黑屏 + 设备墙同一盒子双卡的真根因:peer 身份命名空间从不归一(根治)**。
  扫码/手动添加盒子时控制端没有真实 `device_id`,`P2pCoordinator` 用拨号端点 `host:port`
  (如 `10.10.8.160:8770`)当占位 key 建连接;而盒子 `welcome`/`status` 上报的**真实
  device_id**(如 `and-b87bfc8e49`)走另一命名空间。后果链:`connectedIds` 返回占位 key、
  `WallAggregator`/`GroupExpander` 用真实 id → 组扇出求交集恒为空(只能靠 v1.10.5 兜底硬发
  prepare);握手会话目标集是占位 key,播放端 `ready` 带真实 id → `targets.contains()` 为
  false → **`play_at` 永不下发 → 黑屏**;设备墙同时出现「占位卡(恒连)」+「真实卡(随
  status 时断)」两张。
  - 修复(归一,不在兜底上雕花):连接一旦从帧里拿到真实 device_id(`status`/`ready` 的
    `payload.device_id`,或 `welcome` 的 `from=player:<id>`),就把 `_links`/`_subs`/`_peers`
    的键从占位 key **重绑定**到真实 id(`_maybeRebind`/`_rebind`),打印 `身份归一: 占位 key
    "host:port" → 真实 device_id "<id>"`。归一后 `connectedIds` 与聚合/扇出同命名空间:组扇出
    正常命中(不再靠兜底)、握手目标集用真实 id → `ready` 匹配成功 → **`play_at` 正常下发,
    不再黑屏**。
  - 边界:重绑定去重(真实 id 已有连接则关旧留新)、`setPeers` 改为**按端点(host:port)对账**
    以免把已归一的活连接误断重拨、所有 link 回调用 `_keyForLink` 反查当前 key(不闭包捕获占位
    key)避免孤儿连接。控制端 `WallState` 登记占位→真实别名,`wallDevices` 据此把占位卡折叠
    进真实卡:**同一盒子只剩一张卡**。
  - **v1.10.5「group 匹配为空 → 回退全部已连接」兜底保留**(多组场景 / 归一前窗口期保险),
    归一后正常路径优先命中,不再是唯一能推图的路径。

- **每版必须卸载重装、远程 `update_app` 必失败的真根因:release 签名指纹每版都变(根治)**。
  player 的 `release` buildType 此前用 `signingConfigs.getByName("debug")`,CI 每次用 AGP 临时
  生成的 debug.keystore 签名 → **每版证书指纹不同** → 覆盖安装 `INSTALL_FAILED_UPDATE_
  INCOMPATIBLE` → 只能卸载重装,§23 远程 `update_app` 也必然失败。
  - 修复:player 从 GitHub Actions Secret 解码**固定 keystore** 签名(参照遥控端
    `flutter-build.yml` 的成熟流水线)。`build.gradle.kts` 新增 `release` signingConfig,凭据从
    CI 写出的 `key.properties`(指向 `$RUNNER_TEMP` 的 keystore)读取,release buildType 用它
    替换 debug;保留 v1+v2 签名(minSdk 19 必须 v1)与 R8/minify 不动。`android-build.yml`
    在 build 前 `if` 判断 secret 存在 → `base64 -d` 写 keystore + `key.properties` →
    `assembleRelease`,并回显 signer 证书 SHA256 供真机核对。
  - **无 secret 优雅降级**:fork PR / 本地无 secret 时回退 debug 签名出可安装 APK,构建不失败。
  - **安全**:公开仓,keystore/密码明文绝不入库——只用 `${{ secrets.X }}` 与 `$RUNNER_TEMP`;
    `key.properties`、`*.keystore`、`*.jks` 均 `.gitignore` 排除。固定证书 SHA256 指纹
    `69:EC:70:E5:92:AE:D4:6C:4E:B1:41:2F:E7:66:8F:41:51:46:81:10:1A:CD:0D:D9:DB:B0:98:D1:E2:6D:6D:54`
    (30 年有效)。**装 v1.11.0 后从 v1.10.x 覆盖安装无需卸载,远程 update_app 可覆盖升级。**

## [v1.10.7] — 2026-07-06

### Fixed
- **P2P 直连也能远程更新 APK**: 控制端「远程更新固件」不再限制 broker 模式。broker 下仍上传到 broker 媒体库;P2P/无 broker 下复用控制端本机临时 HTTP 服务生成 APK 下载 URL+sha256,再通过 P2P `update_app` 下发。播放端授权规则同步调整:broker 帧仍需 HMAC 鉴权,P2P 直连控制链路可作为本地操作者授权,但版本严格递增、sha256 校验、同签名平台校验和 root `/data/app` 安装流程不变。
- **P2P 普通下发不再被 group 目标扇空吞掉**: 继 `prepare/startSync` 后,普通 `playlist`、`cache_prefetch`、`set_volume` 等 `send(group:...)` 也加上同样的已连接兜底。真机日志里 `startSync ... targets=[] → 回退到 1 台` 后播放端虽能收到 `prepare`,但前置 `playlist/cache_prefetch` 仍显示 `无目标` 并被丢弃,导致播放端没有媒体清单/下载任务。现在 group 匹配为空但确有直连设备时直接回退到全部已连接,并打印 connected/devices 诊断值。
- **远程自更新 broker 主链路接通**: broker 现在转发 `update_app` 到某台/某组/全部目标,并把被控端 `update_status` 合并进设备墙状态(`update_state/update_detail/update_version_code`),避免控制端下发后被中枢静默丢弃。
- **媒体上传 token 与远程更新兼容**: broker 开启 `media_upload_token` 后,控制端设置页可填写同一 token,本地媒体/APK 上传会带 `Authorization: Bearer ...`;下载仍对被控端开放。
- **远程更新目标补齐单台选择**: 控制端「远程更新固件」支持全部/分组/单台三种目标,并在无可选目标时明确提示。

## [v1.10.5] — 2026-07-05

### Fixed (CRITICAL — 一张图都推不出去的真根因)
- **扫码直连盒子后「推送并播放」零反应**: 真机确认盒子在设备列表里、WS 连上、status/thumb_meta 持续上报,但盒子日志**从无 `RX prepare`**,控制端诊断显示 **`p2p prepare → 0 台`**。根因:`P2pCoordinator.startSync` 用 `GroupExpander.expand('group:<gid>')` 算推送目标,`d.groupId == gid` 严格相等匹配,group_id 任何细微漂移(前后空格/大小写)都会让目标集为空 → 一条 prepare 都不发。
  - 修复①:`GroupExpander` group 比较 `trim().toLowerCase()`,空 gid 视为通配。
  - 修复②(兜底,决定性):`startSync` 若按 group 算出的 targets 为空、但确有已连接被控端,则直接把**全部已直连设备**作为目标——扫码直连一台盒子绝不该因 group 匹配细节而"推图完全没反应"。
  - 修复③:`startSync` 打印决定性诊断 `gid / connected / 各设备 group_id / targets`,下次一眼定位。
- **控制端诊断日志无法复制**: 设置页「诊断日志」新增「复制全部」按钮(一键复制到剪贴板 + SnackBar 回执),单行改 `SelectableText` 可长按选中复制。

## [v1.10.4] — 2026-07-05

### Fixed (CRITICAL — 真机验证驱动)
- **上上下下键崩溃退出软件的真根因**: v1.10.3 的 `openSettings()` 调用 `stopLockTask()`(API 21+),4.4 盒子上 dalvik 解析该方法即抛 `NoSuchMethodError`——**Error 不是 Exception,`catch(Exception)` 拦不住**——导致 openSettings 崩溃、进程被 `Force finishing`,表现为"上上下下退出软件"。logcat 铁证:`E/AndroidRuntime ... MainActivity.openSettings(SourceFile:4)` + `Force finishing activity` + `Process ... has died`。修复:`SDK_INT >= LOLLIPOP` 版本守卫 + `catch(Throwable)` 双保险;`tryLockTask()` 整条 Lock Task 链在 4.4 上整体早返回跳过。
- **遥控主页键回到播放墙**: manifest 启用 HomeAlias 不足以让 4.4 的 HOME 键生效(框架保留 preferred-HOME 关联)。`lmw_provision.sh` 新增设默认 HOME 步骤:`cmd package set-home-activity`(高版本)/ `pm clear-preferred-activity`(4.4 回退,禁用 youku 桌面后唯一启用的 CATEGORY_HOME 目标=播放端被自动选中)。设置页「设为主页」默认勾选。

## [v1.10.3] — 2026-07-05

### Fixed
- **被控端上上下下键不再"退出软件"**: `exitKiosk()` 会 `finish()` 掉唯一的 kiosk Activity,在 YunOS/AliOS 4.4 盒子上导致进程被系统回收,看起来像软件直接退出。改为 `openSettings()`——挂起 kiosk 看门狗 + 用 `REORDER_TO_FRONT` 把设置页压在播放 Activity 之上,不 finish,进设置稳定可靠。左上角连点 7 下同走此路径。
- **遥控主页键(HOME)现在回到播放墙**: `HomeAlias` activity-alias 由默认 `enabled="false"` 改为 `true`,盒子成为 HOME 候选;配合 provision 脚本已禁用的 OEM(youku)桌面,主页键直达播放墙。
- **控制端版本号一直显示 1.10.0**: `remote_flutter/pubspec.yaml` 版本从未随播放端抬升;现同步到 `1.10.3+23`,CI 从 pubspec 动态解析 build-name/number 烧进 APK。

### Changed
- **控制端播放编排按钮文案去歧义**: `下发并预缓存` → `①仅下发缓存 (不播)`;`全员就绪 · 同步起播` → `②推送并播放`(即"推送并播放"就是这个键)。README 说明「预缓存就绪 N/M」含义:M 台目标里 N 台已完成本次列表的下载+校验;盒子未收到 prepare 时不下载,故停在 0/M。

## [v1.10.0] — 2026-07-05

### Added
- **远程自更新 (`update_app`, §23)**: 遥控端选 APK → 上传到 broker 媒体库(得 url+sha256)→ 下发 `update_app` 给某台/某组/全部,被控端自己拉取并 root 安装(`su` 复制进 `/data/app` + reboot,4.4 外贸盒唯一可靠路径),免逐台 adb 刷机。被控端回报 `update_status`(downloading/installing/rejected/failed)。
- **四条安全护栏**: (1) 仅接受**已鉴权**帧(`Envelope.authed`——open/空签名一律拒),(2) `version_code` 必须**严格更新**(防降级/重放),(3) `url`+64 位 hex `sha256` 必填且下载后**重算比对**(不符删文件拒装),(4) 同签名由 Android 平台开机包扫描强制(免额外代码)。
- **控制端 UI**: 设备墙动作条新增「远程更新固件」入口,支持选目标(全部/按组)+ 填 versionCode + 一键上传下发。

### Notes
- 仅内网使用:`update_app` 依赖 `auth_mode`≠`open` + 已配 PSK 才生效;切勿把被控端暴露公网。
- 纯逻辑护栏(`UpdateGuard`)+ 安装命令(`RootInstaller.installScript`)+ `authed` 语义均有 JVM 单测覆盖。

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
> 当前状态：legacy 更新激活与单解码器循环边界遮罩的机制实现已完成；云编译和 QZX 真机验证待完成。不得据此声称视觉故障已在真机解决。
