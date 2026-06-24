import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/p2p/handshake.dart';

/// 可控调度器：捕获定时回调，测试里手动触发“超时”，无需真实等待。
class _FakeScheduler {
  final List<void Function()> pending = [];

  Timer schedule(Duration d, void Function() cb) {
    pending.add(cb);
    // 返回一个不会自己触发的真实 Timer（长延时，立即被编排器持有/取消）。
    return Timer(const Duration(days: 1), () {});
  }

  void fireAll() {
    final cbs = List<void Function()>.from(pending);
    pending.clear();
    for (final cb in cbs) {
      cb();
    }
  }
}

void main() {
  group('HandshakeSession (§9.1–9.2)', () {
    test('收齐全部 target 才 complete', () {
      final s = HandshakeSession(
        prepareId: 'p1',
        groupId: 'g',
        playlistId: 'pl',
        targets: {'a', 'b'},
      );
      expect(s.complete, isFalse);
      expect(s.onReady(deviceId: 'a', prepareId: 'p1'), isFalse);
      expect(s.complete, isFalse);
      final justDone = s.onReady(deviceId: 'b', prepareId: 'p1');
      expect(justDone, isTrue);
      expect(s.complete, isTrue);
    });

    test('prepareId 不匹配的 ready 被忽略', () {
      final s = HandshakeSession(
          prepareId: 'p1', groupId: 'g', playlistId: 'pl', targets: {'a'});
      expect(s.onReady(deviceId: 'a', prepareId: 'WRONG'), isFalse);
      expect(s.ready, isEmpty);
    });

    test('非目标设备 / ready=false 被忽略', () {
      final s = HandshakeSession(
          prepareId: 'p1', groupId: 'g', playlistId: 'pl', targets: {'a'});
      expect(s.onReady(deviceId: 'zzz', prepareId: 'p1'), isFalse);
      expect(s.onReady(deviceId: 'a', prepareId: 'p1', ready: false), isFalse);
      expect(s.ready, isEmpty);
    });

    test('prepareId 缺失（向后兼容）放行', () {
      final s = HandshakeSession(
          prepareId: 'p1', groupId: 'g', playlistId: 'pl', targets: {'a'});
      final done = s.onReady(deviceId: 'a', prepareId: null);
      expect(done, isTrue);
    });

    test('playAtTargets：收齐=全部，超时=仅已就绪', () {
      final s = HandshakeSession(
          prepareId: 'p1', groupId: 'g', playlistId: 'pl', targets: {'a', 'b'});
      s.onReady(deviceId: 'a', prepareId: 'p1');
      expect(s.playAtTargets(timedOut: true), {'a'});
      expect(s.playAtTargets(timedOut: false), {'a', 'b'});
    });

    test('playAtPayload: play_at = controllerNow + bufferMs', () {
      final s = HandshakeSession(
        prepareId: 'p1',
        groupId: 'g',
        playlistId: 'pl',
        targets: {'a'},
        startIndex: 2,
        seekMs: 500,
        bufferMs: 1500,
      );
      final p = s.playAtPayload(10000);
      expect(p['play_at'], 11500);
      expect(p['playlist_id'], 'pl');
      expect(p['group_id'], 'g');
      expect(p['start_index'], 2);
      expect(p['seek_ms'], 500);
    });

    test('markFired 幂等', () {
      final s = HandshakeSession(
          prepareId: 'p1', groupId: 'g', playlistId: 'pl', targets: {'a'});
      expect(s.markFired(), isTrue);
      expect(s.markFired(), isFalse);
    });
  });

  group('HandshakeOrchestrator (§9)', () {
    test('收齐 ready → 立即 onPlayAt(全部 target)', () {
      Set<String>? firedTargets;
      Map<String, dynamic>? firedPayload;
      final orch = HandshakeOrchestrator(
        nowFn: () => 10000,
        scheduler: _FakeScheduler().schedule,
        onPlayAt: (t, p) {
          firedTargets = t;
          firedPayload = p;
        },
      );
      orch.begin(
        prepareId: 'p1',
        groupId: 'g',
        playlistId: 'pl',
        targets: {'a', 'b'},
        bufferMs: 2000,
      );
      orch.onReady(deviceId: 'a', prepareId: 'p1');
      expect(firedTargets, isNull); // 还没收齐
      orch.onReady(deviceId: 'b', prepareId: 'p1');
      expect(firedTargets, {'a', 'b'});
      expect(firedPayload!['play_at'], 12000);
      expect(orch.pending, 0); // 点火后移除
    });

    test('超时 → onPlayAt(仅已就绪者)', () {
      final sched = _FakeScheduler();
      Set<String>? firedTargets;
      final orch = HandshakeOrchestrator(
        nowFn: () => 5000,
        scheduler: sched.schedule,
        onPlayAt: (t, p) => firedTargets = t,
      );
      orch.begin(
        prepareId: 'p1',
        groupId: 'g',
        playlistId: 'pl',
        targets: {'a', 'b', 'c'},
        readyTimeoutMs: 2000,
      );
      orch.onReady(deviceId: 'a', prepareId: 'p1');
      // 触发超时
      sched.fireAll();
      expect(firedTargets, {'a'});
    });

    test('超时但无人就绪 → 不发 play_at', () {
      final sched = _FakeScheduler();
      var fired = false;
      final orch = HandshakeOrchestrator(
        nowFn: () => 1,
        scheduler: sched.schedule,
        onPlayAt: (_, __) => fired = true,
      );
      orch.begin(
          prepareId: 'p1', groupId: 'g', playlistId: 'pl', targets: {'a'});
      sched.fireAll();
      expect(fired, isFalse);
    });

    test('ready 按 group+playlist 回退匹配（prepareId 缺失）', () {
      Set<String>? fired;
      final orch = HandshakeOrchestrator(
        nowFn: () => 0,
        scheduler: _FakeScheduler().schedule,
        onPlayAt: (t, _) => fired = t,
      );
      orch.begin(
          prepareId: 'p1', groupId: 'lobby', playlistId: 'pl-1', targets: {'a'});
      orch.onReady(deviceId: 'a', groupId: 'lobby', playlistId: 'pl-1');
      expect(fired, {'a'});
    });

    test('收齐后超时回调不再二次点火（幂等）', () {
      final sched = _FakeScheduler();
      var count = 0;
      final orch = HandshakeOrchestrator(
        nowFn: () => 0,
        scheduler: sched.schedule,
        onPlayAt: (_, __) => count++,
      );
      orch.begin(
          prepareId: 'p1', groupId: 'g', playlistId: 'pl', targets: {'a'});
      orch.onReady(deviceId: 'a', prepareId: 'p1'); // 收齐点火
      sched.fireAll(); // 超时回调到达，但已点火
      expect(count, 1);
    });
  });
}
