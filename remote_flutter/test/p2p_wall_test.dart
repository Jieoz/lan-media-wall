import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/p2p/wall_aggregator.dart';
import 'package:remote_flutter/protocol/messages.dart';
import 'package:remote_flutter/state/media_progress.dart';

DeviceStatus _status(
  String id, {
  String group = 'lobby',
  String state = 'playing',
  bool online = true,
  String? playlistId,
  String? pushId,
  int? lastSeen,
  Map<String, String> cache = const {},
}) =>
    DeviceStatus(
      deviceId: id,
      groupId: group,
      state: state,
      online: online,
      playlistId: playlistId,
      pushId: pushId,
      lastSeen: lastSeen,
      cache: cache,
    );

void main() {
  group('WallAggregator (§14.3 状态墙本地聚合)', () {
    test('mergeStatus 累积设备，snapshot 按 id 排序', () {
      final agg = WallAggregator();
      agg.mergeStatus(_status('b'), seenAt: 100);
      agg.mergeStatus(_status('a'), seenAt: 100);
      final snap = agg.snapshot(serverTime: 999);
      expect(snap.serverTime, 999);
      expect(snap.devices.map((d) => d.deviceId), ['a', 'b']);
    });

    test('同 device_id 后帧覆盖前帧', () {
      final agg = WallAggregator();
      agg.mergeStatus(_status('a', state: 'idle'), seenAt: 1);
      agg.mergeStatus(_status('a', state: 'playing'), seenAt: 2);
      expect(agg.deviceCount, 1);
      expect(agg.snapshot(serverTime: 0).devices.first.state, 'playing');
    });

    test('缺 last_seen 用收到时刻补齐', () {
      final agg = WallAggregator();
      final merged = agg.mergeStatus(_status('a'), seenAt: 12345);
      expect(merged.lastSeen, 12345);
    });

    test('带 last_seen 则保留原值', () {
      final agg = WallAggregator();
      final merged =
          agg.mergeStatus(_status('a', lastSeen: 555), seenAt: 999);
      expect(merged.lastSeen, 555);
    });

    test('buildGroups 按 group_id 归并 + 成员排序', () {
      final agg = WallAggregator();
      agg.mergeStatus(_status('a2', group: 'lobby'));
      agg.mergeStatus(_status('a1', group: 'lobby'));
      agg.mergeStatus(_status('c', group: 'hall', playlistId: 'pl-hall'));
      final groups = agg.buildGroups();
      final lobby = groups.firstWhere((g) => g.groupId == 'lobby');
      expect(lobby.members, ['a1', 'a2']);
      final hall = groups.firstWhere((g) => g.groupId == 'hall');
      expect(hall.playlistId, 'pl-hall');
    });

    test('空 group_id 归入 (未分组)', () {
      final agg = WallAggregator();
      agg.mergeStatus(_status('a', group: ''));
      final groups = agg.buildGroups();
      expect(groups.any((g) => g.groupId == '(未分组)'), isTrue);
    });

    test('markOffline 保留最后一帧但置 online=false', () {
      final agg = WallAggregator();
      agg.mergeStatus(_status('a', online: true));
      agg.markOffline('a');
      final d = agg.snapshot(serverTime: 0).devices.first;
      expect(d.online, isFalse);
      expect(d.deviceId, 'a');
    });

    test('remove / clear', () {
      final agg = WallAggregator();
      agg.mergeStatus(_status('a'));
      agg.mergeStatus(_status('b'));
      agg.remove('a');
      expect(agg.deviceCount, 1);
      agg.clear();
      expect(agg.deviceCount, 0);
    });
  });

  // §6.4 (E0001) — prove the P2P path actually FEEDS the shared progress
  // machine, not merely that a sender emits a percent. This mirrors exactly
  // what WallState._onWall does: read the P2P aggregator's snapshot and ingest
  // every device's status.cache into the one machine. Observable effect: the
  // machine's aggregated per-device / batch progress reflects P2P-delivered
  // status, monotonically, and never reaches 100 before `ready`.
  group('P2P → shared progress machine consumption (§6.4)', () {
    // Drive the aggregator the way the p2p coordinator does on inbound `status`
    // frames, then ingest its snapshot the way _onWall does.
    void pump(WallAggregator agg, MediaProgressMachine m, DeviceStatus s,
        {int gen = 1}) {
      agg.mergeStatus(s, seenAt: 1);
      for (final d in agg.snapshot(serverTime: 0).devices) {
        m.ingestDeviceCache(d.deviceId, d.cache, gen);
      }
    }

    test('multi-chunk P2P status advances machine monotonically, caps <100', () {
      final agg = WallAggregator();
      final m = MediaProgressMachine();
      pump(agg, m, _status('a', cache: {'x': 'downloading:20%'}));
      expect(m.progressFor('a', 'x')!.percent, 20);
      pump(agg, m, _status('a', cache: {'x': 'downloading:100%'}));
      // producer over-reports 100 mid-download; machine masks it until ready
      expect(m.progressFor('a', 'x')!.percent, 99);
      pump(agg, m, _status('a', cache: {'x': 'ready'}));
      expect(m.progressFor('a', 'x')!.percent, 100);
      expect(m.progressFor('a', 'x')!.isReady, isTrue);
    });

    test('concurrent P2P fan-out aggregates into a batch percent', () {
      final agg = WallAggregator();
      final m = MediaProgressMachine();
      pump(agg, m, _status('a', cache: {'x': 'downloading:50%'}));
      pump(agg, m, _status('b', cache: {'x': 'downloading:10%'}));
      final batch = m.batchProgress(['a', 'b'], (_) => 1);
      expect(batch.totalDevices, 2);
      expect(batch.percent, 30); // mean(50,10)
      expect(batch.completeDevices, 0);
    });

    test('a stale P2P frame from a superseded job is dropped', () {
      final agg = WallAggregator();
      final m = MediaProgressMachine();
      pump(agg, m, _status('a', cache: {'x': 'downloading:70%'}), gen: 2);
      // a lingering status from the previous job (gen 1) arrives late
      pump(agg, m, _status('a', cache: {'x': 'downloading:95%'}), gen: 1);
      expect(m.progressFor('a', 'x')!.generation, 2);
      expect(m.progressFor('a', 'x')!.percent, 70);
    });
  });
}
