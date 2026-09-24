import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/ui/device_wall_filter.dart';

void main() {
  group('DeviceWallFilter', () {
    test('isAll covers null/empty/sentinel', () {
      expect(DeviceWallFilter.isAll(null), isTrue);
      expect(DeviceWallFilter.isAll(''), isTrue);
      expect(DeviceWallFilter.isAll(DeviceWallFilter.all), isTrue);
      expect(DeviceWallFilter.isAll('g1'), isFalse);
    });

    test('matches keeps all when filter is all', () {
      expect(
        DeviceWallFilter.matches(deviceGroupId: 'a', filterGroupId: null),
        isTrue,
      );
      expect(
        DeviceWallFilter.matches(deviceGroupId: null, filterGroupId: null),
        isTrue,
      );
    });

    test('matches requires exact group when filtered', () {
      expect(
        DeviceWallFilter.matches(deviceGroupId: 'g1', filterGroupId: 'g1'),
        isTrue,
      );
      expect(
        DeviceWallFilter.matches(deviceGroupId: 'g2', filterGroupId: 'g1'),
        isFalse,
      );
      expect(
        DeviceWallFilter.matches(deviceGroupId: null, filterGroupId: 'g1'),
        isFalse,
      );
      expect(
        DeviceWallFilter.matches(deviceGroupId: '', filterGroupId: 'g1'),
        isFalse,
      );
    });

    test('apply filters list by groupOf', () {
      final devices = [
        ('d1', 'g1'),
        ('d2', 'g2'),
        ('d3', null),
        ('d4', 'g1'),
      ];
      final filtered = DeviceWallFilter.apply(
        devices,
        filterGroupId: 'g1',
        groupOf: (e) => e.$2,
      );
      expect(filtered.map((e) => e.$1).toList(), ['d1', 'd4']);

      final all = DeviceWallFilter.apply(
        devices,
        filterGroupId: DeviceWallFilter.all,
        groupOf: (e) => e.$2,
      );
      expect(all.length, 4);
    });
  });

  group('DeviceLinkCensus', () {
    test('P2P 控制端：已连接算 P2P，失败算连不上，发现中不计', () {
      final census = DeviceLinkCensus.count(
        controllerIsP2p: true,
        devices: const [
          (connected: true, failed: false),
          (connected: true, failed: false),
          (connected: false, failed: true),
          (connected: false, failed: false),
        ],
      );
      expect(census.p2pConnected, 2);
      expect(census.brokerConnected, 0);
      expect(census.unreachable, 1);
      expect(census.label, 'P2P 已连接 2 · Broker 0 · 连不上 1');
      expect(
        DeviceLinkCensus.cardMark(controllerIsP2p: true, connected: true),
        'P2P',
      );
      expect(
        DeviceLinkCensus.cardMark(controllerIsP2p: true, connected: false),
        isNull,
      );
    });

    test('Broker 控制端：已连接算 Broker，不把在线设备标成 P2P', () {
      final census = DeviceLinkCensus.count(
        controllerIsP2p: false,
        devices: const [
          (connected: true, failed: false),
          (connected: false, failed: true),
        ],
      );
      expect(census.p2pConnected, 0);
      expect(census.brokerConnected, 1);
      expect(census.unreachable, 1);
      expect(
        DeviceLinkCensus.cardMark(controllerIsP2p: false, connected: true),
        'Broker',
      );
    });
  });
}
