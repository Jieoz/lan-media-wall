/// §6.4 shared media-push progress state machine (E0001).
///
/// ONE state machine, consumed by BOTH transports. Progress in this system is
/// not a dedicated wire frame: every player reports `status.cache = {item_id:
/// "downloading:NN%" | "verifying" | "ready" | "error[:reason]" | "pending"}`.
/// The P2P coordinator (`WallAggregator.mergeStatus` → snapshot → `onWall`) and
/// the broker link (`onWall`) both funnel into `WallState._onWall(snapshot)`,
/// so feeding this machine there gives broker/P2P parity structurally — no
/// transport-specific progress code.
///
/// Invariants this machine enforces (the E0001 contract):
///  - percent is always an int in 0..100 — never NaN, never negative, never >100;
///  - percent is MONOTONIC within a generation — an out-of-order or resumed
///    frame that would move it backwards is ignored (kept at the max seen);
///  - percent is capped at 99 while downloading/verifying — only `ready`
///    yields exactly 100, so the UI never shows 100 before the player's atomic
///    finalize + checksum + `ready` handshake;
///  - progress is RESET per job: a new [generation] for a (device,item) drops
///    the old record and starts at 0/pending;
///  - STALE frames are dropped: a frame tagged with an older generation than the
///    record's is discarded (a lingering status from a superseded push job);
///  - records are keyed by device + item + generation and bounded — only the
///    active generation per (device,item) is retained.
///
/// LIMITATION (documented, truthful): the wire `status.cache` carries no
/// per-item generation, and players do not echo one back. [generation] is
/// therefore assigned CONTROLLER-side by [WallState] per push job. The machine
/// uses it to reset/supersede locally; it cannot distinguish two jobs that a
/// player coalesces into one identical cache entry. This is a real boundary of
/// a progress signal that rides on an opaque, additive status field.
library;

import 'dart:math' as math;

/// The lifecycle phase parsed out of a `status.cache` value.
///
/// [interrupted] is not a wire form — the machine synthesizes it when a device
/// goes offline / a job is cancelled while an item is still mid-flight, so the
/// UI can render a frozen/failed state instead of a live bar stuck at a high
/// percent that would read as ongoing success (E0002 risk 3).
enum ProgressPhase { pending, downloading, verifying, ready, error, interrupted }

/// One immutable progress observation for a (device,item) in a generation.
class MediaProgress {
  final String deviceId;
  final String itemId;
  final int generation;
  final ProgressPhase phase;

  /// 0..100, monotonic within [generation], capped <100 until [phase]==ready.
  final int percent;

  /// error reason (phase==error) / interrupt cause, or ''.
  final String detail;

  /// controller-local millis of the last accepted update.
  final int updatedAt;

  /// E0002 risk 1 barrier. Set by [MediaProgressMachine.beginJob] when this
  /// item was ready/near-terminal in the PRIOR generation and a fresh push job
  /// starts. While true, an inherited `ready`/`verifying`/`downloading:100`
  /// frame is NOT accepted as completion — the item is held at pending/0 until
  /// fresh-job evidence arrives (a `downloading:<100` frame, or an explicit
  /// [MediaProgressMachine.confirmJobStarted] once the device echoes the new
  /// job's playlist_id). This stops a pre-command wall snapshot that still
  /// carries the old `ready` from instantly showing 100 under the new job.
  final bool staleGuard;

  const MediaProgress({
    required this.deviceId,
    required this.itemId,
    required this.generation,
    required this.phase,
    required this.percent,
    this.detail = '',
    this.updatedAt = 0,
    this.staleGuard = false,
  });

  bool get isTerminal =>
      phase == ProgressPhase.ready ||
      phase == ProgressPhase.error ||
      phase == ProgressPhase.interrupted;
  bool get isReady => phase == ProgressPhase.ready;
  bool get isError =>
      phase == ProgressPhase.error || phase == ProgressPhase.interrupted;

  MediaProgress _copy({
    ProgressPhase? phase,
    int? percent,
    String? detail,
    int? updatedAt,
    bool? staleGuard,
  }) =>
      MediaProgress(
        deviceId: deviceId,
        itemId: itemId,
        generation: generation,
        phase: phase ?? this.phase,
        percent: percent ?? this.percent,
        detail: detail ?? this.detail,
        updatedAt: updatedAt ?? this.updatedAt,
        staleGuard: staleGuard ?? this.staleGuard,
      );
}

/// Aggregated progress for one device's active push job.
class DeviceJobProgress {
  final String deviceId;
  final int generation;

  /// mean item percent, 0..100.
  final int percent;
  final int totalItems;
  final int readyItems;

  /// True if any item errored (checksum mismatch, download failure) OR was
  /// interrupted (device went offline / job cancelled) mid-flight. The UI must
  /// render this as failed/frozen, NOT as a live bar — otherwise a job that
  /// died at 90% would read as ongoing success (E0002 risk 3).
  final bool hasError;

  const DeviceJobProgress({
    required this.deviceId,
    required this.generation,
    required this.percent,
    required this.totalItems,
    required this.readyItems,
    required this.hasError,
  });

  /// A job is complete only when every item reached the `ready` handshake — not
  /// when percent hits 100 (percent is capped at 99 pre-finalize by design) and
  /// never while an item is in error/interrupted.
  bool get isComplete =>
      totalItems > 0 && readyItems == totalItems && !hasError;
}

/// Parse a `status.cache` value into (phase, percent, detail). Defensive: any
/// malformed/unknown string degrades to (pending, 0) rather than throwing, and
/// a bogus percent (NaN source, negative, >100) is clamped into 0..100.
({ProgressPhase phase, int percent, String detail}) parseCacheValue(String raw) {
  final v = raw.trim().toLowerCase();
  if (v == 'ready') {
    return (phase: ProgressPhase.ready, percent: 100, detail: '');
  }
  if (v == 'verifying') {
    // Bytes are in; checksum/finalize pending. Not 100 — capped by the machine.
    return (phase: ProgressPhase.verifying, percent: 99, detail: '');
  }
  if (v == 'retrying') {
    // Android emits `retrying` on a transient download stall/reconnect (§6.2).
    // It is still an in-flight DOWNLOADING state, not an error and not done:
    // keep the phase downloading with no percent claim (0), so the monotonic
    // rule holds it at the max already seen rather than regressing or erroring.
    return (phase: ProgressPhase.downloading, percent: 0, detail: '');
  }
  if (v.startsWith('error')) {
    final i = v.indexOf(':');
    return (
      phase: ProgressPhase.error,
      percent: 0,
      detail: i >= 0 ? raw.trim().substring(i + 1) : '',
    );
  }
  if (v.startsWith('downloading')) {
    final i = v.indexOf(':');
    var pct = 0;
    if (i >= 0) {
      final digits = v.substring(i + 1).replaceAll('%', '').trim();
      pct = int.tryParse(digits) ?? 0;
    }
    return (
      phase: ProgressPhase.downloading,
      percent: _clampPercent(pct),
      detail: '',
    );
  }
  // "pending" or anything unknown.
  return (phase: ProgressPhase.pending, percent: 0, detail: '');
}

int _clampPercent(num? p) {
  if (p == null || p.isNaN || p.isInfinite) return 0;
  final i = p.toInt();
  if (i < 0) return 0;
  if (i > 100) return 100;
  return i;
}

/// The one shared progress state machine. Pure and transport-agnostic: it is
/// fed parsed cache maps by [WallState._onWall] for every device in a wall
/// snapshot, regardless of whether that snapshot came over P2P or the broker.
class MediaProgressMachine {
  /// deviceId → (itemId → record). Only the active generation per (device,item)
  /// is retained (bounded history: superseded generations are pruned on reset).
  final Map<String, Map<String, MediaProgress>> _byDevice = {};
  /// Generation explicitly seeded by beginJob for each device. Other generations
  /// may be passively observed (tests/ambient status) and are not item-filtered.
  final Map<String, int> _explicitGeneration = {};

  /// Bumped whenever any accepted update mutates state. Callers coalesce their
  /// own notify by comparing this to the value at the previous drain.
  int _revision = 0;
  int get revision => _revision;

  /// Ingest one device's cache map, tagging it with the controller-assigned
  /// [generation] for that device's current push job. [now] is injectable for
  /// deterministic tests. Returns true if any record changed.
  ///
  /// Rules applied per item:
  ///  - unknown generation for this (device,item), or a NEWER generation than
  ///    the stored record → reset: start a fresh record at the incoming value;
  ///  - OLDER generation than the stored record → STALE, dropped entirely;
  ///  - same generation → monotonic merge (percent never decreases; phase only
  ///    advances toward ready/error; capped <100 until ready).
  bool ingestDeviceCache(
    String deviceId,
    Map<String, String> cache,
    int generation, {
    int now = 0,
  }) {
    if (deviceId.isEmpty) return false;
    var changed = false;
    final items = _byDevice.putIfAbsent(deviceId, () => {});
    for (final entry in cache.entries) {
      final itemId = entry.key;
      final parsed = parseCacheValue(entry.value);
      final prev = items[itemId];

      // For an explicit push generation, beginJob pre-seeds the exact expected
      // item set. A player status may also carry its whole historical cache
      // inventory; never let those unrelated entries join this job's average or
      // completion count. Generation 0 remains passive/ambient discovery.
      if (prev == null && _explicitGeneration[deviceId] == generation) continue;

      if (generation < (prev?.generation ?? -1)) {
        continue; // STALE: a lingering frame from a superseded job — drop it.
      }
      if (prev == null || generation > prev.generation) {
        // fresh job (or first sighting) → reset this item's progress to
        // 0/pending then apply the incoming observation. No prior generation
        // was seeded here (beginJob was not called for it), so there is no
        // stale-ready to guard against: a first sighting of `ready` is a
        // genuine cached-instant completion.
        items[itemId] = _apply(
          MediaProgress(
            deviceId: deviceId,
            itemId: itemId,
            generation: generation,
            phase: ProgressPhase.pending,
            percent: 0,
          ),
          parsed,
          now,
        );
        changed = true;
        continue;
      }
      // same generation → monotonic merge (guard-aware; see _apply).
      final merged = _apply(prev, parsed, now);
      if (!identical(merged, prev)) {
        items[itemId] = merged;
        changed = true;
      }
    }
    if (changed) _revision++;
    return changed;
  }

  /// Merge a parsed observation onto [prev] under the monotonic/cap rules.
  /// Returns [prev] unchanged (same identity) when the observation is a no-op or
  /// a backwards move that must be ignored.
  MediaProgress _apply(
    MediaProgress prev,
    ({ProgressPhase phase, int percent, String detail}) obs,
    int now,
  ) {
    // E0002 risk 1: while the stale guard holds, an INHERITED near-terminal
    // frame (ready / verifying / downloading:100) is not proof the new job ran
    // — it can be a pre-command snapshot. Hold at pending/0. Only fresh-job
    // evidence releases the guard: a `downloading:<100` frame (the player is
    // demonstrably re-fetching) or an explicit confirmJobStarted() once the
    // device echoes the exact new job's push_id (needed because a cached re-push
    // emits `ready` with no intervening downloading — it would hang otherwise).
    if (prev.staleGuard) {
      final freshEvidence = obs.phase == ProgressPhase.downloading &&
          obs.percent < 100;
      if (!freshEvidence) {
        return prev; // still guarded → stay pending/0, not complete.
      }
      // released by real download evidence → drop guard and apply normally.
      prev = prev._copy(staleGuard: false);
    }
    // An interrupt is a FAILED terminal within its generation. Nothing — not
    // even a late or ambient `ready` still sitting in the dead job's cache
    // (E0002 risk 3: an offline snapshot carries the pre-disconnect inventory)
    // — may resurrect it into apparent success. Reviving a disconnected job
    // from stale cache would report a died-at-80% push as 100%/complete. Only a
    // FRESH generation (new push_id / beginJob) starts a new record; a genuine
    // recovery must arrive as a new job, never as an ambient overwrite of a
    // failed terminal. This is stricter than the ready-sticky rule below: an
    // interrupted record blocks ALL incoming phases, `ready` included.
    if (prev.phase == ProgressPhase.interrupted) {
      return prev;
    }
    // A terminal `ready` is sticky within a generation — do not un-ready.
    if (prev.phase == ProgressPhase.ready && obs.phase != ProgressPhase.ready) {
      return prev;
    }
    final targetPhase = _maxPhase(prev.phase, obs.phase);
    // Cap: only `ready` may reach 100. Everything else tops out at 99 so the
    // UI never shows 100 before the atomic finalize + checksum + ready ACK.
    var pct = obs.percent;
    if (targetPhase != ProgressPhase.ready) {
      pct = math.min(pct, 99);
    } else {
      pct = 100;
    }
    // Monotonic: never regress percent within a generation.
    pct = math.max(pct, prev.percent);
    if (targetPhase != ProgressPhase.ready) pct = math.min(pct, 99);

    final detail =
        obs.phase == ProgressPhase.error ? obs.detail : prev.detail;
    if (targetPhase == prev.phase &&
        pct == prev.percent &&
        detail == prev.detail) {
      return prev; // genuine no-op
    }
    return prev._copy(
      phase: targetPhase,
      percent: pct,
      detail: detail,
      updatedAt: now,
    );
  }

  /// Phase ordering for monotonic advance. error and ready are terminal; error
  /// wins over ready is NOT allowed to flip a ready, handled by the sticky rule
  /// above. Ordinary ordering: pending < downloading < verifying < ready,
  /// error slots just below ready so a mid-download error is observable.
  ProgressPhase _maxPhase(ProgressPhase a, ProgressPhase b) =>
      _phaseRank(a) >= _phaseRank(b) ? a : b;

  int _phaseRank(ProgressPhase p) => switch (p) {
        ProgressPhase.pending => 0,
        ProgressPhase.downloading => 1,
        ProgressPhase.verifying => 2,
        ProgressPhase.error => 3,
        // interrupted sits with error (failed-terminal). Note the interrupted
        // record is already short-circuited as strictly terminal in _apply
        // (a late `ready` cannot revive it), so this rank only orders a fresh
        // observation against a NON-interrupted prev.
        ProgressPhase.interrupted => 3,
        ProgressPhase.ready => 4,
      };

  /// Current record for a (device,item), or null if never seen.
  MediaProgress? progressFor(String deviceId, String itemId) =>
      _byDevice[deviceId]?[itemId];

  /// Aggregate one device's active job across the items it is currently tracking
  /// for [generation]. Items from other generations are ignored. Returns null
  /// when the device has no items in that generation.
  DeviceJobProgress? deviceJob(String deviceId, int generation) {
    final items = _byDevice[deviceId];
    if (items == null || items.isEmpty) return null;
    final active =
        items.values.where((r) => r.generation == generation).toList();
    if (active.isEmpty) return null;
    var sum = 0;
    var ready = 0;
    var err = false;
    for (final r in active) {
      sum += r.percent;
      if (r.isReady) ready++;
      if (r.isError) err = true;
    }
    return DeviceJobProgress(
      deviceId: deviceId,
      generation: generation,
      percent: (sum / active.length).round(),
      totalItems: active.length,
      readyItems: ready,
      hasError: err,
    );
  }

  /// Batch/fan-out progress across [deviceIds] for their respective
  /// [generationOf] job. Mean of per-device percents; complete only when every
  /// device's job is complete (all items ready). Returns 0..100 percent.
  ({int percent, int completeDevices, int totalDevices, int errorDevices})
      batchProgress(
    Iterable<String> deviceIds,
    int Function(String deviceId) generationOf,
  ) {
    var sum = 0;
    var n = 0;
    var complete = 0;
    var errored = 0;
    for (final id in deviceIds) {
      final job = deviceJob(id, generationOf(id));
      if (job == null) continue;
      n++;
      sum += job.percent;
      if (job.isComplete) complete++;
      if (job.hasError) errored++;
    }
    return (
      percent: n == 0 ? 0 : (sum / n).round(),
      completeDevices: complete,
      totalDevices: n,
      errorDevices: errored,
    );
  }

  /// E0002 risk 1: mark the start of a fresh push job for [deviceId] at
  /// [generation], seeding the [expectedItems] at 0/pending. Any expected item
  /// that was ready/near-terminal in the PRIOR generation gets a [staleGuard]
  /// so a pre-command wall snapshot still carrying its old `ready` cannot
  /// instantly report 100 under the new job — it stays pending until fresh-job
  /// evidence (see [_apply]). Items not in [expectedItems] but tracked for this
  /// device are pruned (bounded history: only the active job's items survive).
  /// [generation] must be the NEW (already-bumped) generation.
  void beginJob(String deviceId, int generation, Iterable<String> expectedItems,
      {int now = 0}) {
    if (deviceId.isEmpty) return;
    _explicitGeneration[deviceId] = generation;
    final items = _byDevice.putIfAbsent(deviceId, () => {});
    final expected = expectedItems.toSet();
    // prune items from prior jobs that are not part of this one.
    items.removeWhere((id, _) => !expected.contains(id));
    for (final id in expected) {
      if (id.isEmpty) continue;
      // Always guard a fresh replace: after a controller restart there may be
      // no prior record even though the player's ambient cache is already ready.
      const guard = true;
      items[id] = MediaProgress(
        deviceId: deviceId,
        itemId: id,
        generation: generation,
        phase: ProgressPhase.pending,
        percent: 0,
        updatedAt: now,
        staleGuard: guard,
      );
    }
    _revision++;
  }

  /// E0002 risk 1: the device has demonstrably adopted the job at [generation]
  /// (its status echoed the new job's push_id), so an inherited `ready` is
  /// now trustworthy: release the stale guard on its items. Required for the
  /// cached-instant re-push case, where the player re-affirms `ready` with no
  /// intervening `downloading` frame that would otherwise release the guard.
  bool confirmJobStarted(String deviceId, int generation) {
    final items = _byDevice[deviceId];
    if (items == null) return false;
    var changed = false;
    for (final e in items.entries) {
      final r = e.value;
      if (r.generation == generation && r.staleGuard) {
        items[e.key] = r._copy(staleGuard: false);
        changed = true;
      }
    }
    if (changed) _revision++;
    return changed;
  }

  /// E0002 risk 3: a device went offline / the job was cancelled while items
  /// were still in flight. Freeze each non-ready item of [generation] at its
  /// last percent but flip it to [ProgressPhase.interrupted] with [reason], so
  /// the UI shows a failed/frozen state rather than a live bar reading as
  /// ongoing success. Ready items are left intact (already truthfully done).
  bool interruptDevice(String deviceId, int generation,
      {String reason = 'disconnected', int now = 0}) {
    final items = _byDevice[deviceId];
    if (items == null) return false;
    var changed = false;
    for (final e in items.entries) {
      final r = e.value;
      if (r.generation != generation) continue;
      if (r.phase == ProgressPhase.ready ||
          r.phase == ProgressPhase.interrupted) {
        continue;
      }
      items[e.key] = r._copy(
        phase: ProgressPhase.interrupted,
        detail: reason,
        updatedAt: now,
        staleGuard: false,
      );
      changed = true;
    }
    if (changed) _revision++;
    return changed;
  }

  /// E0002 risk 3: cancel/clear — drop a single device's records so a cancelled
  /// job leaves no lingering percent at all (used by the empty-replace CLEAR
  /// path). Distinct from [interruptDevice] (freeze+mark) and [forgetDevice]
  /// (device removed from the wall entirely).
  void resetDevice(String deviceId) {
    _explicitGeneration.remove(deviceId);
    if (_byDevice.remove(deviceId) != null) _revision++;
  }

  /// Forget a device entirely (e.g. removed from the wall).
  void forgetDevice(String deviceId) {
    _explicitGeneration.remove(deviceId);
    if (_byDevice.remove(deviceId) != null) _revision++;
  }

  void clear() {
    if (_byDevice.isEmpty) return;
    _byDevice.clear();
    _explicitGeneration.clear();
    _revision++;
  }
}
