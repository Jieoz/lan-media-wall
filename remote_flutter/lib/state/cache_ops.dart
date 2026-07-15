/// §27/§28 缓存清理 / 清单 —— 控制端一体化状态归约(Broker + P2P 汇合).
///
/// 设计不变量(protocol_spec §27/§28, design §4.x):
///  - 悬挂操作按 (request_id + device_id) 唯一键管理; 同一 request_id 发给两台设备
///    是两个互不干扰的操作(设备维度隔离).
///  - 无乐观成功: 只有目标播放端回终态 cache_cleanup_result 才算完成; 路由 ack /
///    generic ack 绝不置成功.
///  - 迟到 / 陈旧结果拒绝: 结果落到不存在或已终态的键→记为 stale-late, 绝不完成一个
///    更新的操作.
///  - 幂等: 重复投递同一终态结果不重复变更(已终态即忽略, idempotent_replay 亦然).
///  - 终态互不混淆: success / partial / failed / timeout / unsupported / offline /
///    generationConflict / notFound / deleteFailed 各自独立可见.
///
/// 纯 Dart, 无 Flutter 依赖, 便于单测. WallState 持有它并负责 notifyListeners.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../protocol/messages.dart';

String cacheCleanupFingerprint({
  required String target,
  required String mode,
  required bool dryRun,
  List<String>? itemIds,
  String? expectedPushId,
  String reason = 'manual',
}) {
  final fields = <String>[
    'cache_cleanup', target, mode, dryRun ? 'true' : 'false',
    ...?itemIds, expectedPushId ?? '', reason,
  ];
  final canonical = fields.map((v) => '${utf8.encode(v).length}:$v').join();
  return sha256.convert(utf8.encode(canonical)).toString();
}

/// 单个删除结果行(§27 deleted[]).
class CacheDeleted {
  final String itemId;
  final String contentKey;
  final int bytes;
  const CacheDeleted(this.itemId, this.contentKey, this.bytes);

  static CacheDeleted fromMap(Map<String, dynamic> m) => CacheDeleted(
        (m['item_id'] ?? '').toString(),
        (m['content_key'] ?? '').toString(),
        _int(m['bytes']),
      );
}

/// 被跳过(受保护 / not_found)的行(§27 skipped[]).
class CacheSkipped {
  final String itemId;
  final String reason;
  const CacheSkipped(this.itemId, this.reason);

  static CacheSkipped fromMap(Map<String, dynamic> m) => CacheSkipped(
        (m['item_id'] ?? '').toString(),
        (m['reason'] ?? '').toString(),
      );
}

/// 删除失败的行(§27 failed[]).
class CacheFailed {
  final String itemId;
  final String reason;
  const CacheFailed(this.itemId, this.reason);

  static CacheFailed fromMap(Map<String, dynamic> m) => CacheFailed(
        (m['item_id'] ?? '').toString(),
        (m['reason'] ?? '').toString(),
      );
}

int _int(Object? v) =>
    v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);

bool _bool(Object? v) => v is bool ? v : false;

String _str(Object? v) => v is String ? v : '';

List<Map<String, dynamic>> _rows(Object? v) => (v is List)
    ? v
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false)
    : const [];

/// 播放端回来的 §27 cache_cleanup_result 终态帧(防御式解析: 未知/畸形字段不崩).
class CacheCleanupResult {
  final String requestId;
  final String deviceId;
  final String operationFingerprint;
  final bool ok;
  final String error;
  final bool dryRun;
  final String mode;
  final String reason;
  final String? expectedPushId;
  final String? observedPushId;
  final List<CacheDeleted> deleted;
  final List<CacheSkipped> skipped;
  final List<CacheFailed> failed;
  final int freedBytes;
  final CacheSummary? summaryAfter;
  final bool idempotentReplay;

  const CacheCleanupResult({
    required this.requestId,
    required this.deviceId,
    this.operationFingerprint = '',
    required this.ok,
    required this.error,
    required this.dryRun,
    required this.mode,
    required this.reason,
    this.expectedPushId,
    this.observedPushId,
    this.deleted = const [],
    this.skipped = const [],
    this.failed = const [],
    this.freedBytes = 0,
    this.summaryAfter,
    this.idempotentReplay = false,
  });

  static CacheCleanupResult fromMap(Map<String, dynamic> m) => CacheCleanupResult(
        requestId: _str(m['request_id']),
        deviceId: _str(m['device_id']),
        operationFingerprint: m.containsKey('operation_fingerprint')
            ? _str(m['operation_fingerprint'])
            : '',
        ok: _bool(m['ok']),
        error: _str(m['error']),
        dryRun: _bool(m['dry_run']),
        mode: _str(m['mode']),
        reason: _str(m['reason']),
        expectedPushId: m['expected_push_id']?.toString(),
        observedPushId: m['observed_push_id']?.toString(),
        deleted: _rows(m['deleted']).map(CacheDeleted.fromMap).toList(),
        skipped: _rows(m['skipped']).map(CacheSkipped.fromMap).toList(),
        failed: _rows(m['failed']).map(CacheFailed.fromMap).toList(),
        freedBytes: _int(m['freed_bytes']),
        summaryAfter: CacheSummary.fromMap(
            (m['summary_after'] as Map?)?.cast<String, dynamic>()),
        idempotentReplay: _bool(m['idempotent_replay']),
      );
}

/// §28 逐项清单行.
class InventoryItem {
  final String itemId;
  final String? contentKey;
  final int? bytes;
  final String state;
  final List<String> protectionReasons;
  final int lastAccessMs;

  const InventoryItem({
    required this.itemId,
    this.contentKey,
    this.bytes,
    this.state = 'ready',
    this.protectionReasons = const [],
    this.lastAccessMs = 0,
  });

  /// 受保护(有任一保护原因)则不可作为可回收候选.
  bool get isProtected => protectionReasons.isNotEmpty;

  static InventoryItem fromMap(Map<String, dynamic> m) => InventoryItem(
        itemId: _str(m['item_id']),
        contentKey: m['content_key']?.toString(),
        bytes: m['bytes'] == null ? null : _int(m['bytes']),
        state: m['state'] == null ? 'ready' : _str(m['state']),
        protectionReasons: (m['protection_reasons'] is List)
            ? (m['protection_reasons'] as List)
                .map((e) => e.toString())
                .toList()
            : const [],
        lastAccessMs: _int(m['last_access_ms']),
      );
}

/// §28 cache_inventory_result 终态帧.
class CacheInventoryResult {
  final String requestId;
  final String deviceId;
  final List<InventoryItem> items;

  const CacheInventoryResult({
    required this.requestId,
    required this.deviceId,
    this.items = const [],
  });

  static CacheInventoryResult fromMap(Map<String, dynamic> m) =>
      CacheInventoryResult(
        requestId: _str(m['request_id']),
        deviceId: _str(m['device_id']),
        items: _rows(m['items']).map(InventoryItem.fromMap).toList(),
      );
}

/// 一个清理操作的生命周期状态. 悬挂中(pending)之外全是终态(互不混淆).
enum CacheOpStatus {
  /// 已下发, 等待目标播放端回终态结果.
  pending,

  /// ok=true 且无 failed 行: 全部规划项都删掉了(或 dry-run 规划成功).
  success,

  /// ok=true 但有 failed 行: 部分删除失败.
  partial,

  /// ok=false 且 error 非代次类: 整单失败.
  failed,

  /// 超时: 到期仍无终态结果(可能老端不支持却假装, 或掉线).
  timeout,

  /// 目标不广告 cache_cleanup_v1 / cache_inventory_v1: 从不下发, 直接终态.
  unsupported,

  /// 目标离线: 从不下发, 直接终态.
  offline,

  /// 代次冲突(generation_mismatch / generation_changed): 什么都没删.
  generationConflict,
}

/// 一个清理 / 清单操作(按 request_id + device_id 唯一).
class CacheOperation {
  final String requestId;
  final String deviceId;

  /// 'cleanup' | 'inventory'.
  final String kind;

  /// cleanup 专属: 是否 dry-run(dry-run 成功=候选可提交, 不做物理删除).
  final bool dryRun;
  final String operationFingerprint;

  final CacheOpStatus status;

  /// 下发时刻(ms), 用于超时判定.
  final int startedAtMs;

  /// 终态到达时刻(ms), pending 时为 0.
  final int settledAtMs;

  /// cleanup 终态结果(到达后填).
  final CacheCleanupResult? result;

  /// inventory 终态结果(到达后填).
  final CacheInventoryResult? inventory;

  /// 人类可读的失败/冲突原因(error 字符串), 无则空.
  final String detail;

  const CacheOperation({
    required this.requestId,
    required this.deviceId,
    required this.kind,
    required this.status,
    required this.startedAtMs,
    this.dryRun = false,
    this.operationFingerprint = '',
    this.settledAtMs = 0,
    this.result,
    this.inventory,
    this.detail = '',
  });

  bool get isPending => status == CacheOpStatus.pending;
  bool get isTerminal => status != CacheOpStatus.pending;

  /// 稳定复合键: 同一 request_id 发给两台设备是两个隔离操作.
  static String keyFor(String requestId, String deviceId) =>
      '$requestId::@::$deviceId';

  String get key => keyFor(requestId, deviceId);

  CacheOperation _copy({
    CacheOpStatus? status,
    int? settledAtMs,
    CacheCleanupResult? result,
    CacheInventoryResult? inventory,
    String? detail,
  }) =>
      CacheOperation(
        requestId: requestId,
        deviceId: deviceId,
        kind: kind,
        dryRun: dryRun,
        operationFingerprint: operationFingerprint,
        startedAtMs: startedAtMs,
        status: status ?? this.status,
        settledAtMs: settledAtMs ?? this.settledAtMs,
        result: result ?? this.result,
        inventory: inventory ?? this.inventory,
        detail: detail ?? this.detail,
      );
}

/// 迟到 / 陈旧结果的记账(诊断可见, 不完成任何操作).
class StaleResult {
  final String requestId;
  final String deviceId;
  final String kind; // 'cleanup' | 'inventory'
  final String why; // 'unknown_op' | 'already_terminal'
  final int atMs;
  const StaleResult(this.requestId, this.deviceId, this.kind, this.why, this.atMs);
}

/// Broker + P2P 汇合的一体化清理/清单归约器.
///
/// 两个传输的接收路径都调进这里的同一组 on* 方法(绝不各建平行特例状态). 出站发送
/// 由 WallState 负责(它持有链路), 归约器只做「登记悬挂 → 匹配终态 → 记陈旧」的纯状态
/// 机, 因此完全可单测. 键为 request_id+device_id, 天然做到设备维度隔离与并发不覆盖.
class CacheOpsReducer {
  /// 复合键 -> 操作. 悬挂与终态都留在这里(UI 展示每台设备的最近结果并可重试).
  final Map<String, CacheOperation> _ops = {};

  /// 陈旧/迟到结果记账(有界, 仅供诊断).
  final List<StaleResult> _stale = [];
  static const int _staleMax = 64;

  /// 默认超时(ms). WallState tick 时调 [expire] 收割.
  final int timeoutMs;

  CacheOpsReducer({this.timeoutMs = 30000});

  Iterable<CacheOperation> get operations => _ops.values;
  List<StaleResult> get staleResults => List.unmodifiable(_stale);

  CacheOperation? operationFor(String requestId, String deviceId) =>
      _ops[CacheOperation.keyFor(requestId, deviceId)];

  /// 该设备当前是否有悬挂清理(UI 禁用重复提交).
  bool hasPending(String deviceId) => _ops.values
      .any((o) => o.deviceId == deviceId && o.isPending);

  /// 登记一个即将下发的清理操作. 传输/能力前置由调用方(WallState)判定:
  ///  - [supported]=false → 直接终态 unsupported(从不下发);
  ///  - [online]=false → 直接终态 offline(从不下发);
  /// 否则登记为 pending. 返回登记后的操作(调用方据 status 决定是否真的发线).
  ///
  /// 幂等: 同键已存在且悬挂 → 原样返回(并发不覆盖); 已终态 → 允许以新 startedAt 重开
  /// (重试语义, 见 [retry]).
  CacheOperation beginCleanup({
    required String requestId,
    required String deviceId,
    required bool dryRun,
    String operationFingerprint = '',
    required int nowMs,
    bool supported = true,
    bool online = true,
  }) {
    final key = CacheOperation.keyFor(requestId, deviceId);
    final existing = _ops[key];
    if (existing != null && existing.isPending) return existing;
    final CacheOpStatus status;
    String detail = '';
    if (!supported) {
      status = CacheOpStatus.unsupported;
      detail = '目标未广告 cache_cleanup_v1';
    } else if (!online) {
      status = CacheOpStatus.offline;
      detail = '目标离线';
    } else {
      status = CacheOpStatus.pending;
    }
    final op = CacheOperation(
      requestId: requestId,
      deviceId: deviceId,
      kind: 'cleanup',
      dryRun: dryRun,
      operationFingerprint: operationFingerprint,
      status: status,
      startedAtMs: nowMs,
      settledAtMs: status == CacheOpStatus.pending ? 0 : nowMs,
      detail: detail,
    );
    _ops[key] = op;
    return op;
  }

  /// 登记一个即将下发的清单请求(能力/在线前置同 [beginCleanup]).
  CacheOperation beginInventory({
    required String requestId,
    required String deviceId,
    required int nowMs,
    bool supported = true,
    bool online = true,
  }) {
    final key = CacheOperation.keyFor(requestId, deviceId);
    final existing = _ops[key];
    if (existing != null && existing.isPending) return existing;
    final CacheOpStatus status;
    String detail = '';
    if (!supported) {
      status = CacheOpStatus.unsupported;
      detail = '目标未广告 cache_inventory_v1';
    } else if (!online) {
      status = CacheOpStatus.offline;
      detail = '目标离线';
    } else {
      status = CacheOpStatus.pending;
    }
    final op = CacheOperation(
      requestId: requestId,
      deviceId: deviceId,
      kind: 'inventory',
      status: status,
      startedAtMs: nowMs,
      settledAtMs: status == CacheOpStatus.pending ? 0 : nowMs,
      detail: detail,
    );
    _ops[key] = op;
    return op;
  }

  /// 收到 §27 cache_cleanup_result. 匹配悬挂操作并落终态; 落到不存在或已终态的键→
  /// 记陈旧(绝不完成更新的操作, 绝不二次变更). 返回被完成的操作, 或 null(陈旧).
  CacheOperation? onCleanupResult(CacheCleanupResult r, {required int nowMs}) {
    final key = CacheOperation.keyFor(r.requestId, r.deviceId);
    final op = _ops[key];
    if (op == null) {
      _recordStale(r.requestId, r.deviceId, 'cleanup', 'unknown_op', nowMs);
      return null;
    }
    if (op.kind != 'cleanup' || op.dryRun != r.dryRun ||
        op.operationFingerprint != r.operationFingerprint) {
      _recordStale(r.requestId, r.deviceId, 'cleanup',
          'operation_fingerprint_mismatch', nowMs);
      return null;
    }
    if (op.isTerminal) {
      // 幂等: 同一操作的重复/replay 终态不重复变更.
      _recordStale(r.requestId, r.deviceId, 'cleanup', 'already_terminal', nowMs);
      return null;
    }
    final CacheOpStatus status;
    String detail = r.error;
    if (!r.ok) {
      if (r.error == 'generation_mismatch' || r.error == 'generation_changed') {
        status = CacheOpStatus.generationConflict;
      } else {
        status = CacheOpStatus.failed;
      }
    } else if (r.failed.isNotEmpty) {
      status = CacheOpStatus.partial;
      detail = '${r.failed.length} 项删除失败';
    } else {
      status = CacheOpStatus.success;
      detail = '';
    }
    final settled = op._copy(
      status: status, settledAtMs: nowMs, result: r, detail: detail);
    _ops[key] = settled;
    return settled;
  }

  /// 收到 §28 cache_inventory_result. 匹配规则同上.
  CacheOperation? onInventoryResult(CacheInventoryResult r, {required int nowMs}) {
    final key = CacheOperation.keyFor(r.requestId, r.deviceId);
    final op = _ops[key];
    if (op == null) {
      _recordStale(r.requestId, r.deviceId, 'inventory', 'unknown_op', nowMs);
      return null;
    }
    if (op.kind != 'inventory') {
      _recordStale(r.requestId, r.deviceId, 'inventory', 'kind_mismatch', nowMs);
      return null;
    }
    if (op.isTerminal) {
      _recordStale(r.requestId, r.deviceId, 'inventory', 'already_terminal', nowMs);
      return null;
    }
    final settled = op._copy(
      status: CacheOpStatus.success, settledAtMs: nowMs, inventory: r);
    _ops[key] = settled;
    return settled;
  }

  /// 投递失败: 把 ONE 个悬挂操作立刻转 timeout 终态(投递失败与「发出去没回」同样
  /// 对待, 不伪造成功, 且不误伤其它设备的悬挂操作). 已终态则忽略.
  CacheOperation? failUndelivered(
      String requestId, String deviceId, int nowMs, String why) {
    final key = CacheOperation.keyFor(requestId, deviceId);
    final op = _ops[key];
    if (op == null || op.isTerminal) return null;
    final t = op._copy(
      status: CacheOpStatus.timeout, settledAtMs: nowMs, detail: why);
    _ops[key] = t;
    return t;
  }

  /// 收割超时: 所有悬挂且 now-startedAt≥timeout 的操作转 timeout 终态.
  /// 返回被超时的操作(供 UI/日志). WallState 在 status/tick 时调用.
  List<CacheOperation> expire(int nowMs) {
    final expired = <CacheOperation>[];
    for (final entry in _ops.entries.toList()) {
      final op = entry.value;
      if (op.isPending && nowMs - op.startedAtMs >= timeoutMs) {
        final t = op._copy(
          status: CacheOpStatus.timeout, settledAtMs: nowMs,
          detail: '等待结果超时');
        _ops[entry.key] = t;
        expired.add(t);
      }
    }
    return expired;
  }

  /// 重试: 用一个新的 request_id 重开某设备的操作. 旧终态操作保留(诊断), 新操作以
  /// 新键 pending 登记. 返回新操作(调用方据 status 发线).
  CacheOperation retryCleanup({
    required String newRequestId,
    required String deviceId,
    required bool dryRun,
    String operationFingerprint = '',
    required int nowMs,
    bool supported = true,
    bool online = true,
  }) =>
      beginCleanup(
        requestId: newRequestId, deviceId: deviceId, dryRun: dryRun,
        operationFingerprint: operationFingerprint,
        nowMs: nowMs, supported: supported, online: online);

  /// 移除某台设备的所有已终态操作(UI 关闭详情面板时清理; 悬挂的保留).
  void clearSettledFor(String deviceId) {
    _ops.removeWhere((_, op) => op.deviceId == deviceId && op.isTerminal);
  }

  void _recordStale(
      String requestId, String deviceId, String kind, String why, int atMs) {
    _stale.add(StaleResult(requestId, deviceId, kind, why, atMs));
    while (_stale.length > _staleMax) {
      _stale.removeAt(0);
    }
  }
}
