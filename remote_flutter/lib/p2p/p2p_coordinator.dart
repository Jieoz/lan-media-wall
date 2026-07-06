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

  /// 身份归一回调（根因 A 修复）：当一条以占位 key（`host:port`，扫码/手动添加时
  /// 无真实 device_id）建立的直连,从对端 `welcome`/`status` 拿到**真实 device_id**
  /// 后,把连接从占位 key 重绑定到真实 id。UI 层据此把占位卡与真实卡收敛成一张
  /// （否则设备墙会同时出现「占位卡(恒连)」+「真实卡(随 status 时断)」两张）。
  void Function(String placeholderId, String realId)? onPeerIdentified;

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
  ///
  /// **按连接端点(host:port)对账,而非按 deviceId**(根因 A 修复的关键):一条连接一旦
  /// 从占位 key(`host:port`)重绑定到真实 device_id,后续发现仍可能只知道占位 id
  /// (扫码 URI 无真实 id)。若仍按 deviceId 对账,会把「已重绑定到真实 id 的活连接」
  /// 误判为「已消失」而断开,再以占位 key 重拨 → 抖动 + 回到双命名空间。以端点对账则
  /// 天然幂等:同一 host:port 的连接不论当前挂在哪个 key 下,都视为「已存在,不动」。
  void setPeers(Iterable<P2pPeer> peers) {
    if (_disposed) return;
    final nextByEndpoint = {for (final p in peers) _endpoint(p): p};
    // 断开端点不再出现的对端(用当前实际 key 断,兼容已重绑定的连接)。
    for (final key in _links.keys.toList()) {
      final peer = _peers[key];
      final ep = peer == null ? null : _endpoint(peer);
      if (ep == null || !nextByEndpoint.containsKey(ep)) _disconnect(key);
    }
    // 已连端点集合(当前挂在任意 key 下的连接)。
    final connectedEndpoints = {
      for (final key in _links.keys)
        if (_peers[key] != null) _endpoint(_peers[key]!),
    };
    // 拨号新端点。
    for (final entry in nextByEndpoint.entries) {
      if (connectedEndpoints.contains(entry.key)) continue;
      final p = entry.value;
      _peers[p.deviceId] = p;
      if (!_links.containsKey(p.deviceId)) _dial(p);
    }
    _emitPeers();
  }

  /// 一台对端的连接端点标识（host:port，归一小写去空格）。身份对账的稳定键。
  static String _endpoint(P2pPeer p) =>
      '${p.host.trim().toLowerCase()}:${p.port}';

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
    // 所有回调都用 [_keyForLink] 解析「这条 link **当前**挂在哪个 key 下」,而非闭包
    // 捕获拨号时的占位 key——身份归一(重绑定)后这条 link 已挂到真实 device_id,
    // 若仍按占位 key 清理会漏删/错删,留下孤儿连接(设备墙恒显已连的幽灵卡)。
    _subs[peer.deviceId] = link.textStream.listen(
      (text) => _onText(_keyForLink(link) ?? peer.deviceId, text),
      onError: (Object e) => _onLinkError(_keyForLink(link) ?? peer.deviceId, e),
      onDone: () => _onLinkDone(_keyForLink(link) ?? peer.deviceId),
      cancelOnError: false,
    );
    link.ready.then((_) {
      final key = _keyForLink(link);
      if (key == null) return; // 已被替换/断开
      _log('已连接被控端 ${peer.deviceName ?? peer.deviceId}(${peer.uri})');
      _emitPeerState(key, PeerLinkState.connected, null);
      _sendHello(key);
      _emitPeers();
    }).catchError((Object e) {
      final key = _keyForLink(link) ?? peer.deviceId;
      _log('握手失败 $key: $e');
      _emitPeerState(key, PeerLinkState.failed, '握手失败: $e');
      _onLinkDone(key);
    });
  }

  /// 反查一条 link 当前挂在哪个 key 下（身份归一后 key 可能已从占位迁到真实 id）。
  String? _keyForLink(WsLink link) {
    for (final e in _links.entries) {
      if (identical(e.value, link)) return e.key;
    }
    return null;
  }

  /// 从一帧里取该对端的**真实 device_id**（身份权威）：
  ///  - status/ready 等:优先 `payload.device_id`(与 [WallAggregator] 聚合键一致)。
  ///  - welcome 等无 payload.device_id:从 `from`(如 `player:and-b87bfc8e49`)剥前缀。
  /// 取不到(空/无前缀)→ null,不触发归一(维持占位 key)。
  static String? _realIdOf(Envelope env) {
    final pid = env.payload['device_id'];
    if (pid is String && pid.isNotEmpty) return pid;
    final from = env.from;
    final i = from.indexOf(':');
    if (i >= 0 && i + 1 < from.length) return from.substring(i + 1);
    return from.isNotEmpty ? from : null;
  }

  /// 若 [arrivalKey] 仍是占位 key 且本帧带出了真实 device_id,则把连接从占位 key
  /// 重绑定到真实 id。返回**归一后应使用的 key**（真实 id;无需归一时原样返回）。
  String _maybeRebind(String arrivalKey, Envelope env) {
    final realId = _realIdOf(env);
    if (realId == null || realId == arrivalKey) return arrivalKey;
    // arrivalKey 已不是活连接(可能上一帧已归一) → 直接用当前应归属的 key。
    if (!_links.containsKey(arrivalKey)) {
      return _links.containsKey(realId) ? realId : arrivalKey;
    }
    _rebind(arrivalKey, realId);
    return realId;
  }

  /// 把 [from] 键上的连接(link/sub/peer)迁移到 [to] 键（真实 device_id）。
  void _rebind(String from, String to) {
    final link = _links.remove(from);
    if (link == null) return;
    final sub = _subs.remove(from);
    final peer = _peers.remove(from);
    // 去重:真实 id 已有另一条连接(重复拨号/重连窗口) → 关掉旧的,新连接接管该 id。
    if (_links.containsKey(to)) {
      _log('身份归一去重: $to 已有连接,关闭旧连接保留新连接($from)');
      _subs.remove(to)?.cancel();
      _links.remove(to)?.close();
    }
    _links[to] = link;
    if (sub != null) _subs[to] = sub;
    // peer 元数据用真实 id 重登记(host/port/name 不变,仅键归一)。
    _peers[to] = peer == null
        ? P2pPeer(deviceId: to, host: '', port: 0)
        : P2pPeer(
            deviceId: to,
            host: peer.host,
            port: peer.port,
            deviceName: peer.deviceName,
            secure: peer.secure,
          );
    _log('身份归一: 占位 key "$from" → 真实 device_id "$to"');
    // UI 层据此把占位卡与真实卡收敛成一张,并迁移接入态。
    onPeerIdentified?.call(from, to);
    _emitPeers();
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

  void _onText(String arrivalKey, String text) {
    final Envelope env;
    try {
      env = Envelope.fromJson(text);
    } catch (e) {
      _log('JSON 解析失败($arrivalKey): $e');
      return;
    }
    final vr = codec.verify(env);
    if (vr != VerifyError.ok) {
      _log('入站验签失败($arrivalKey ${env.type}): $vr');
      return;
    }
    // 根因 A 修复:身份归一。占位 key(host:port)承载的连接,一旦帧里带出真实
    // device_id(status/ready 的 payload.device_id,或 welcome 的 from=player:<id>),
    // 就把连接从占位 key 重绑定到真实 id,使 connectedIds 与 WallAggregator/
    // GroupExpander 用的 device_id 归一到同一命名空间。归一后:组扇出求交集正常命中、
    // 握手会话目标集用真实 id → ready 匹配成功 → play_at 正常下发(不再黑屏)。
    final deviceId = _maybeRebind(arrivalKey, env);
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
    final devices = aggregator.snapshot(serverTime: clock.serverTime()).devices;
    var targets = GroupExpander.expand(
      to,
      devices: devices,
      connected: connectedIds,
    ).toSet();
    if (targets.isEmpty) {
      _log('send($type) 无目标（to=$to, connected=${connectedIds.toList()}, '
          'devices=${devices.map((d) => "${d.deviceId}@grp=\"${d.groupId}\"").toList()}）');
      if (to.startsWith('group:') && connectedIds.isNotEmpty) {
        targets = connectedIds.toSet();
        _log('send($type) group 匹配为空 → 回退到全部已连接 ${targets.length} 台: ${targets.toList()}');
      }
    }
    if (targets.isEmpty) {
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
    var targets = GroupExpander.expand(
      'group:$groupId',
      devices: devices,
      connected: connectedIds,
    ).toSet();
    // §诊断:targets 为空是"点了推送盒子没反应"的头号原因。把决定 targets 的三个
    // 值原样打出来,一眼看出到底是 groupId 对不上、还是 connected 不含它。
    _log('startSync gid="$groupId" '
        'connected=${connectedIds.toList()} '
        'devices=${devices.map((d) => "${d.deviceId}@grp=\"${d.groupId}\"").toList()} '
        '→ targets=${targets.toList()}');
    // §兜底(单遥控端直连场景):若按 group 匹配算不出目标,但确实有已连接的被控端,
    // 就把"当前所有已直连的设备"作为目标——扫码直连一台盒子却因 group_id 漂移
    // (空串/大小写/前后空格)被过滤,是绝不该让"推图完全没反应"的。宁可多发给已连的,
    // 也不要静默 0 台。真机上"列表里有、连上了、却推不动"正是被这一层救回。
    if (targets.isEmpty && connectedIds.isNotEmpty) {
      targets = connectedIds.toSet();
      _log('startSync group 匹配为空 → 回退到全部已连接 ${targets.length} 台: ${targets.toList()}');
    }
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


