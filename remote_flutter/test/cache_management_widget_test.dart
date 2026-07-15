import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/messages.dart';
import 'package:remote_flutter/state/cache_ops.dart';
import 'package:remote_flutter/state/wall_state.dart';
import 'package:remote_flutter/ui/cache_management.dart';

/// §27/§28 缓存管理 UI 的 widget 测试:终态互不混淆、演练零变更、提交必确认、
/// 逐项保护原因可见、窄屏不溢出、重试入口。用纯展示件 [CacheOpResultTile] 与容器
/// [CacheManagementView] 驱动 —— 前者无需网络,后者用直接构造的 [WallState]。
CacheOperation _op(
  CacheOpStatus status, {
  String kind = 'cleanup',
  bool dryRun = false,
  CacheCleanupResult? result,
  CacheInventoryResult? inventory,
  String detail = '',
}) =>
    CacheOperation(
      requestId: 'r1',
      deviceId: 'd1',
      kind: kind,
      status: status,
      startedAtMs: 0,
      dryRun: dryRun,
      settledAtMs: status == CacheOpStatus.pending ? 0 : 1,
      result: result,
      inventory: inventory,
      detail: detail,
    );

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('cacheReasonLabel 用真实线协议 token(播放端发的是无前缀原词)', () {
    // 播放端(CacheReferenceSnapshot.kt / cache_refs.py)发的是无前缀原词:
    // playing/active/prepared/inflight/last_task/pinned/shared_content,
    // 以及 not_found/delete_failed 与代次类 generation_*。UI 必须认这些。
    test('全部保护 token 都有可读中文,含 prepared 与 pinned', () {
      expect(cacheReasonLabel('playing'), '正在播放');
      expect(cacheReasonLabel('active'), '当前列表引用');
      expect(cacheReasonLabel('prepared'), '正在缓冲/预备');
      expect(cacheReasonLabel('inflight'), '正在下载');
      expect(cacheReasonLabel('last_task'), '断电续播引用');
      expect(cacheReasonLabel('pinned'), '已固定');
      expect(cacheReasonLabel('shared_content'), '被其它项共享');
    });

    test('跳过/失败/代次 token 保持可读', () {
      expect(cacheReasonLabel('not_found'), '未找到');
      expect(cacheReasonLabel('delete_failed'), '删除失败');
      expect(cacheReasonLabel('generation_mismatch'), '采纳代次不符');
      expect(cacheReasonLabel('generation_changed'), '清理期间代次变化');
    });

    test('未知 token 原样透出,空串给占位', () {
      expect(cacheReasonLabel('weird_future_reason'), 'weird_future_reason');
      expect(cacheReasonLabel(''), '—');
    });
  });

  group('CacheOpResultTile 终态互不混淆', () {
    testWidgets('success 无重试', (t) async {
      await t.pumpWidget(_host(CacheOpResultTile(
          op: _op(CacheOpStatus.success,
              result: CacheCleanupResult.fromMap(const {
                'request_id': 'r1', 'device_id': 'd1', 'ok': true,
                'deleted': [
                  {'item_id': 'a', 'content_key': 'k', 'bytes': 2048}
                ],
                'freed_bytes': 2048,
              })),
          onRetry: () {})));
      expect(find.text('清理 · 成功'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('unsupported 明确且不可重试', (t) async {
      await t.pumpWidget(_host(CacheOpResultTile(
          op: _op(CacheOpStatus.unsupported, detail: '未广告 cache_cleanup_v1'),
          onRetry: () {})));
      expect(find.text('清理 · 该设备不支持缓存清理'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('offline / timeout / partial / failed / generationConflict 各自可见',
        (t) async {
      for (final e in {
        CacheOpStatus.offline: '清理 · 设备离线',
        CacheOpStatus.timeout: '清理 · 超时无响应',
        CacheOpStatus.partial: '清理 · 部分成功',
        CacheOpStatus.failed: '清理 · 失败',
        CacheOpStatus.generationConflict: '清理 · 代次冲突(未删除任何内容)',
      }.entries) {
        await t.pumpWidget(_host(CacheOpResultTile(op: _op(e.key), onRetry: () {})));
        expect(find.text(e.value), findsOneWidget, reason: '${e.key}');
        // 这些非成功终态都提供重试入口。
        expect(find.text('重试'), findsOneWidget, reason: '${e.key}');
      }
    });

    testWidgets('dry-run success 显示「未删除」而非已删除', (t) async {
      await t.pumpWidget(_host(CacheOpResultTile(
          op: _op(CacheOpStatus.success, dryRun: true,
              result: CacheCleanupResult.fromMap(const {
                'request_id': 'r1', 'device_id': 'd1', 'ok': true, 'dry_run': true,
                'deleted': [
                  {'item_id': 'a', 'bytes': 1024},
                  {'item_id': 'b', 'bytes': 1024}
                ],
                'freed_bytes': 2048,
              })))));
      expect(find.textContaining('演练'), findsOneWidget);
      expect(find.textContaining('未删除'), findsOneWidget);
    });

    testWidgets('retry 回调被触发', (t) async {
      var tapped = false;
      await t.pumpWidget(_host(CacheOpResultTile(
          op: _op(CacheOpStatus.failed), onRetry: () => tapped = true)));
      await t.tap(find.text('重试'));
      expect(tapped, isTrue);
    });
  });

  group('CacheManagementView 能力真值 / 离线闸门', () {
    testWidgets('无缓存能力 → 明确不可操作,无动作按钮', (t) async {
      final ws = WallState();
      addTearDown(ws.dispose);
      ws.debugIngestWall(WallSnapshot(devices: const [
        DeviceStatus(
            deviceId: 'd1', groupId: 'g', state: 'playing', online: true),
      ]));
      await t.pumpWidget(_host(
          CacheManagementView(state: ws, deviceId: 'd1', deviceName: 'D1')));
      expect(find.textContaining('未广告缓存管理能力'), findsOneWidget);
      expect(find.text('演练(不删除)'), findsNothing);
    });

    testWidgets('有能力但离线 → 离线提示', (t) async {
      final ws = WallState();
      addTearDown(ws.dispose);
      ws.debugIngestWall(WallSnapshot(devices: const [
        DeviceStatus(
            deviceId: 'd1', groupId: 'g', state: 'idle', online: false,
            capabilities: ['cache_cleanup_v1', 'cache_inventory_v1']),
      ]));
      await t.pumpWidget(_host(
          CacheManagementView(state: ws, deviceId: 'd1', deviceName: 'D1')));
      expect(find.textContaining('设备当前离线'), findsOneWidget);
    });
  });

  WallState _supportedDevice() {
    final ws = WallState();
    ws.debugIngestWall(WallSnapshot(devices: const [
      DeviceStatus(
        deviceId: 'd1', groupId: 'g', state: 'playing', online: true,
        capabilities: ['cache_cleanup_v1', 'cache_inventory_v1'],
        cacheSummary: CacheSummary(
            readyItems: 5, totalBytes: 5 * 1024 * 1024,
            reclaimableItems: 2, reclaimableBytes: 2 * 1024 * 1024,
            protectedItems: 3, inflightItems: 1),
      ),
    ]));
    return ws;
  }

  group('CacheManagementView 提交必确认 / 摘要 / 窄屏', () {
    testWidgets('摘要卡展示 §26 标量', (t) async {
      final ws = _supportedDevice();
      addTearDown(ws.dispose);
      await t.pumpWidget(_host(
          CacheManagementView(state: ws, deviceId: 'd1', deviceName: 'D1')));
      expect(find.textContaining('可回收'), findsOneWidget);
      expect(find.textContaining('受保护'), findsOneWidget);
      expect(find.text('演练(不删除)'), findsOneWidget);
    });

    testWidgets('没有成功演练时真实清理入口不可用', (t) async {
      final ws = _supportedDevice();
      addTearDown(ws.dispose);
      await t.pumpWidget(_host(
          CacheManagementView(state: ws, deviceId: 'd1', deviceName: 'D1')));
      expect(find.text('请先演练'), findsOneWidget);
      // Stable key — FilledButton.icon label ancestry is flaky across Flutter SDKs.
      final commit = find.byKey(const Key('cache-commit-cleanup'));
      expect(commit, findsOneWidget);
      expect(t.widget<FilledButton>(commit).onPressed, isNull);
      expect(ws.cacheOperations.where((o) => o.kind == 'cleanup'), isEmpty);
    });

    testWidgets('成功演练后确认才下发精确候选清理(无乐观成功)', (t) async {
      final ws = _supportedDevice();
      // Keep dry-run pending so debugIngest can settle it; real commit later
      // re-enables outbound so undeliverable send still fails closed.
      ws.debugHoldOutboundCache = true;
      addTearDown(ws.dispose);
      await t.pumpWidget(_host(
          CacheManagementView(state: ws, deviceId: 'd1', deviceName: 'D1')));
      await t.tap(find.text('演练(不删除)'));
      await t.pump();
      final dry = ws.cacheOperations.singleWhere(
          (o) => o.kind == 'cleanup' && o.dryRun);
      expect(dry.status, CacheOpStatus.pending);
      ws.debugIngestCacheCleanupResult({
        'request_id': dry.requestId,
        'device_id': 'd1',
        'operation_fingerprint': dry.operationFingerprint,
        'ok': true,
        'dry_run': true,
        'observed_push_id': 'push-1',
        'deleted': const [
          {'item_id': 'old-a', 'content_key': 'sha256:a', 'bytes': 100}
        ],
        'skipped': const [],
        'failed': const [],
        'freed_bytes': 100,
      });
      await t.pump();
      expect(find.text('清理 1 项'), findsOneWidget);
      // Real commit must exercise undeliverable fail-closed path.
      ws.debugHoldOutboundCache = false;
      await t.tap(find.text('清理 1 项'));
      await t.pumpAndSettle();
      expect(find.text('确认清理缓存?'), findsOneWidget);
      await t.tap(find.text('确认清理'));
      await t.pumpAndSettle();
      // 链路未就绪 → 投递失败即收割为 timeout 终态(不伪造成功)。
      final ops = ws.cacheOperations.where((o) => o.kind == 'cleanup').toList();
      expect(ops.length, 2);
      expect(ops.singleWhere((o) => o.dryRun).status, CacheOpStatus.success);
      expect(ops.singleWhere((o) => !o.dryRun).status,
          isNot(CacheOpStatus.success));
    });

    testWidgets('清单逐项渲染:可回收 / 受保护 + 原因可见', (t) async {
      final items = [
        InventoryItem.fromMap(const {
          'item_id': 'clip-a', 'bytes': 1024, 'protection_reasons': []
        }),
        InventoryItem.fromMap(const {
          'item_id': 'clip-b', 'bytes': 2048,
          'protection_reasons': ['playing']
        }),
      ];
      await t.pumpWidget(_host(SingleChildScrollView(
          child: CacheInventoryList(items: items))));
      expect(find.text('clip-a'), findsOneWidget);
      expect(find.text('clip-b'), findsOneWidget);
      expect(find.textContaining('可回收'), findsWidgets);
      expect(find.textContaining('正在播放'), findsOneWidget);
      expect(find.textContaining('缓存清单(2 项)'), findsOneWidget);
    });

    testWidgets('窄屏(320 宽)动作条不溢出', (t) async {
      final ws = _supportedDevice();
      addTearDown(ws.dispose);
      await t.pumpWidget(_host(SizedBox(
        width: 320,
        child: CacheManagementView(
            state: ws, deviceId: 'd1', deviceName: 'D1'),
      )));
      await t.pumpAndSettle();
      // flutter_test 把 RenderFlex overflow 记为测试异常;窄屏无溢出则为 null。
      expect(t.takeException(), isNull);
    });
  });

  group('缓存与播放列表解耦', () {
    test('演练/清理只由缓存流产生,播放列表操作不触发 cache 操作', () {
      final ws = _supportedDevice();
      addTearDown(ws.dispose);
      // 播放列表草稿的行删除是纯 draft 变更,与 WallState 缓存归约器无关:
      // 这里直接断言在未走缓存流时归约器为空(结构性隔离)。
      expect(ws.cacheOperations, isEmpty);
      // sendPlaylist 会因链路未就绪抛错,但它绝不应产生任何 cache 操作(缓存清理
      // 是独立入口,不搭 playlist 便车)。
      expect(
        () => ws.sendPlaylist(
          playlistId: 'PL', groupId: 'g', sync: false,
          loopMode: LoopMode.all, mode: 'replace',
          items: const [
            MediaItem(itemId: 'a', name: 'a', url: 'http://x/a', type: 'video'),
          ],
        ),
        throwsA(isA<StateError>()),
      );
      expect(ws.cacheOperations.where((o) => o.kind == 'cleanup'), isEmpty);
      expect(ws.cacheOperations.where((o) => o.kind == 'inventory'), isEmpty);
    });
  });
}
