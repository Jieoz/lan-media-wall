import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/p2p/p2p_coordinator.dart';
import 'package:remote_flutter/p2p/ws_link.dart';
import 'package:remote_flutter/protocol/auth_mode.dart';
import 'package:remote_flutter/protocol/envelope.dart';
import 'package:remote_flutter/protocol/messages.dart';

/// 内存 fake：记录出站文本，并可注入入站文本/二进制帧。
class FakeWsLink implements WsLink {
  FakeWsLink(this.uri);
  final Uri uri;
  final List<String> sent = [];
  final _ctrl = StreamController<String>.broadcast();
  final _bin = StreamController<Uint8List>.broadcast();
  final _ready = Completer<void>();
  @override
  int? closeCode;
  @override
  String? closeReason;

  void completeReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  void failReady(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
  }

  /// 模拟收到一帧。
  void inject(String text) => _ctrl.add(text);

  /// 模拟收到一个二进制帧（§6.4 缩略图 JPEG 字节）。
  void injectBinary(Uint8List bytes) => _bin.add(bytes);

  /// 模拟连接被动断开（onDone 触发 → 协调端走重连路径）。
  void drop({int? code, String? reason}) {
    closeCode = code;
    closeReason = reason;
    _ctrl.close();
    _bin.close();
  }

  @override
  Stream<String> get textStream => _ctrl.stream;
  @override
  Stream<Uint8List> get binaryStream => _bin.stream;
  @override
  Future<void> get ready => _ready.future;
  @override
  void sendText(String data) => sent.add(data);
  @override
  Future<void> close() async {
    await _ctrl.close();
    await _bin.close();
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

    test('p2p create_group creates visible empty group locally', () async {
      WallSnapshot? wall;
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1,
        linkFactory: (uri) => FakeWsLink(uri),
      )..onWall = (snap) => wall = snap;

      coord.send('create_group',
          to: 'broker', payload: {'group_id': 'hall-2', 'name': '二号厅', 'sync': false});

      final groups = {for (final g in wall!.groups) g.groupId: g};
      expect(groups.containsKey('hall-2'), isTrue);
      expect(groups['hall-2']!.name, '二号厅');
      expect(groups['hall-2']!.sync, isFalse);
      expect(groups['hall-2']!.members, isEmpty);
    });

    test('p2p update_group and delete_group update local wall snapshot', () async {
      WallSnapshot? wall;
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1,
        linkFactory: (uri) => FakeWsLink(uri),
      )..onWall = (snap) => wall = snap;

      coord.send('create_group',
          to: 'broker', payload: {'group_id': 'hall-2', 'name': '二号厅'});
      coord.send('update_group',
          to: 'broker', payload: {'group_id': 'hall-2', 'name': '二号厅改', 'sync': false});
      var groups = {for (final g in wall!.groups) g.groupId: g};
      expect(groups['hall-2']!.name, '二号厅改');
      expect(groups['hall-2']!.sync, isFalse);

      coord.send('delete_group',
          to: 'broker', payload: {'group_id': 'hall-2', 'reassign_to': 'default'});
      groups = {for (final g in wall!.groups) g.groupId: g};
      expect(groups.containsKey('hall-2'), isFalse);
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

    test('根因A 归一后:status 带匹配组 → 走正常路径命中(不再触发兜底)', () async {
      // 拨号只有占位 key(host:port),收到 status 带真实 device_id + group_id
      // 后连接重绑定到真实 id。此后 send(group:default) 应通过 GroupExpander
      // 正常匹配到该真实 id(它现在既在 aggregator 的 default 组、又在
      // connectedIds 里),命中正常路径,不再落入「回退全部已连接」兜底。
      // 这正是根因 A 修复目标:正常路径优先,兜底不再是唯一能推图的路径。
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
      // 目标是归一后的真实 device_id,而不是拨号时的占位 host:port key。
      expect(_parse(sentPlaylist.single).to, 'player:and-88fe839f52');
      // 命中正常路径 → 不应打印兜底日志。
      expect(logs.any((line) => line.contains('回退到全部已连接')), isFalse);
    });

    test('group 匹配为空时拒绝投递,绝不扩大到全部已连接设备', () async {
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

      coord.send('playlist', to: 'group:lobby', payload: {'playlist_id': 'pl-1'});

      final sentPlaylist = link.sent.where((s) => _parse(s).type == 'playlist');
      expect(sentPlaylist, isEmpty);
      expect(logs.any((line) => line.contains('无目标')), isTrue);
      expect(logs.any((line) => line.contains('回退到全部已连接')), isFalse);
    });

    test('update_status 在 P2P 入站链路回传给上层', () async {
      late FakeWsLink link;
      String? receivedDeviceId;
      String? receivedState;
      String? receivedDetail;
      int? receivedVersionCode;
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1,
        linkFactory: (uri) => link = FakeWsLink(uri),
      )..onUpdateStatus = (deviceId, state, detail, versionCode) {
          receivedDeviceId = deviceId;
          receivedState = state;
          receivedDetail = detail;
          receivedVersionCode = versionCode;
        };
      coord.setPeers([const P2pPeer(deviceId: 'a', host: 'h', port: 8770)]);
      link.completeReady();
      await Future<void>.delayed(Duration.zero);

      coord.handleFrame('a', frame(openCodec(), 'update_status', {
        'device_id': 'a',
        'state': 'installing',
        'detail': 'verified',
        'version_code': 40,
      }));

      expect(receivedDeviceId, 'a');
      expect(receivedState, 'installing');
      expect(receivedDetail, 'verified');
      expect(receivedVersionCode, 40);
    });

    test('组命令只投递已匹配成员并返回成功写入数', () async {
      final links = <String, FakeWsLink>{};
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1,
        linkFactory: (uri) {
          final link = FakeWsLink(uri);
          links[uri.host] = link;
          return link;
        },
      );
      coord.setPeers([
        const P2pPeer(deviceId: 'a', host: 'ha', port: 8770),
        const P2pPeer(deviceId: 'b', host: 'hb', port: 8770),
      ]);
      for (final link in links.values) {
        link.completeReady();
      }
      await Future<void>.delayed(Duration.zero);
      coord.handleFrame('a', frame(openCodec(), 'status',
          {'device_id': 'a', 'group_id': 'lobby'}));
      coord.handleFrame('b', frame(openCodec(), 'status',
          {'device_id': 'b', 'group_id': 'other'}));
      for (final link in links.values) {
        link.sent.clear();
      }

      final deliveredTargets = coord.sendTargets('pause', to: 'group:lobby');

      expect(deliveredTargets, {'a'});
      expect(
          links['ha']!.sent.where((s) => _parse(s).type == 'pause'), hasLength(1));
      expect(
          links['hb']!.sent.where((s) => _parse(s).type == 'pause'), isEmpty);
    });

    test('startSync 零目标时直接失败且不创建空握手', () {
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 100000,
        linkFactory: (uri) => FakeWsLink(uri),
      );

      expect(
        () => coord.startSync(playlistId: 'pl-1', groupId: 'lobby'),
        throwsA(isA<StateError>()),
      );
      expect(coord.handshake.pending, 0);
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

    test('§9.4b startSync(deviceId) 只锁一台: prepare/play_at 只发这一台', () async {
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

      // 单台推送:锁定 a。b 是同组同连接的兄弟,绝不能被牵动。
      final prepareId =
          coord.startSync(playlistId: 'pl-1', groupId: 'lobby', deviceId: 'a');
      expect(links['ha']!.sent.where((s) => _parse(s).type == 'prepare').length, 1);
      expect(links['hb']!.sent.where((s) => _parse(s).type == 'prepare').length, 0);

      // a 回 ready → 只有 a 收到 play_at,b 全程 0 条。
      coord.handleFrame('a',
          frame(openCodec(), 'ready', {'device_id': 'a', 'prepare_id': prepareId, 'group_id': 'lobby', 'ready': true}));
      expect(links['ha']!.sent.where((s) => _parse(s).type == 'play_at').length, 1);
      expect(links['hb']!.sent.where((s) => _parse(s).type == 'play_at').length, 0);
    });

    test('p2p 预缓存栅栏: prepare 携带 prefetch 参数且 ready=false 只等待不点火', () async {
      late FakeWsLink link;
      final logs = <String>[];
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 100000,
        readyTimeoutMs: 120000,
        linkFactory: (uri) => link = FakeWsLink(uri),
      )..onLog = logs.add;
      coord.setPeers([const P2pPeer(deviceId: 'a', host: 'ha', port: 8770)]);
      link.completeReady();
      await Future<void>.delayed(Duration.zero);
      coord.handleFrame('a', frame(openCodec(), 'status', {'device_id': 'a', 'group_id': 'default'}));
      link.sent.clear();

      final prepareId = coord.startSync(
        playlistId: 'pl-1',
        groupId: 'default',
        prefetchBarrier: true,
        readyTimeoutMsOverride: 120000,
      );

      final prep = _parse(link.sent.firstWhere((s) => _parse(s).type == 'prepare'));
      expect(prep.payload['prepare_id'], prepareId);
      expect(prep.payload['prefetch'], isTrue);
      expect(prep.payload['barrier_timeout_ms'], 120000);

      coord.handleFrame('a', frame(openCodec(), 'ready', {
        'device_id': 'a',
        'prepare_id': prepareId,
        'group_id': 'default',
        'ready': false,
      }));

      expect(link.sent.where((s) => _parse(s).type == 'play_at'), isEmpty);
      expect(logs.any((l) => l.contains('ready(a) = false')), isTrue);
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

    test('缩略图(B): thumb_meta + 紧跟二进制帧配对 → onThumb 交出 JPEG', () async {
      late FakeWsLink link;
      final thumbs = <String, Uint8List>{};
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1,
        linkFactory: (uri) => link = FakeWsLink(uri),
      )..onThumb = (id, jpeg) => thumbs[id] = jpeg;
      coord.setPeers([const P2pPeer(deviceId: 'a', host: 'h', port: 8770)]);
      link.completeReady();
      await Future<void>.delayed(Duration.zero);

      final jpeg = Uint8List.fromList(List<int>.generate(16, (i) => i));
      // 先 thumb_meta（文本帧），紧跟二进制帧。
      coord.handleFrame(
          'a',
          frame(openCodec(), 'thumb_meta',
              {'device_id': 'a', 'seq': 1, 'bytes': jpeg.length}));
      link.injectBinary(jpeg);
      await Future<void>.delayed(Duration.zero);

      expect(thumbs['a'], jpeg);
    });

    test('缩略图(B): 无配对 thumb_meta 的二进制帧被丢弃(不崩)', () async {
      late FakeWsLink link;
      final thumbs = <String, Uint8List>{};
      final coord = P2pCoordinator(
        codec: openCodec(),
        controllerId: 'c1',
        nowFn: () => 1,
        linkFactory: (uri) => link = FakeWsLink(uri),
      )..onThumb = (id, jpeg) => thumbs[id] = jpeg;
      coord.setPeers([const P2pPeer(deviceId: 'a', host: 'h', port: 8770)]);
      link.completeReady();
      await Future<void>.delayed(Duration.zero);

      link.injectBinary(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);
      expect(thumbs, isEmpty);
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

    test('断线主动重连(C): drop 后经退避 timer 主动重拨同一端点，且不产生双连接', () {
      fakeAsync((async) {
        var dialCount = 0;
        final created = <FakeWsLink>[];
        final coord = P2pCoordinator(
          codec: openCodec(),
          controllerId: 'c1',
          nowFn: () => 1,
          linkFactory: (uri) {
            dialCount++;
            final l = FakeWsLink(uri);
            created.add(l);
            return l;
          },
        );
        coord.setPeers([const P2pPeer(deviceId: 'a', host: 'h', port: 8770)]);
        expect(dialCount, 1);
        expect(coord.connectedCount, 1);
        created.last.completeReady();
        async.flushMicrotasks();

        // 断线：关 text+binary 流 → onDone → 协调端排一次退避重连。
        created.last.drop();
        async.flushMicrotasks();
        expect(coord.connectedCount, 0); // link 已随 onDone 移除

        // 尚未到退避(首次 1s)：不应重拨。
        async.elapse(const Duration(milliseconds: 500));
        expect(dialCount, 1);

        // 过退避 → 主动重拨同一端点 → 新连接建立。
        async.elapse(const Duration(milliseconds: 600));
        expect(dialCount, 2);
        expect(coord.connectedCount, 1);
        expect(created.length, 2);

        // 端点去重:discover 驱动的 setPeers 再拨同一端点时,因已有活连接被跳过。
        coord.setPeers([const P2pPeer(deviceId: 'a', host: 'h', port: 8770)]);
        expect(dialCount, 2); // 不重复拨号
        expect(coord.connectedCount, 1); // 无双连接

        coord.dispose();
      });
    });

    test('断线主动重连(C): 对端已从发现列表移除后再断，不重连', () {
      fakeAsync((async) {
        var dialCount = 0;
        late FakeWsLink link;
        final coord = P2pCoordinator(
          codec: openCodec(),
          controllerId: 'c1',
          nowFn: () => 1,
          linkFactory: (uri) {
            dialCount++;
            return link = FakeWsLink(uri);
          },
        );
        coord.setPeers([const P2pPeer(deviceId: 'a', host: 'h', port: 8770)]);
        link.completeReady();
        async.flushMicrotasks();
        expect(dialCount, 1);
        expect(coord.connectedCount, 1);

        // 对端从发现列表移除 → _disconnect 清 peer + 关连接 + 清退避定时器。
        // 随后 link.close() 触发的 onDone 里,peer 已不在 → _scheduleReconnect 早退。
        coord.setPeers(const []);
        async.flushMicrotasks();
        expect(coord.connectedCount, 0);

        // 即便过了远超退避上限的时间,也不应重拨(peer 已不被期望连接)。
        async.elapse(const Duration(seconds: 60));
        expect(dialCount, 1);

        coord.dispose();
      });
    });

    test('旧 link delayed ready error 不删除 replacement、不离线、不排重连', () {
      fakeAsync((async) {
        final created = <FakeWsLink>[];
        final logs = <String>[];
        final coord = P2pCoordinator(
          codec: openCodec(), controllerId: 'c1', nowFn: () => 1,
          linkFactory: (uri) {
            final link = FakeWsLink(uri);
            created.add(link);
            return link;
          },
        )..onLog = logs.add;
        const peer = P2pPeer(deviceId: 'a', host: 'h', port: 8770);
        coord.setPeers([peer]);
        final old = created.single;
        coord.setPeers(const []);
        coord.setPeers([peer]);
        created.last.completeReady();
        async.flushMicrotasks();

        old.failReady(StateError('delayed old handshake failure'));
        async.flushMicrotasks();
        expect(coord.connectedCount, 1);
        async.elapse(const Duration(seconds: 10));
        expect(created.length, 2);
        expect(logs.where((l) => l.contains('后重连 a')), isEmpty);
        coord.dispose();
      });
    });

    test('upgrade 后连续 1013 保留指数退避 1s→2s→4s，welcome 后重置', () {
      fakeAsync((async) {
        final created = <FakeWsLink>[];
        final logs = <String>[];
        final coord = P2pCoordinator(
          codec: openCodec(), controllerId: 'c1', nowFn: () => 1,
          linkFactory: (uri) {
            final link = FakeWsLink(uri);
            created.add(link);
            return link;
          },
        )..onLog = logs.add;
        coord.setPeers([const P2pPeer(deviceId: 'a', host: 'h', port: 8770)]);

        for (final delay in const [1000, 2000, 4000]) {
          created.last.completeReady();
          async.flushMicrotasks();
          created.last.drop(code: 1013, reason: 'controller already active');
          async.flushMicrotasks();
          expect(logs.lastWhere((l) => l.contains('后重连')), contains('${delay}ms'));
          expect(logs.any((l) => l.contains('code=1013') &&
              l.contains('controller already active')), isTrue);
          async.elapse(Duration(milliseconds: delay));
        }

        created.last.completeReady();
        async.flushMicrotasks();
        created.last.inject(frame(openCodec(), 'welcome', {'topology': 'p2p'},
            from: 'player:a'));
        async.flushMicrotasks();
        created.last.drop(code: 1006, reason: 'wifi');
        async.flushMicrotasks();
        expect(logs.lastWhere((l) => l.contains('后重连')), contains('1000ms'));
        coord.dispose();
      });
    });
  });
}
