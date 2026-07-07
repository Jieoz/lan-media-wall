import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/messages.dart';

void main() {
  group('MediaItem 序列化往返 (§6.1)', () {
    test('toMap 仅含非空可选字段', () {
      const item = MediaItem(
        itemId: 'a1',
        type: 'image',
        name: 'logo.png',
        url: 'http://nas.local/logo.png',
        durationMs: 8000,
      );
      final m = item.toMap();
      expect(m['item_id'], 'a1');
      expect(m['type'], 'image');
      expect(m['duration_ms'], 8000);
      expect(m['loop'], false);
      expect(m.containsKey('size'), isFalse);
      expect(m.containsKey('sha256'), isFalse);
    });

    test('fromMap(toMap) 往返一致', () {
      const item = MediaItem(
        itemId: 'v1',
        type: 'video',
        name: 'promo.mp4',
        url: 'http://nas.local/promo.mp4',
        size: 1024,
        sha256: 'abc',
        durationMs: 60000,
        loop: true,
      );
      final back = MediaItem.fromMap(item.toMap());
      expect(back.itemId, item.itemId);
      expect(back.type, item.type);
      expect(back.url, item.url);
      expect(back.size, 1024);
      expect(back.sha256, 'abc');
      expect(back.durationMs, 60000);
      expect(back.loop, isTrue);
    });

    test('isImage 判定', () {
      const img = MediaItem(itemId: 'i', type: 'image', name: 'n', url: 'u');
      const vid = MediaItem(itemId: 'v', type: 'video', name: 'n', url: 'u');
      expect(img.isImage, isTrue);
      expect(vid.isImage, isFalse);
    });
  });

  group('DeviceStatus.fromMap (§5.1)', () {
    test('完整字段解析', () {
      final m = {
        'device_id': 'win-01',
        'device_name': '大厅左屏',
        'online': true,
        'group_id': 'lobby',
        'state': 'playing',
        'current': {
          'item_id': 'a1',
          'name': 'promo.mp4',
          'position_ms': 12000,
          'duration_ms': 60000,
        },
        'playlist_id': 'pl-1',
        'volume': 80,
        'muted': false,
        'audio_master': true,
        'cache': {'a1': 'ready', 'b2': 'downloading:45%'},
        'clock_offset_ms': -12,
        'cpu': 18,
        'errors': <String>[],
        'last_seen': 1750000000000,
      };
      final d = DeviceStatus.fromMap(m);
      expect(d.deviceId, 'win-01');
      expect(d.deviceName, '大厅左屏');
      expect(d.online, isTrue);
      expect(d.state, 'playing');
      expect(d.current?.name, 'promo.mp4');
      expect(d.current?.positionMs, 12000);
      expect(d.volume, 80);
      expect(d.audioMaster, isTrue);
      expect(d.cache['a1'], 'ready');
      expect(d.cache['b2'], 'downloading:45%');
      expect(d.clockOffsetMs, -12);
      expect(d.lastSeen, 1750000000000);
    });

    test('缺省/缺失字段走默认值', () {
      final d = DeviceStatus.fromMap({'device_id': 'x'});
      expect(d.online, isFalse);
      expect(d.state, 'idle');
      expect(d.current, isNull);
      expect(d.volume, 0);
      expect(d.cache, isEmpty);
      expect(d.errors, isEmpty);
      expect(d.lastSeen, isNull);
    });
  });

  group('WallSnapshot.fromMap (§5.2)', () {
    test('groups + devices 嵌套解析', () {
      final m = {
        'server_time': 1750000000000,
        'groups': [
          {
            'group_id': 'lobby',
            'name': '大厅',
            'sync': true,
            'playlist_id': 'pl-1',
            'members': ['win-01', 'and-02'],
          },
        ],
        'devices': [
          {'device_id': 'win-01', 'group_id': 'lobby', 'online': true},
        ],
      };
      final w = WallSnapshot.fromMap(m);
      expect(w.serverTime, 1750000000000);
      expect(w.groups.length, 1);
      expect(w.groups.first.members, ['win-01', 'and-02']);
      expect(w.groups.first.sync, isTrue);
      expect(w.devices.length, 1);
      expect(w.devices.first.deviceId, 'win-01');
    });

    test('空快照', () {
      final w = WallSnapshot.fromMap(const {});
      expect(w.groups, isEmpty);
      expect(w.devices, isEmpty);
    });
  });

  group('ThumbMeta.fromMap (§6.4)', () {
    test('解析 + mime 默认', () {
      final t = ThumbMeta.fromMap({
        'device_id': 'win-01',
        'seq': 3,
        'bytes': 4096,
      });
      expect(t.deviceId, 'win-01');
      expect(t.seq, 3);
      expect(t.bytes, 4096);
      expect(t.mime, 'image/jpeg');
    });
  });

  group('AnnounceInfo 往返 (§7)', () {
    test('toMap/fromMap 一致，broker_hint 可空', () {
      const a = AnnounceInfo(
        deviceId: 'win-01',
        deviceName: '大厅左屏',
        ip: '192.168.1.50',
        brokerHint: '192.168.1.10:8770',
      );
      final back = AnnounceInfo.fromMap(a.toMap());
      expect(back.deviceId, 'win-01');
      expect(back.ip, '192.168.1.50');
      expect(back.brokerHint, '192.168.1.10:8770');

      const noHint =
          AnnounceInfo(deviceId: 'd', deviceName: 'n', ip: '1.2.3.4');
      expect(noHint.toMap().containsKey('broker_hint'), isFalse);
    });
  });

  group('Commands payload (§6/§9)', () {
    test('hello controller', () {
      final p = Commands.hello(controllerId: 'phone-jay');
      expect(p['role'], 'controller');
      expect(p['controller_id'], 'phone-jay');
      expect(p['app_version'], '1.0.0');
    });

    test('playlist 含全部字段', () {
      final p = Commands.playlist(
        playlistId: 'pl-1',
        groupId: 'lobby',
        sync: true,
        loop: false,
        items: const [
          MediaItem(itemId: 'a', type: 'video', name: 'n', url: 'u'),
        ],
      );
      expect(p['playlist_id'], 'pl-1');
      expect(p['group_id'], 'lobby');
      expect(p['sync'], isTrue);
      expect((p['items'] as List).length, 1);
    });

    test('prepare 默认 start_index/seek_ms', () {
      final p = Commands.prepare(playlistId: 'pl-1', groupId: 'g');
      expect(p['start_index'], 0);
      expect(p['seek_ms'], 0);
      expect(p.containsKey('prefetch'), isFalse);
      expect(p.containsKey('barrier_timeout_ms'), isFalse);
    });

    test('prepare 可携带预缓存栅栏参数', () {
      final p = Commands.prepare(
        playlistId: 'pl-1',
        groupId: 'g',
        prefetch: true,
        barrierTimeoutMs: 120000,
      );
      expect(p['prefetch'], isTrue);
      expect(p['barrier_timeout_ms'], 120000);
    });

    test('set_volume clamp 到 0..100', () {
      final hi = Commands.setVolume(volume: 150, groupId: 'g');
      final lo = Commands.setVolume(volume: -5, deviceId: 'd');
      expect(hi['volume'], 100);
      expect(lo['volume'], 0);
      expect(hi['group_id'], 'g');
      expect(lo['device_id'], 'd');
    });

    test('_target 只填非空目标', () {
      final g = Commands.pause(groupId: 'lobby');
      expect(g['group_id'], 'lobby');
      expect(g.containsKey('device_id'), isFalse);

      final d = Commands.stop(deviceId: 'win-01');
      expect(d['device_id'], 'win-01');
      expect(d.containsKey('group_id'), isFalse);
    });

    test('set_audio_master / assign_group', () {
      final am = Commands.setAudioMaster(
          groupId: 'lobby', deviceIds: ['win-01', 'and-02']);
      expect(am['group_id'], 'lobby');
      expect(am['device_ids'], ['win-01', 'and-02']);

      final ag = Commands.assignGroup(deviceId: 'win-01', groupId: 'hall');
      expect(ag['device_id'], 'win-01');
      expect(ag['group_id'], 'hall');
    });
  });

  group('fmtMs', () {
    test('毫秒 → mm:ss', () {
      expect(fmtMs(0), '00:00');
      expect(fmtMs(12000), '00:12');
      expect(fmtMs(65000), '01:05');
      expect(fmtMs(-100), '00:00');
    });
  });
}
