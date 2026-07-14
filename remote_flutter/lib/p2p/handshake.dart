import 'dart:async';

import '../protocol/envelope.dart';

/// 一次同步会话的就绪收集状态（§9.1–9.2，p2p 本地版）。
///
/// 遥控端把 `prepare` 扇出给目标各被控端 → 收齐 `ready`（或 `ready_timeout_ms` 超时）
/// → 算 `play_at = controller_now + buffer_ms` → 发给各被控端。
class HandshakeSession {
  HandshakeSession({
    required this.prepareId,
    required this.groupId,
    required this.playlistId,
    this.pushId = '',
    required Set<String> targets,
    this.startIndex = 0,
    this.seekMs = 0,
    this.bufferMs = 2000,
  }) : targets = Set.unmodifiable(targets);

  /// = 本次 prepare 的 msg_id（§9.1 v1.1：会话关联键）。
  final String prepareId;
  final String groupId;
  final String playlistId;
  final String pushId;

  /// 目标被控端 device_id 集合。
  final Set<String> targets;
  final int startIndex;
  final int seekMs;

  /// play_at 相对 controllerNow 的提前量（§14.3：play_at = controller_now + buffer_ms）。
  final int bufferMs;

  final Set<String> _ready = {};
  bool _fired = false;

  Set<String> get ready => Set.unmodifiable(_ready);
  bool get fired => _fired;

  /// 已就绪是否覆盖全部目标。
  bool get complete => _ready.containsAll(targets) && targets.isNotEmpty;

  /// 记录一条 `ready`。返回是否“因此刚好收齐”（用于触发 play_at）。
  /// 仅接受属于本会话目标、且 prepareId 匹配（缺失则放行，§9.1 向后兼容）的 ready。
  bool onReady({
    required String deviceId,
    String? prepareId,
    bool ready = true,
  }) {
    if (prepareId != null && prepareId.isNotEmpty && prepareId != this.prepareId) {
      return false;
    }
    if (!targets.contains(deviceId)) return false;
    if (!ready) return false;
    final wasComplete = complete;
    _ready.add(deviceId);
    return !wasComplete && complete;
  }

  /// 标记已发出 play_at（防重复触发）。返回此调用是否为首次点火。
  bool markFired() {
    if (_fired) return false;
    _fired = true;
    return true;
  }

  /// 收齐 / 超时后向哪些设备发 play_at：
  ///  - 收齐：全部目标。
  ///  - 超时：仅已就绪者（§9.2：超时后对已就绪者广播）。
  Set<String> playAtTargets({required bool timedOut}) {
    if (timedOut) return Set.unmodifiable(_ready);
    return targets;
  }

  /// 构造 `play_at` payload（§9.2）。`play_at` = [controllerNow] + [bufferMs]。
  Map<String, dynamic> playAtPayload(int controllerNow) => {
        'playlist_id': playlistId,
        'push_id': pushId,
        'group_id': groupId,
        'start_index': startIndex,
        'seek_ms': seekMs,
        'play_at': controllerNow + bufferMs,
      };
}

/// 三段握手编排器（§9，p2p 本地版）。管理多个并发 [HandshakeSession]，
/// 注入 [nowFn] 与可选 [scheduler] 便于单测（不触碰真实 socket / 时钟）。
///
/// 用法：
///  1. [begin] 开一个会话（上层据返回的 session 把 `prepare` 扇出给 targets）。
///  2. 入站每条 `ready` 调 [onReady]；收齐即回调 [onPlayAt]。
///  3. `ready_timeout_ms` 到点回调 [onPlayAt]（仅已就绪者）。
class HandshakeOrchestrator {
  HandshakeOrchestrator({
    int Function()? nowFn,
    Timer Function(Duration, void Function())? scheduler,
    this.onPlayAt,
    this.onLog,
  })  : _now = nowFn ?? nowMs,
        _scheduler = scheduler ?? _defaultScheduler;

  final int Function() _now;
  final Timer Function(Duration, void Function()) _scheduler;

  /// 收齐或超时后触发：把 play_at 发给 [targets]。
  void Function(Set<String> targets, Map<String, dynamic> payload)? onPlayAt;
  void Function(String line)? onLog;

  final Map<String, HandshakeSession> _sessions = {};
  final Map<String, Timer> _timers = {};

  static Timer _defaultScheduler(Duration d, void Function() cb) =>
      Timer(d, cb);

  /// 当前在途会话数（诊断用）。
  int get pending => _sessions.length;

  HandshakeSession? session(String prepareId) => _sessions[prepareId];

  /// 开一个会话并起 `ready_timeout_ms` 计时。返回会话（上层据此扇出 prepare）。
  HandshakeSession begin({
    required String prepareId,
    required String groupId,
    required String playlistId,
    String pushId = '',
    required Set<String> targets,
    int startIndex = 0,
    int seekMs = 0,
    int bufferMs = 2000,
    int readyTimeoutMs = 2000,
  }) {
    final s = HandshakeSession(
      prepareId: prepareId,
      groupId: groupId,
      playlistId: playlistId,
      pushId: pushId,
      targets: targets,
      startIndex: startIndex,
      seekMs: seekMs,
      bufferMs: bufferMs,
    );
    _sessions[prepareId] = s;
    _timers[prepareId] =
        _scheduler(Duration(milliseconds: readyTimeoutMs), () {
      _fire(prepareId, timedOut: true);
    });
    return s;
  }

  /// 喂一条入站 `ready`。命中并收齐 → 立即点火 play_at。
  void onReady({
    required String deviceId,
    String? prepareId,
    String? groupId,
    String? playlistId,
    bool ready = true,
  }) {
    // 优先按 prepareId 精确匹配；缺失时按 group+playlist 回退（§9.1 向后兼容）。
    final s = _match(prepareId: prepareId, groupId: groupId, playlistId: playlistId);
    if (s == null) {
      _log('ready 未匹配任何在途会话（device=$deviceId, prepare_id=${prepareId ?? ''}, ready=$ready）');
      return;
    }
    final justComplete =
        s.onReady(deviceId: deviceId, prepareId: prepareId, ready: ready);
    if (!ready) {
      _log('ready($deviceId) = false，会话 ${s.prepareId} 继续等待缓存/超时');
    } else if (!s.targets.contains(deviceId)) {
      _log('ready($deviceId) 不在会话 ${s.prepareId} 目标内，忽略');
    } else {
      _log('ready($deviceId) 命中会话 ${s.prepareId}: ${s.ready.length}/${s.targets.length}');
    }
    if (justComplete) _fire(s.prepareId, timedOut: false);
  }

  HandshakeSession? _match({
    String? prepareId,
    String? groupId,
    String? playlistId,
  }) {
    if (prepareId != null && prepareId.isNotEmpty) {
      final direct = _sessions[prepareId];
      if (direct != null) return direct;
    }
    if (groupId != null) {
      for (final s in _sessions.values) {
        if (s.groupId == groupId &&
            (playlistId == null || s.playlistId == playlistId)) {
          return s;
        }
      }
    }
    return null;
  }

  void _fire(String prepareId, {required bool timedOut}) {
    final s = _sessions[prepareId];
    if (s == null) return;
    if (!s.markFired()) return; // 已点火，幂等
    _timers.remove(prepareId)?.cancel();
    _sessions.remove(prepareId);
    final targets = s.playAtTargets(timedOut: timedOut);
    if (targets.isEmpty) {
      _log('会话 $prepareId ${timedOut ? "超时" : "收齐"}但无就绪目标，放弃 play_at');
      return;
    }
    final payload = s.playAtPayload(_now());
    _log('会话 $prepareId ${timedOut ? "超时" : "收齐"} → play_at=${payload['play_at']} '
        '发往 ${targets.length} 台');
    onPlayAt?.call(targets, payload);
  }

  /// 取消一个会话（设备全部掉线等）。
  void cancel(String prepareId) {
    _timers.remove(prepareId)?.cancel();
    _sessions.remove(prepareId);
  }

  void cancelForTargets(Set<String> targets) {
    final ids = _sessions.entries
        .where((entry) => entry.value.targets.any(targets.contains))
        .map((entry) => entry.key)
        .toList();
    for (final id in ids) {
      cancel(id);
    }
  }

  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _sessions.clear();
  }

  void _log(String line) => onLog?.call(line);
}
