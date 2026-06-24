import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/broker_client.dart';
import '../net/discovery.dart';
import '../p2p/p2p_coordinator.dart';
import '../protocol/auth_mode.dart';
import '../protocol/envelope.dart';
import '../protocol/messages.dart';
import '../protocol/pair_uri.dart';

/// 持久化键。
class _Keys {
  static const broker = 'settings.broker_host';
  static const port = 'settings.broker_port';
  static const secure = 'settings.broker_secure';
  static const psk = 'settings.psk';
  static const controllerId = 'settings.controller_id';
}

/// 当前拓扑（§14）。
enum Topology { dedicated, cohosted, p2p }

extension TopologyLabel on Topology {
  String get label => switch (this) {
        Topology.dedicated => '专用 broker',
        Topology.cohosted => '寄生 broker',
        Topology.p2p => '无 broker (p2p)',
      };
}

/// 遥控端中枢状态(ChangeNotifier)：
///  - 持有设置(broker 地址/PSK/controller_id)与 [EnvelopeCodec]。
///  - 持有 [BrokerClient] / [Discovery] / [P2pCoordinator]，按发现结果自动选拓扑(§14.5)。
///  - 对 UI 暴露设备墙快照、缩略图字节、连接态、auth_mode、topology、出站控制命令。
class WallState extends ChangeNotifier {
  WallState();

  // ---- 设置 ----
  String brokerHost = '';
  int brokerPort = 8770;
  bool brokerSecure = false;
  String psk = '';
  String controllerId = '';

  // ---- 运行态 ----
  late final EnvelopeCodec _codec;
  late final BrokerClient _broker;
  late final Discovery _discovery;
  late final P2pCoordinator _p2p;
  bool _inited = false;

  /// 当前拓扑（§14）。默认 p2p，发现到 broker 后切 dedicated。
  Topology _topology = Topology.p2p;

  /// 当前鉴权模式（§13）。默认 open。
  AuthMode _authMode = AuthMode.open;

  WallSnapshot _wall = const WallSnapshot();
  final Map<String, Uint8List> _thumbs = {};
  final List<AnnounceInfo> _discovered = [];
  final List<String> _log = [];
  ConnState _conn = ConnState.disconnected;
  int _p2pPeers = 0;

  /// 当前 broker 接入目标（用于避免发现重复触发时反复重连）。
  String _brokerTarget = '';

  // ---- getters ----
  WallSnapshot get wall => _wall;
  List<WallGroup> get groups => _wall.groups;
  List<DeviceStatus> get devices => _wall.devices;
  List<AnnounceInfo> get discovered => List.unmodifiable(_discovered);
  ConnState get conn => _conn;
  AuthMode get authMode => _authMode;
  Topology get topology => _topology;
  bool get isP2p => _topology == Topology.p2p;
  int get p2pPeers => _p2pPeers;

  /// p2p 下“已连 N 台”，broker 下沿用连接态。
  bool get connected =>
      isP2p ? _p2pPeers > 0 : _conn == ConnState.connected;
  List<String> get logLines => List.unmodifiable(_log);

  /// 由当前连接信息生成一张配对 URI（§15）。
  ///  - broker 模式：用当前 broker host/port。
  ///  - p2p 模式：无单一 broker；用本机作为协调端，host 留空交由 UI 提示手填本机 IP。
  /// [group] 为要邀请加入的目标组（默认 "lobby"）。
  PairUri buildPairUri({String group = 'lobby', String? overrideHost}) {
    final host = overrideHost?.trim().isNotEmpty == true
        ? overrideHost!.trim()
        : (isP2p ? '' : brokerHost);
    return PairUri(
      connHost: host,
      port: isP2p ? 8770 : brokerPort,
      group: group,
      mode: _authMode,
      psk: _authMode == AuthMode.open ? null : psk,
      wss: brokerSecure,
    );
  }

  Uint8List? thumbOf(String deviceId) => _thumbs[deviceId];

  DeviceStatus? deviceById(String id) {
    for (final d in _wall.devices) {
      if (d.deviceId == id) return d;
    }
    return null;
  }

  WallGroup? groupById(String id) {
    for (final g in _wall.groups) {
      if (g.groupId == id) return g;
    }
    return null;
  }

  /// 本组成员的 DeviceStatus。
  List<DeviceStatus> membersOf(String groupId) {
    final g = groupById(groupId);
    if (g == null) return const [];
    return g.members
        .map(deviceById)
        .whereType<DeviceStatus>()
        .toList(growable: false);
  }

  /// 一次性初始化：读持久化设置、建链路、启动发现。
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    await _loadSettings();

    // 引导期 auth_mode：有 PSK → required(签)，无 PSK → open(空 sig)。
    // 连上协调端后据 welcome.auth_mode 再校正(§13)。
    _authMode = psk.isEmpty ? AuthMode.open : AuthMode.required;
    _codec = EnvelopeCodec(
      psk: psk,
      fromAddress: _fromAddress(),
      authMode: _authMode,
    );
    _broker = BrokerClient(codec: _codec, controllerId: controllerId)
      ..onWall = _onWall
      ..onThumb = _onThumb
      ..onState = _onConn
      ..onAuthMode = _onAuthMode
      ..onTopology = _onTopologyHint
      ..onLog = _pushLog;
    _discovery = Discovery(codec: _codec, controllerId: controllerId)
      ..onDevices = _onDiscovered
      ..onLog = _pushLog;
    _p2p = P2pCoordinator(codec: _codec, controllerId: controllerId)
      ..onWall = _onWall
      ..onPeers = _onP2pPeers
      ..onLog = _pushLog;

    await _discovery.start();
    _evaluateTopology();
  }

  String _fromAddress() => 'controller:$controllerId';

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    brokerHost = prefs.getString(_Keys.broker) ?? '';
    brokerPort = prefs.getInt(_Keys.port) ?? 8770;
    brokerSecure = prefs.getBool(_Keys.secure) ?? false;
    psk = prefs.getString(_Keys.psk) ?? '';
    controllerId = prefs.getString(_Keys.controllerId) ?? '';
    if (controllerId.isEmpty) {
      controllerId = 'ctl-${uuid4().substring(0, 8)}';
      await prefs.setString(_Keys.controllerId, controllerId);
    }
  }

  /// 更新设置并持久化；按需重连。
  Future<void> updateSettings({
    String? host,
    int? port,
    bool? secure,
    String? newPsk,
    String? newControllerId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (host != null) {
      brokerHost = host.trim();
      await prefs.setString(_Keys.broker, brokerHost);
    }
    if (port != null) {
      brokerPort = port;
      await prefs.setInt(_Keys.port, port);
    }
    if (secure != null) {
      brokerSecure = secure;
      await prefs.setBool(_Keys.secure, secure);
    }
    if (newPsk != null) {
      psk = newPsk;
      _codec.psk = newPsk;
      await prefs.setString(_Keys.psk, newPsk);
    }
    if (newControllerId != null && newControllerId.trim().isNotEmpty) {
      controllerId = newControllerId.trim();
      _codec.fromAddress = _fromAddress();
      _broker.controllerId = controllerId;
      _discovery.controllerId = controllerId;
      _p2p.controllerId = controllerId;
      await prefs.setString(_Keys.controllerId, controllerId);
    }
    notifyListeners();
    _evaluateTopology();
  }

  /// 选择拓扑并接入（§14.5 零配置默认）：
  ///  - 用户手填了 broker 地址 → 直接连 broker（模式 A/B）。
  ///  - 否则看发现结果：有 broker_hint → 连 broker；只有一堆 p2p 被控端 → p2p 直连。
  void _evaluateTopology() {
    // 手填 broker 优先。
    if (brokerHost.isNotEmpty) {
      _enterBroker(brokerHost, brokerPort, brokerSecure);
      return;
    }
    // 发现结果里找 broker_hint。
    for (final a in _discovered) {
      final ep = a.brokerEndpoint;
      if (ep != null) {
        _enterBroker(ep.host, ep.port, brokerSecure);
        return;
      }
    }
    // 无 broker → p2p：对每台发现到的被控端各开一条 WS（§14.3）。
    if (_discovered.isNotEmpty) {
      _enterP2p();
    } else {
      _pushLog('暂未发现协调端/被控端，等待发现…');
    }
  }

  void _enterBroker(String host, int port, bool secure) {
    if (_topology == Topology.p2p) {
      _p2p.setPeers(const []); // 退出 p2p，断开直连
      _p2pPeers = 0;
    }
    final target = '$host:$port:$secure';
    // welcome 未到前，dedicated 是合理默认；cohosted 对端侧透明，无法区分。
    final wasP2p = _topology == Topology.p2p;
    _topology = Topology.dedicated;
    // 同一目标且已在连接/已连，避免重复 connect 触发退避重置。
    if (target == _brokerTarget && !wasP2p) {
      notifyListeners();
      return;
    }
    _brokerTarget = target;
    notifyListeners();
    _broker.connect(host: host, port: port, secure: secure);
  }

  void _enterP2p() {
    final wasBroker = _topology != Topology.p2p;
    _topology = Topology.p2p;
    if (wasBroker) {
      _broker.disconnect();
      _brokerTarget = '';
    }
    // p2p 下遥控端是协调端：auth_mode 由本端 PSK 决定（有则 required，无则 open，§13/§14.3）。
    _authMode = psk.isEmpty ? AuthMode.open : AuthMode.required;
    _codec.authMode = _authMode;
    _p2p.setPeers([
      for (final a in _discovered)
        if (a.ip.isNotEmpty)
          P2pPeer(
            deviceId: a.deviceId,
            host: a.ip,
            port: 8770,
            deviceName: a.deviceName,
            secure: brokerSecure,
          ),
    ]);
    notifyListeners();
  }

  /// 手动触发一次设备发现广播。
  void refreshDiscovery() => _discovery.discover();

  void reconnect() {
    if (isP2p) {
      _p2p.setPeers(const []);
      _evaluateTopology();
    } else {
      _broker.disconnect();
      _evaluateTopology();
    }
  }

  // ---- 入站回调 ----
  void _onWall(WallSnapshot snap) {
    _wall = snap;
    notifyListeners();
  }

  void _onThumb(String deviceId, Uint8List jpeg) {
    _thumbs[deviceId] = jpeg;
    notifyListeners();
  }

  void _onConn(ConnState s) {
    _conn = s;
    notifyListeners();
  }

  void _onAuthMode(AuthMode mode) {
    _authMode = mode;
    notifyListeners();
  }

  void _onTopologyHint(String topo) {
    final t = switch (topo) {
      'cohosted' => Topology.cohosted,
      'p2p' => Topology.p2p,
      _ => Topology.dedicated,
    };
    if (t != _topology && !isP2p) {
      // broker 声明 cohosted/dedicated：仅更新展示（连接方式无差别）。
      _topology = t == Topology.p2p ? Topology.dedicated : t;
      notifyListeners();
    }
  }

  void _onP2pPeers(int count) {
    _p2pPeers = count;
    notifyListeners();
  }

  void _onDiscovered(List<AnnounceInfo> list) {
    _discovered
      ..clear()
      ..addAll(list);
    // 发现结果变化 → 重新评估拓扑（新被控端加入 p2p、broker 出现等）。
    _evaluateTopology();
    notifyListeners();
  }

  void _pushLog(String line) {
    final stamped = '${DateTime.now().toIso8601String().substring(11, 19)}  $line';
    _log.add(stamped);
    if (_log.length > 200) _log.removeRange(0, _log.length - 200);
    notifyListeners();
  }

  // ---- 出站路由 ----
  /// 计算信封 `to`：单机→player:<id>；组→group:<id>；否则 broker(§2)。
  String _to({String? groupId, String? deviceId}) {
    if (deviceId != null && deviceId.isNotEmpty) return 'player:$deviceId';
    if (groupId != null && groupId.isNotEmpty) return 'group:$groupId';
    return 'broker';
  }

  void _send(String type, Map<String, dynamic> payload,
      {String? groupId, String? deviceId}) {
    final to = _to(groupId: groupId, deviceId: deviceId);
    if (isP2p) {
      _p2p.send(type, to: to, payload: payload);
    } else {
      _broker.send(type, to: to, payload: payload);
    }
  }

  // ---- 出站命令(供 UI 调用) ----
  void cachePrefetch(List<MediaItem> items, {String? groupId}) {
    _send('cache_prefetch', Commands.cachePrefetch(items), groupId: groupId);
  }

  /// 下发 playlist(§6.3)。
  void sendPlaylist({
    required String playlistId,
    required String groupId,
    required bool sync,
    required bool loop,
    required List<MediaItem> items,
  }) {
    _send(
      'playlist',
      Commands.playlist(
        playlistId: playlistId,
        groupId: groupId,
        sync: sync,
        loop: loop,
        items: items,
      ),
      groupId: groupId,
    );
  }

  /// 一键同步播放(§9.1)：
  ///  - broker 模式：下发 prepare，broker 收齐 ready 后广播 play_at。
  ///  - p2p 模式：遥控端本地编排三段握手（fan prepare → 收齐 ready/超时 → play_at）。
  void prepare({
    required String playlistId,
    required String groupId,
    int startIndex = 0,
    int seekMs = 0,
  }) {
    if (isP2p) {
      _p2p.startSync(
        playlistId: playlistId,
        groupId: groupId,
        startIndex: startIndex,
        seekMs: seekMs,
      );
      return;
    }
    _send(
      'prepare',
      Commands.prepare(
        playlistId: playlistId,
        groupId: groupId,
        startIndex: startIndex,
        seekMs: seekMs,
      ),
      groupId: groupId,
    );
  }

  void pause({String? groupId, String? deviceId}) => _send(
      'pause', Commands.pause(groupId: groupId, deviceId: deviceId),
      groupId: groupId, deviceId: deviceId);

  void resume({String? groupId, String? deviceId}) => _send(
      'resume', Commands.resume(groupId: groupId, deviceId: deviceId),
      groupId: groupId, deviceId: deviceId);

  void stop({String? groupId, String? deviceId}) => _send(
      'stop', Commands.stop(groupId: groupId, deviceId: deviceId),
      groupId: groupId, deviceId: deviceId);

  void next({String? groupId, String? deviceId}) => _send(
      'next', Commands.next(groupId: groupId, deviceId: deviceId),
      groupId: groupId, deviceId: deviceId);

  void prev({String? groupId, String? deviceId}) => _send(
      'prev', Commands.prev(groupId: groupId, deviceId: deviceId),
      groupId: groupId, deviceId: deviceId);

  void setVolume(int volume, {String? groupId, String? deviceId}) => _send(
      'set_volume',
      Commands.setVolume(volume: volume, groupId: groupId, deviceId: deviceId),
      groupId: groupId,
      deviceId: deviceId);

  void setMute(bool muted, {String? groupId, String? deviceId}) => _send(
      'set_mute',
      Commands.setMute(muted: muted, groupId: groupId, deviceId: deviceId),
      groupId: groupId,
      deviceId: deviceId);

  /// set_audio_master(§9.3)：指定本组哪几台出声。
  void setAudioMaster({
    required String groupId,
    required List<String> deviceIds,
  }) =>
      _send('set_audio_master',
          Commands.setAudioMaster(groupId: groupId, deviceIds: deviceIds),
          groupId: groupId);

  /// assign_group(§9.3)：改设备分组。
  void assignGroup({required String deviceId, required String groupId}) =>
      _send('assign_group',
          Commands.assignGroup(deviceId: deviceId, groupId: groupId),
          deviceId: deviceId);

  @override
  void dispose() {
    _broker.dispose();
    _discovery.dispose();
    _p2p.dispose();
    super.dispose();
  }
}
