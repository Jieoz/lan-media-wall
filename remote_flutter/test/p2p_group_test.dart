import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/p2p/group_expander.dart';
import 'package:remote_flutter/protocol/messages.dart';

DeviceStatus _dev(String id, String group) =>
    DeviceStatus(deviceId: id, groupId: group, online: true);

void main() {
  final devices = [
    _dev('a', 'lobby'),
    _dev('b', 'lobby'),
    _dev('c', 'hall'),
  ];

  group('GroupExpander.expand (§14.3 客户端侧扇出)', () {
    test('group:<gid> → 组内全部成员', () {
      final r = GroupExpander.expand('group:lobby', devices: devices);
      expect(r.toSet(), {'a', 'b'});
    });

    test('player:<id> → 单成员', () {
      expect(GroupExpander.expand('player:c', devices: devices), ['c']);
    });

    test('all / broker → 全体', () {
      expect(GroupExpander.expand('all', devices: devices).toSet(),
          {'a', 'b', 'c'});
      expect(GroupExpander.expand('broker', devices: devices).toSet(),
          {'a', 'b', 'c'});
    });

    test('connected 过滤掉未连接成员', () {
      final r = GroupExpander.expand(
        'group:lobby',
        devices: devices,
        connected: {'a'}, // b 未连
      );
      expect(r, ['a']);
    });

    test('player 指向未连接设备 → 空', () {
      final r = GroupExpander.expand('player:b',
          devices: devices, connected: {'a'});
      expect(r, isEmpty);
    });

    test('去重 + 稳定顺序', () {
      final dup = [_dev('a', 'g'), _dev('a', 'g'), _dev('x', 'g')];
      final r = GroupExpander.expand('group:g', devices: dup);
      expect(r, ['a', 'x']);
    });

    test('空组 → 空列表', () {
      expect(GroupExpander.expand('group:nope', devices: devices), isEmpty);
    });
  });

  group('GroupExpander.groupsOf', () {
    test('按 group_id 归并，过滤未连接', () {
      final g = GroupExpander.groupsOf(devices, connected: {'a', 'c'});
      expect(g['lobby'], ['a']);
      expect(g['hall'], ['c']);
    });

    test('忽略空 group_id / 空 device_id', () {
      final mixed = [
        _dev('a', 'lobby'),
        _dev('b', ''), // 无组
        _dev('', 'lobby'), // 无 id
      ];
      final g = GroupExpander.groupsOf(mixed);
      expect(g['lobby'], ['a']);
      expect(g.length, 1);
    });
  });
}
