import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/p2p/p2p_coordinator.dart';
import 'package:remote_flutter/p2p/ws_link.dart';
import 'package:remote_flutter/protocol/auth_mode.dart';
import 'package:remote_flutter/protocol/envelope.dart';

/// 内存 fake：记录出站文本，并可注入入站文本。
class FakeWsLink implements WsLink {
  FakeWsLink(this.uri);
  final Uri uri;
  final List<String> sent = [];
  final _ctrl = StreamController<String>.broadcast();
  final _ready = Completer<void>();

  void completeReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  /// 模拟收到一帧。
  void inject(String text) => _ctrl.add(text);

  @override
  Stream<String> get textStream => _ctrl.stream;
  @override
  Future<void> get ready => _ready.future;
  @override
  void sendText(String data) => sent.add(data);
  @override
  Future<void> close() async {
    await _ctrl.close();
  }
}

/// 解析出站帧为 (type, payload, to)。
({String type, Map<String, dynamic> payload, String to}) _parse(String s) {
  final m = (jsonDecode(s) as Map).cast<String, dynamic>();
  return (
    type: m['type'] as String,
    payload: (m['payload'] as Map).cast<String, dynamic>(),
    to: m['to'] as String,
  );
}

void main() {
  // 用 open 模式造 codec：fake 注入的帧 sig 为空也能通过验签（§13）。
  EnvelopeCodec openCodec() =>
      EnvelopeCodec(psk: '', fromAddress: 'controller:c1', authMode: AuthMode.open);

  // 用注入 codec 把一帧 envelope 序列化（模拟 player 发来的帧）。
  String frame(EnvelopeCodec codec, String type, Map<String, dynamic> payload,
      {String from = 'player:x'}) {
    return codec.build(type: type, to: 'controller:c1', from: from, payload: payload).toJson();
  }

  group('P2pCoordinator 多连接 + 主时钟 + 聚合 (§14.3)', () {
    test('setPeers 对每台拨号并发 hello', () async {
      final links = <String, FakeWsLink>{};
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1000,
        linkFactory: (uri) {
          final l = FakeWsLink(uri);
          links[uri.toString()] = l;
          return l;
        },
      );
      coord.setPeers([
        const P2pPeer(deviceId: 'a', host: '10.0.0.1', port: 8770),
        const P2pPeer(deviceId: 'b', host: '10.0.0.2', port: 8770),
      ]);
      expect(coord.connectedCount, 2);
      // 完成握手 → 发 hello
      for (final l in links.values) {
        l.completeReady();
      }
      await Future<void>.delayed(Duration.zero);
      for (final l in links.values) {
        expect(l.sent.length, 1);
        final f = _parse(l.sent.first);
        expect(f.type, 'hello');
        expect(f.payload['topology'], 'p2p');
      }
    });

    test('time_sync → time_sync_ack（主时钟回 t2/t3 + req_msg_id）', () async {
      late FakeWsLink link;
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 50000,
        linkFactory: (uri) => link = FakeWsLink(uri),
      );
      coord.setPeers([const P2pPeer(deviceId: 'a', host: 'h', port: 8770)]);
      link.completeReady();
      await Future<void>.delayed(Duration.zero);
      link.sent.clear();

      final ts = frame(openCodec(), 'time_sync', {'t1': 111}, from: 'player:a');
      coord.handleFrame('a', ts);
      final ack = _parse(link.sent.firstWhere((s) => _parse(s).type == 'time_sync_ack'));
      expect(ack.payload['t1'], 111);
      expect(ack.payload['t2'], 50000);
      expect(ack.payload['t3'], 50000);
      expect(ack.payload['req_msg_id'], isNotEmpty);
    });

    test('status 聚合进 onWall 快照', () async {
      late FakeWsLink link;
      var wallDevices = 0;
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1,
        linkFactory: (uri) => link = FakeWsLink(uri),
      )..onWall = (snap) => wallDevices = snap.devices.length;
      coord.setPeers([const P2pPeer(deviceId: 'a', host: 'h', port: 8770)]);
      link.completeReady();
      await Future<void>.delayed(Duration.zero);

      coord.handleFrame('a',
          frame(openCodec(), 'status', {'device_id': 'a', 'group_id': 'lobby', 'state': 'playing', 'online': true}));
      expect(wallDevices, 1);
    });

    test('send group 扇出为逐成员 play 控制', () async {
      final links = <String, FakeWsLink>{};
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1,
        linkFactory: (uri) {
          final l = FakeWsLink(uri);
          links[uri.host] = l;
          return l;
        },
      );
      coord.setPeers([
        const P2pPeer(deviceId: 'a', host: 'ha', port: 8770),
        const P2pPeer(deviceId: 'b', host: 'hb', port: 8770),
      ]);
      for (final l in links.values) {
        l.completeReady();
      }
      await Future<void>.delayed(Duration.zero);
      // 两台都在 lobby 组
      coord.handleFrame('a', frame(openCodec(), 'status', {'device_id': 'a', 'group_id': 'lobby'}));
      coord.handleFrame('b', frame(openCodec(), 'status', {'device_id': 'b', 'group_id': 'lobby'}));
      for (final l in links.values) {
        l.sent.clear();
      }
      coord.send('pause', to: 'group:lobby', payload: {'group_id': 'lobby'});
      expect(links['ha']!.sent.where((s) => _parse(s).type == 'pause').length, 1);
      expect(links['hb']!.sent.where((s) => _parse(s).type == 'pause').length, 1);
    });

    test('send group 匹配为空但已有直连时回退到全部已连接', () async {
      late FakeWsLink link;
      final logs = <String>[];
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1,
        linkFactory: (uri) => link = FakeWsLink(uri),
      )..onLog = logs.add;
      coord.setPeers([const P2pPeer(deviceId: '10.10.8.160:8770', host: 'h', port: 8770)]);
      link.completeReady();
      await Future<void>.delayed(Duration.zero);
      link.sent.clear();

      coord.handleFrame(
        '10.10.8.160:8770',
        frame(openCodec(), 'status', {
          'device_id': 'and-88fe839f52',
          'group_id': 'default',
        }),
      );

      coord.send('playlist', to: 'group:default', payload: {'playlist_id': 'pl-1'});

      final sentPlaylist = link.sent.where((s) => _parse(s).type == 'playlist');
      expect(sentPlaylist.length, 1);
      // 根因A 身份归一后:收到 status 携带真实 device_id 时,连接已从占位
      // key(host:port)重绑定到真实 device_id,因此即便走「回退全部已连接」
      // 兜底,目标也应是真实 device_id(player:and-88fe839f52),而不再是
      // 归一前的占位 key。这正是归一生效的证据。
      expect(_parse(sentPlaylist.single).to, 'player:and-88fe839f52');
      expect(logs.any((line) => line.contains('回退到全部已连接 1 台')), isTrue);
    });

    test('startSync fan prepare，收齐 ready → play_at 发各成员', () async {
      final links = <String, FakeWsLink>{};
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 100000,
        bufferMs: 2000,
        linkFactory: (uri) {
          final l = FakeWsLink(uri);
          links[uri.host] = l;
          return l;
        },
      );
      coord.setPeers([
        const P2pPeer(deviceId: 'a', host: 'ha', port: 8770),
        const P2pPeer(deviceId: 'b', host: 'hb', port: 8770),
      ]);
      for (final l in links.values) {
        l.completeReady();
      }
      await Future<void>.delayed(Duration.zero);
      coord.handleFrame('a', frame(openCodec(), 'status', {'device_id': 'a', 'group_id': 'lobby'}));
      coord.handleFrame('b', frame(openCodec(), 'status', {'device_id': 'b', 'group_id': 'lobby'}));
      for (final l in links.values) {
        l.sent.clear();
      }

      final prepareId = coord.startSync(playlistId: 'pl-1', groupId: 'lobby');
      // 两台都收到 prepare
      final aPrep = _parse(links['ha']!.sent.firstWhere((s) => _parse(s).type == 'prepare'));
      expect(aPrep.payload['prepare_id'], prepareId);

      // 两台回 ready
      coord.handleFrame('a',
          frame(openCodec(), 'ready', {'device_id': 'a', 'prepare_id': prepareId, 'group_id': 'lobby', 'ready': true}));
      coord.handleFrame('b',
          frame(openCodec(), 'ready', {'device_id': 'b', 'prepare_id': prepareId, 'group_id': 'lobby', 'ready': true}));

      // 收齐 → 两台都收到 play_at = now + buffer = 102000
      final aPlay = _parse(links['ha']!.sent.firstWhere((s) => _parse(s).type == 'play_at'));
      expect(aPlay.payload['play_at'], 102000);
      expect(links['hb']!.sent.where((s) => _parse(s).type == 'play_at').length, 1);
    });

    test('身份归一(根因A): welcome 带真实 device_id → 连接从占位 key 重绑定', () async {
      late FakeWsLink link;
      final logs = <String>[];
      final identified = <String, String>{};
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1,
        linkFactory: (uri) => link = FakeWsLink(uri),
      )
        ..onLog = logs.add
        ..onPeerIdentified = (from, to) => identified[from] = to;
      // 扫码/手动添加:无真实 id,以 host:port 当占位 deviceId 建连。
      coord.setPeers(
          [const P2pPeer(deviceId: '10.10.8.160:8770', host: '10.10.8.160', port: 8770)]);
      link.completeReady();
      await Future<void>.delayed(Duration.zero);
      // 归一前:connectedIds 是占位命名空间。
      expect(coord.connectedIds, {'10.10.8.160:8770'});

      // welcome 从 from=player:<真实id> 带出真实 device_id。
      coord.handleFrame(
        '10.10.8.160:8770',
        frame(openCodec(), 'welcome', {'topology': 'p2p'},
            from: 'player:and-b87bfc8e49'),
      );
      // 归一后:占位 key 迁移到真实 device_id,命名空间归一。
      expect(coord.connectedIds, {'and-b87bfc8e49'});
      expect(identified['10.10.8.160:8770'], 'and-b87bfc8e49');
      expect(logs.any((l) => l.contains('身份归一') && l.contains('and-b87bfc8e49')),
          isTrue);
    });

    test('身份归一(根因A): 归一后组扇出走正常路径(不靠兜底) + play_at 正常下发', () async {
      late FakeWsLink link;
      final logs = <String>[];
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 100000,
        bufferMs: 2000,
        linkFactory: (uri) => link = FakeWsLink(uri),
      )..onLog = logs.add;
      coord.setPeers(
          [const P2pPeer(deviceId: '10.10.8.160:8770', host: '10.10.8.160', port: 8770)]);
      link.completeReady();
      await Future<void>.delayed(Duration.zero);
      // status 带真实 device_id → 归一 + 聚合。
      coord.handleFrame(
        '10.10.8.160:8770',
        frame(openCodec(), 'status',
            {'device_id': 'and-b87bfc8e49', 'group_id': 'default'},
            from: 'player:and-b87bfc8e49'),
      );
      expect(coord.connectedIds, {'and-b87bfc8e49'});
      link.sent.clear();
      logs.clear();

      final prepareId = coord.startSync(playlistId: 'pl-1', groupId: 'default');
      // 组匹配正常命中,不再触发兜底回退。
      expect(logs.any((l) => l.contains('回退到全部已连接')), isFalse);
      final prep = _parse(link.sent.firstWhere((s) => _parse(s).type == 'prepare'));
      expect(prep.to, 'player:and-b87bfc8e49');

      // ready 带真实 device_id → 会话目标集匹配成功 → play_at 下发(不再黑屏)。
      coord.handleFrame(
        'and-b87bfc8e49',
        frame(openCodec(), 'ready',
            {'device_id': 'and-b87bfc8e49', 'prepare_id': prepareId, 'ready': true},
            from: 'player:and-b87bfc8e49'),
      );
      final play = _parse(link.sent.firstWhere((s) => _parse(s).type == 'play_at'));
      expect(play.to, 'player:and-b87bfc8e49');
      expect(play.payload['play_at'], 102000);
    });

    test('身份归一(根因A): 归一后 setPeers(占位)不误断活连接', () async {
      late FakeWsLink link;
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1,
        linkFactory: (uri) => link = FakeWsLink(uri),
      );
      const placeholder =
          P2pPeer(deviceId: '10.10.8.160:8770', host: '10.10.8.160', port: 8770);
      coord.setPeers([placeholder]);
      link.completeReady();
      await Future<void>.delayed(Duration.zero);
      coord.handleFrame(
        '10.10.8.160:8770',
        frame(openCodec(), 'welcome', {'topology': 'p2p'},
            from: 'player:and-b87bfc8e49'),
      );
      expect(coord.connectedIds, {'and-b87bfc8e49'});
      // 发现仍只知道占位 id(扫码 URI 无真实 id):按端点对账,活连接不该被误断+重拨。
      coord.setPeers([placeholder]);
      expect(coord.connectedCount, 1);
      expect(coord.connectedIds, {'and-b87bfc8e49'});
    });

    test('对端消失 → 断开并 markOffline', () async {
      final links = <String, FakeWsLink>{};
      var lastWall = 0;
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1,
        linkFactory: (uri) {
          final l = FakeWsLink(uri);
          links[uri.host] = l;
          return l;
        },
      )..onWall = (snap) => lastWall =
          snap.devices.where((d) => d.online).length;
      coord.setPeers([const P2pPeer(deviceId: 'a', host: 'ha', port: 8770)]);
      links['ha']!.completeReady();
      await Future<void>.delayed(Duration.zero);
      coord.handleFrame('a', frame(openCodec(), 'status', {'device_id': 'a', 'group_id': 'g', 'online': true}));
      expect(lastWall, 1);
      // 移除该对端
      coord.setPeers(const []);
      expect(coord.connectedCount, 0);
    });
  });
}
