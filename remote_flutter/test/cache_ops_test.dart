import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/messages.dart';
import 'package:remote_flutter/state/cache_ops.dart';

/// §27/§28 一体化归约器 —— 双传输汇合、幂等、陈旧拒绝、代次冲突、超时、能力真值.
void main() {
  CacheCleanupResult cleanup(
    String reqId,
    String dev, {
    bool ok = true,
    String error = '',
    bool dryRun = false,
    List<Map<String, dynamic>> deleted = const [],
    List<Map<String, dynamic>> failed = const [],
    List<Map<String, dynamic>> skipped = const [],
    bool replay = false,
  }) =>
      CacheCleanupResult.fromMap({
        'request_id': reqId,
        'device_id': dev,
        'ok': ok,
        'error': error,
        'dry_run': dryRun,
        'mode': 'unreferenced',
        'reason': 'manual',
        'deleted': deleted,
        'failed': failed,
        'skipped': skipped,
        'freed_bytes': deleted.fold<int>(0, (a, d) => a + (d['bytes'] as int? ?? 0)),
        'idempotent_replay': replay,
      });

  group('模型防御式解析', () {
    test('cleanup_result 完整解析', () {
      final r = cleanup('r1', 'd1', deleted: [
        {'item_id': 'x', 'content_key': 'sha256:aa', 'bytes': 1000},
      ], skipped: [
        {'item_id': 'y', 'reason': 'active'},
      ]);
      expect(r.ok, isTrue);
      expect(r.deleted.single.itemId, 'x');
      expect(r.deleted.single.bytes, 1000);
      expect(r.skipped.single.reason, 'active');
      expect(r.freedBytes, 1000);
    });

    test('畸形/未知字段不崩', () {
      final r = CacheCleanupResult.fromMap({
        'request_id': 'r1',
        'device_id': 'd1',
        'ok': 'not-a-bool', // 错误类型
        'deleted': 'not-a-list', // 错误类型
        'skipped': [
          {'item_id': 'y'}, // 缺 reason
          42, // 非 map 行, 应被过滤
        ],
        'freed_bytes': 'oops',
        'unknown_field': {'nested': true},
      });
      expect(r.ok, isFalse);
      expect(r.deleted, isEmpty);
      expect(r.skipped.single.reason, '');
      expect(r.freedBytes, 0);
    });

    test('inventory_result + protection_reasons', () {
      final inv = CacheInventoryResult.fromMap({
        'request_id': 'q1',
        'device_id': 'd1',
        'items': [
          {'item_id': 'a', 'content_key': 'sha256:aa', 'bytes': 10,
            'protection_reasons': ['active']},
          {'item_id': 'b', 'content_key': 'path:/x', 'bytes': 20,
            'protection_reasons': []},
        ],
      });
      expect(inv.items.length, 2);
      expect(inv.items[0].isProtected, isTrue);
      expect(inv.items[1].isProtected, isFalse);
    });

    test('CacheSummary null-in null-out', () {
      expect(CacheSummary.fromMap(null), isNull);
      final s = CacheSummary.fromMap({'ready_items': 5, 'reclaimable_bytes': 100});
      expect(s!.readyItems, 5);
      expect(s.reclaimableBytes, 100);
      expect(s.protectedItems, 0); // 缺失键走默认
    });
  });

  group('归约器 —— 悬挂/终态/幂等', () {
    test('结果类型和 dry_run 必须与悬挂操作匹配', () {
      final r = CacheOpsReducer();
      r.beginCleanup(
          requestId: 'same', deviceId: 'd1', dryRun: true, nowMs: 0);
      expect(r.onCleanupResult(
          cleanup('same', 'd1', ok: true, dryRun: false), nowMs: 1), isNull);
      expect(r.onInventoryResult(CacheInventoryResult.fromMap({
        'request_id': 'same', 'device_id': 'd1', 'items': const [],
      }), nowMs: 2), isNull);
      expect(r.operationFor('same', 'd1')!.status, CacheOpStatus.pending);
    });

    test('operation fingerprint mismatch is stale and cannot settle pending', () {
      final r = CacheOpsReducer();
      r.beginCleanup(requestId: 'fp', deviceId: 'd1', dryRun: false,
          operationFingerprint: 'expected', nowMs: 0);
      final result = CacheCleanupResult(
        requestId: 'fp', deviceId: 'd1', operationFingerprint: 'forged',
        ok: true, error: '', dryRun: false, mode: 'selected', reason: 'manual',
        expectedPushId: 'g1', observedPushId: 'g1', deleted: const [],
        skipped: const [], failed: const [], freedBytes: 0,
        // summaryAfter is CacheSummary?, not a Map — use null for this
        // fingerprint-mismatch fixture (field is unused by the assertion).
        summaryAfter: null, idempotentReplay: false,
      );
      expect(r.onCleanupResult(result, nowMs: 1), isNull);
      expect(r.operationFor('fp', 'd1')!.status, CacheOpStatus.pending);
      expect(r.staleResults.last.why, 'operation_fingerprint_mismatch');
    });

    test('begin pending → cleanup_result success 落终态', () {
      final r = CacheOpsReducer();
      final op = r.beginCleanup(
        requestId: 'r1', deviceId: 'd1', dryRun: false, nowMs: 0);
      expect(op.status, CacheOpStatus.pending);
      final settled = r.onCleanupResult(
        cleanup('r1', 'd1', deleted: [
          {'item_id': 'x', 'content_key': 'sha256:aa', 'bytes': 5}
        ]),
        nowMs: 100);
      expect(settled!.status, CacheOpStatus.success);
      expect(settled.result!.freedBytes, 5);
    });

    test('有 failed 行 → partial', () {
      final r = CacheOpsReducer();
      r.beginCleanup(requestId: 'r1', deviceId: 'd1', dryRun: false, nowMs: 0);
      final s = r.onCleanupResult(
        cleanup('r1', 'd1', ok: true, failed: [
          {'item_id': 'z', 'reason': 'delete_failed'}
        ]),
        nowMs: 1);
      expect(s!.status, CacheOpStatus.partial);
    });

    test('generation_mismatch / generation_changed → generationConflict', () {
      for (final err in ['generation_mismatch', 'generation_changed']) {
        final r = CacheOpsReducer();
        r.beginCleanup(requestId: 'r1', deviceId: 'd1', dryRun: false, nowMs: 0);
        final s = r.onCleanupResult(
          cleanup('r1', 'd1', ok: false, error: err), nowMs: 1);
        expect(s!.status, CacheOpStatus.generationConflict,
            reason: 'error=$err');
      }
    });

    test('ok=false 其它 error → failed', () {
      final r = CacheOpsReducer();
      r.beginCleanup(requestId: 'r1', deviceId: 'd1', dryRun: false, nowMs: 0);
      final s = r.onCleanupResult(
        cleanup('r1', 'd1', ok: false, error: 'boom'), nowMs: 1);
      expect(s!.status, CacheOpStatus.failed);
    });

    test('幂等: 已终态后重复结果记陈旧、不再变更', () {
      final r = CacheOpsReducer();
      r.beginCleanup(requestId: 'r1', deviceId: 'd1', dryRun: false, nowMs: 0);
      final first = r.onCleanupResult(cleanup('r1', 'd1'), nowMs: 1);
      expect(first!.status, CacheOpStatus.success);
      final dup = r.onCleanupResult(cleanup('r1', 'd1', replay: true), nowMs: 2);
      expect(dup, isNull);
      expect(r.staleResults.single.why, 'already_terminal');
      // 原终态不被覆盖
      expect(r.operationFor('r1', 'd1')!.status, CacheOpStatus.success);
    });

    test('迟到: 落到不存在的键记陈旧 unknown_op', () {
      final r = CacheOpsReducer();
      final res = r.onCleanupResult(cleanup('ghost', 'd1'), nowMs: 1);
      expect(res, isNull);
      expect(r.staleResults.single.why, 'unknown_op');
    });
  });

  group('归约器 —— 设备隔离/并发/超时/能力', () {
    test('同一 request_id 两台设备互不干扰', () {
      final r = CacheOpsReducer();
      r.beginCleanup(requestId: 'r1', deviceId: 'd1', dryRun: false, nowMs: 0);
      r.beginCleanup(requestId: 'r1', deviceId: 'd2', dryRun: false, nowMs: 0);
      r.onCleanupResult(cleanup('r1', 'd1'), nowMs: 1);
      expect(r.operationFor('r1', 'd1')!.status, CacheOpStatus.success);
      expect(r.operationFor('r1', 'd2')!.status, CacheOpStatus.pending);
    });

    test('同设备悬挂中再 begin 同键不覆盖(并发保护)', () {
      final r = CacheOpsReducer();
      final a = r.beginCleanup(
        requestId: 'r1', deviceId: 'd1', dryRun: false, nowMs: 0);
      final b = r.beginCleanup(
        requestId: 'r1', deviceId: 'd1', dryRun: true, nowMs: 5);
      expect(identical(a, b) || (a.startedAtMs == b.startedAtMs), isTrue);
      expect(b.dryRun, isFalse); // 保留了第一次登记
    });

    test('超时收割: 悬挂超过 timeout 转 timeout', () {
      final r = CacheOpsReducer(timeoutMs: 1000);
      r.beginCleanup(requestId: 'r1', deviceId: 'd1', dryRun: false, nowMs: 0);
      expect(r.expire(500), isEmpty); // 未到期
      final expired = r.expire(1000);
      expect(expired.single.status, CacheOpStatus.timeout);
      // 超时后迟到结果不能完成它(已终态)
      final late = r.onCleanupResult(cleanup('r1', 'd1'), nowMs: 1200);
      expect(late, isNull);
    });

    test('不支持能力 → 直接 unsupported, 从不悬挂', () {
      final r = CacheOpsReducer();
      final op = r.beginCleanup(
        requestId: 'r1', deviceId: 'd1', dryRun: false, nowMs: 0,
        supported: false);
      expect(op.status, CacheOpStatus.unsupported);
      expect(op.isTerminal, isTrue);
    });

    test('离线 → 直接 offline', () {
      final r = CacheOpsReducer();
      final op = r.beginCleanup(
        requestId: 'r1', deviceId: 'd1', dryRun: false, nowMs: 0,
        online: false);
      expect(op.status, CacheOpStatus.offline);
    });

    test('重试用新 request_id 重开, 旧终态保留', () {
      final r = CacheOpsReducer(timeoutMs: 10);
      r.beginCleanup(requestId: 'r1', deviceId: 'd1', dryRun: false, nowMs: 0);
      r.expire(10); // r1 超时
      final retry = r.retryCleanup(
        newRequestId: 'r2', deviceId: 'd1', dryRun: false, nowMs: 20);
      expect(retry.status, CacheOpStatus.pending);
      expect(r.operationFor('r1', 'd1')!.status, CacheOpStatus.timeout);
      expect(r.operationFor('r2', 'd1')!.status, CacheOpStatus.pending);
    });

    test('inventory 悬挂 → inventory_result 落 success', () {
      final r = CacheOpsReducer();
      r.beginInventory(requestId: 'q1', deviceId: 'd1', nowMs: 0);
      final s = r.onInventoryResult(
        CacheInventoryResult.fromMap({
          'request_id': 'q1', 'device_id': 'd1',
          'items': [
            {'item_id': 'a', 'bytes': 10, 'protection_reasons': []}
          ],
        }),
        nowMs: 1);
      expect(s!.status, CacheOpStatus.success);
      expect(s.inventory!.items.single.itemId, 'a');
    });

    test('hasPending 反映悬挂', () {
      final r = CacheOpsReducer();
      expect(r.hasPending('d1'), isFalse);
      r.beginCleanup(requestId: 'r1', deviceId: 'd1', dryRun: false, nowMs: 0);
      expect(r.hasPending('d1'), isTrue);
      r.onCleanupResult(cleanup('r1', 'd1'), nowMs: 1);
      expect(r.hasPending('d1'), isFalse);
    });
  });

  group('wire payload target ↔ fingerprint 对齐', () {
    test('Commands.cacheCleanup 必须把 device_id 写进 payload', () {
      final payload = Commands.cacheCleanup(
        requestId: 'r1',
        mode: 'selected',
        itemIds: const ['a'],
        dryRun: true,
        expectedPushId: 'g1',
        reason: 'manual',
        deviceId: 'd1',
      );
      expect(payload['device_id'], 'd1');
      expect(payload.containsKey('group_id'), isFalse);
      // controller-stored fingerprint must use the same target the payload
      // will produce on broker/player (device:<id>, not "all").
      final fp = cacheCleanupFingerprint(
        target: 'device:${payload['device_id']}',
        mode: payload['mode'] as String,
        dryRun: payload['dry_run'] as bool,
        itemIds: (payload['item_ids'] as List).cast<String>(),
        expectedPushId: payload['expected_push_id'] as String?,
        reason: payload['reason'] as String,
      );
      expect(fp, isNotEmpty);
      // Omitting deviceId produces target "all" — that must NOT match the
      // device-scoped fingerprint the controller stores for a single-device op.
      final allFp = cacheCleanupFingerprint(
        target: 'all',
        mode: 'selected',
        dryRun: true,
        itemIds: const ['a'],
        expectedPushId: 'g1',
        reason: 'manual',
      );
      expect(fp, isNot(equals(allFp)));
    });

    test('Commands.cacheInventory 也携带 device_id', () {
      final payload =
          Commands.cacheInventory(requestId: 'q1', deviceId: 'd1');
      expect(payload['device_id'], 'd1');
      expect(payload['request_id'], 'q1');
    });
  });
}
