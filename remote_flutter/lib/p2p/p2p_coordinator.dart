import 'dart:async';

import '../protocol/envelope.dart';
import '../protocol/messages.dart';
import 'clock_master.dart';
import 'group_expander.dart';
import 'handshake.dart';
import 'wall_aggregator.dart';
import 'ws_link.dart';

/// 一条 p2p 直连的生命周期态（§14.5 可见性）：遥控端拨号 → 握手 → 就绪 / 失败。
/// 供 UI 把「连接中 / 已连接 / 失败(原因)」直接画在设备卡上，不再静默吞掉。
enum PeerLinkState { connecting, connected, failed }

/// 一个被控端的拨号目标。
class P2pPeer {
  const P2pPeer({
    required this.deviceId,
    required this.host,
    required this.port,
    this.deviceName,
    this.secure = false,
  });

  final String deviceId;
  final String host;
  final int port;
  final String? deviceName;
  final bool secure;

  Uri get uri => Uri.parse('${secure ? 'wss' : 'ws'}://$host:$port');
}

/// p2p 协调端（protocol_spec.md §14.3）：遥控端兼任 broker。
///
/// 职责（均为遥控端客户端侧本地完成）：
///  - **多连接管理**：对每台发现到的被控端各开一条 WS（被控端在 p2p 下跑 WS 服务端）。
///  - **主时钟**（[ClockMaster]）：回应各 player 的 `time_sync` → `time_sync_ack`。
///  - **三段握手编排**（[HandshakeOrchestrator]）：fan `prepare` → 收 `ready`/超时 → `play_at`。
///  - **组扇出**（[GroupExpander]）：`to:"group:<gid>"` 本地展开为逐成员发送。
///  - **状态墙聚合**（[WallAggregator]）：合并各 `status` 为本地设备墙快照。
///
/// 退化（§14.4）：WiFi 抖动、单遥控端、尽力而为同步（典型 ±100–200ms），适合 ≤8 台。
class P2pCoordinator {
  P2pCoordinator({
    required this.codec,
    required this.controllerId,
    WsLinkFactory? linkFactory,
    int Function()? nowFn,
    int readyTimeoutMs = 2000,
    int bufferMs = 2000,
  })  : _linkFactory = linkFactory ?? IoWsLink.connect,
        _now = nowFn ?? nowMs,
        _readyTimeoutMs = readyTimeoutMs,
        _bufferMs = bufferMs {
    clock = ClockMaster(nowFn: _now);
    aggregator = WallAggregator();
    handshake = HandshakeOrchestrator(
      nowFn: _now,
      onPlayAt: _onPlayAtReady,
      onLog: _log,
    );
  }

  /// 与全系统一致的信封编解码器（签名/验签，按 authMode）。
  EnvelopeCodec codec;

  /// 本遥控端 id。
  String controllerId;

  final WsLinkFactory _linkFactory;
  final int Function() _now;
  final int _readyTimeoutMs;
  final int _bufferMs;

  late final ClockMaster clock;
  late final WallAggregator aggregator;
  late final HandshakeOrchestrator handshake;

  /// 聚合后的设备墙快照变化回调（替代 broker 的 wall 帧）。
  void Function(WallSnapshot snapshot)? onWall;

  /// 连接的对端数量变化（用于 UI“已连 N 台”展示）。
  void Function(int connectedCount)? onPeers;

  /// 单台对端连接态变化（§14.5 可见性）：connecting/connected/failed，
  /// failed 时 [reason] 给出原因（超时/拒绝/握手失败）。UI 据此画每张卡的状态。
  void Function(String deviceId, PeerLinkState state, String? reason)? onPeerState;

  /// 诊断日志。
  void Function(String line)? onLog;

  final Map<String, WsLink> _links = {};
  final Map<String, StreamSubscription<String>> _subs = {};
  final Map<String, P2pPeer> _peers = {};
  bool _disposed = false;

  /// 当前已建立直连的 device_id 集合。
  Set<String> get connectedIds => _links.keys.toSet();
  int get connectedCount => _links.length;

  // ---- 连接管理 ----

  /// 用一组发现到的对端刷新连接：新增的拨号，消失的断开。
  void setPeers(Iterable<P2pPeer> peers) {
    if (_disposed) return;
    final next = {for (final p in peers) p.deviceId: p};
    // 断开不再出现的对端。
    for (final id in _links.keys.toList()) {
      if (!next.containsKey(id)) _disconnect(id);
    }
    // 拨号新对端。
    for (final p in next.values) {
      _peers[p.deviceId] = p;
      if (!_links.containsKey(p.deviceId)) _dial(p);
    }
    _emitPeers();
  }

  void _dial(P2pPeer peer) {
    if (_disposed) return;
    // §14.5 可见性：拨号即上报 connecting，UI 立刻显示「连接中」。
    _emitPeerState(peer.deviceId, PeerLinkState.connecting, null);
    final WsLink link;
    try {
      link = _linkFactory(peer.uri);
    } catch (e) {
      _log('拨号 ${peer.deviceId}(${peer.uri}) 失败: $e');
      _emitPeerState(peer.deviceId, PeerLinkState.failed, '拨号失败: $e');
      return;
    }
    _links[peer.deviceId] = link;
    _subs[peer.deviceId] = link.textStream.listen(
      (text) => _onText(peer.deviceId, text),
      onError: (Object e) => _onLinkError(peer.deviceId, e),
      onDone: () => _onLinkDone(peer.deviceId),
      cancelOnError: false,
    );
    link.ready.then((_) {
      if (_links[peer.deviceId] != link) return;
      _log('已连接被控端 ${peer.deviceName ?? peer.deviceId}(${peer.uri})');
      _emitPeerState(peer.deviceId, PeerLinkState.connected, null);
      _sendHello(peer.deviceId);
      _emitPeers();
    }).catchError((Object e) {
      _log('握手失败 ${peer.deviceId}: $e');
      _emitPeerState(peer.deviceId, PeerLinkState.failed, '握手失败: $e');
      _onLinkDone(peer.deviceId);
    });
  }

  void _sendHello(String deviceId) {
    // §17.3：p2p 下遥控端是协调端，其 key_mode 是该拓扑的权威，随 hello 声明给各 player，
    // player 据此决定验本端帧用 device_key（derived）还是 PSK（global）。
    _sendTo(deviceId, 'hello', to: 'player:$deviceId', payload: {
      'role': 'controller',
      'controller_id': controllerId,
      'app_version': '1.0.0',
      'topology': 'p2p',
      'auth_mode': codec.authMode.wire,
      'key_mode': codec.keyMode.wire,
    });
  }

  void _disconnect(String deviceId) {
    _subs.remove(deviceId)?.cancel();
    final link = _links.remove(deviceId);
    link?.close();
    aggregator.markOffline(deviceId);
  }

  void _onLinkError(String deviceId, Object e) {
    _log('连接错误 $deviceId: $e');
    _emitPeerState(deviceId, PeerLinkState.failed, '连接错误: $e');
  }

  void _onLinkDone(String deviceId) {
    _log('连接关闭 $deviceId');
    final wasConnected = _links.containsKey(deviceId);
    _subs.remove(deviceId)?.cancel();
    _links.remove(deviceId);
    aggregator.markOffline(deviceId);
    // 曾连上又断开 → 失败态（掉线）；从未连上的（拨号即失败）已在 _dial 上报。
    if (wasConnected) {
      _emitPeerState(deviceId, PeerLinkState.failed, '连接断开');
    }
    _emitWall();
    _emitPeers();
  }

  // ---- 入站分发 ----

  /// 处理一条来自 [deviceId] 直连的文本帧。包级可见以便单测直接驱动。
  void handleFrame(String deviceId, String text) => _onText(deviceId, text);

  void _onText(String deviceId, String text) {
    final Envelope env;
    try {
      env = Envelope.fromJson(text);
    } catch (e) {
      _log('JSON 解析失败($deviceId): $e');
      return;
    }
    final vr = codec.verify(env);
    if (vr != VerifyError.ok) {
      _log('入站验签失败($deviceId ${env.type}): $vr');
      return;
    }
    switch (env.type) {
      case 'welcome':
        _log('被控端 $deviceId welcome(topology=${env.payload['topology']})');
        final snap = (env.payload['snapshot'] as Map?)?.cast<String, dynamic>();
        if (snap != null) {
          for (final d in WallSnapshot.fromMap(snap).devices) {
            aggregator.mergeStatus(d, seenAt: _now());
          }
          _emitWall();
        }
        break;
      case 'status':
        aggregator.mergeStatus(DeviceStatus.fromMap(env.payload), seenAt: _now());
        _emitWall();
        break;
      case 'time_sync':
        _answerTimeSync(deviceId, env);
        break;
      case 'ready':
        handshake.onReady(
          deviceId: _asStr(env.payload['device_id'], deviceId),
          prepareId: env.payload['prepare_id'] as String?,
          groupId: env.payload['group_id'] as String?,
          playlistId: env.payload['playlist_id'] as String?,
          ready: env.payload['ready'] is bool
              ? env.payload['ready'] as bool
              : true,
        );
        break;
      case 'ack':
        _log('ack($deviceId): ${env.payload}');
        break;
      case 'error':
        _log('error($deviceId): ${env.payload}');
        break;
      default:
        _log('忽略入站类型($deviceId): ${env.type}');
    }
  }

  /// 主时钟：回应 player 的 time_sync（§8.1 / §14.3）。
  void _answerTimeSync(String deviceId, Envelope req) {
    final payload = clock.ackPayload(
      req.payload,
      reqMsgId: req.msgId,
      recvMs: _now(),
    );
    _sendTo(deviceId, 'time_sync_ack', to: 'player:$deviceId', payload: payload);
  }

  void _onPlayAtReady(Set<String> targets, Map<String, dynamic> payload) {
    for (final id in targets) {
      _sendTo(id, 'play_at', to: 'player:$id', payload: payload);
    }
  }

  // ---- 出站（客户端侧扇出，§14.3 路由）----

  /// 把一条命令按 `to` 地址在客户端侧扇出（group→逐成员；player→单条；all→全体）。
  /// payload 由调用方按 §6/§9 构造（与 broker 模式同一套 [Commands]）。
  void send(String type, {required String to, Map<String, dynamic> payload = const {}}) {
    final targets = GroupExpander.expand(
      to,
      devices: aggregator.snapshot(serverTime: clock.serverTime()).devices,
      connected: connectedIds,
    );
    if (targets.isEmpty) {
      _log('send($type) 无目标（to=$to）');
      return;
    }
    for (final id in targets) {
      _sendTo(id, type, to: 'player:$id', payload: payload);
    }
  }

  /// 一台直连的定向发送（已连接才发）。
  void _sendTo(String deviceId, String type,
      {required String to, Map<String, dynamic> payload = const {}}) {
    final link = _links[deviceId];
    if (link == null) {
      _log('sendTo($deviceId,$type) 丢弃：未连接');
      return;
    }
    final env = codec.build(type: type, to: to, payload: payload);
    link.sendText(env.toJson());
  }

  /// 编排一次同步起播（§9，p2p 本地版）：
  ///  1. 自分配 prepare_id，向组内目标 fan `prepare`；
  ///  2. [HandshakeOrchestrator] 收齐 `ready`（或 readyTimeoutMs 超时）；
  ///  3. 算 play_at = controllerNow + bufferMs，发给（收齐:全部 / 超时:已就绪）。
  ///
  /// 返回本次会话的 prepare_id。
  ///
  /// [readyTimeoutMsOverride] 供 §21 预缓存栅栏用:传入长超时(如 120s),让各被控端
  /// 有时间下载+校验完成再回 ready,而非用默认 2s 短超时。缺省沿用构造时的短超时。
  String startSync({
    required String playlistId,
    required String groupId,
    int startIndex = 0,
    int seekMs = 0,
    int? readyTimeoutMsOverride,
  }) {
    final prepareId = uuid4();
    final devices =
        aggregator.snapshot(serverTime: clock.serverTime()).devices;
    final targets = GroupExpander.expand(
      'group:$groupId',
      devices: devices,
      connected: connectedIds,
    ).toSet();
    handshake.begin(
      prepareId: prepareId,
      groupId: groupId,
      playlistId: playlistId,
      targets: targets,
      startIndex: startIndex,
      seekMs: seekMs,
      bufferMs: _bufferMs,
      readyTimeoutMs: readyTimeoutMsOverride ?? _readyTimeoutMs,
    );
    final payload = Commands.prepare(
      playlistId: playlistId,
      groupId: groupId,
      startIndex: startIndex,
      seekMs: seekMs,
      prepareId: prepareId,
    );
    for (final id in targets) {
      _sendTo(id, 'prepare', to: 'player:$id', payload: payload);
    }
    _log('p2p prepare $prepareId → ${targets.length} 台');
    return prepareId;
  }

  void _emitWall() {
    onWall?.call(aggregator.snapshot(serverTime: clock.serverTime()));
  }

  void _emitPeers() => onPeers?.call(connectedCount);

  void _emitPeerState(String deviceId, PeerLinkState state, String? reason) =>
      onPeerState?.call(deviceId, state, reason);

  void _log(String line) => onLog?.call(line);

  void dispose() {
    _disposed = true;
    for (final s in _subs.values) {
      s.cancel();
    }
    _subs.clear();
    for (final l in _links.values) {
      l.close();
    }
    _links.clear();
    handshake.dispose();
  }

  static String _asStr(Object? v, [String def = '']) =>
      v is String && v.isNotEmpty ? v : def;
}


