import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/p2p/wall_aggregator.dart';
import 'package:remote_flutter/protocol/messages.dart';

DeviceStatus _status(
  String id, {
  String group = 'lobby',
  String state = 'playing',
  bool online = true,
  String? playlistId,
  int? lastSeen,
}) =>
    DeviceStatus(
      deviceId: id,
      groupId: group,
      state: state,
      online: online,
      playlistId: playlistId,
      lastSeen: lastSeen,
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
}
