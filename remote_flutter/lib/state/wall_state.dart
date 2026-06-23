import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/broker_client.dart';
import '../net/discovery.dart';
import '../protocol/envelope.dart';
import '../protocol/messages.dart';

/// 持久化键。
class _Keys {
  static const broker = 'settings.broker_host';
  static const port = 'settings.broker_port';
  static const secure = 'settings.broker_secure';
  static const psk = 'settings.psk';
  static const controllerId = 'settings.controller_id';
}

/// 遥控端中枢状态(ChangeNotifier)：
///  - 持有设置(broker 地址/PSK/controller_id)与 [EnvelopeCodec]。
///  - 持有 [BrokerClient] 与 [Discovery]，把入站快照/缩略图/连接态归并进本状态。
///  - 对 UI 暴露设备墙快照、缩略图字节、连接态、出站控制命令。
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
  bool _inited = false;

  WallSnapshot _wall = const WallSnapshot();
  final Map<String, Uint8List> _thumbs = {};
  final List<AnnounceInfo> _discovered = [];
  final List<String> _log = [];
  ConnState _conn = ConnState.disconnected;

  // ---- getters ----
  WallSnapshot get wall => _wall;
  List<WallGroup> get groups => _wall.groups;
  List<DeviceStatus> get devices => _wall.devices;
  List<AnnounceInfo> get discovered => List.unmodifiable(_discovered);
  ConnState get conn => _conn;
  bool get connected => _conn == ConnState.connected;
  List<String> get logLines => List.unmodifiable(_log);

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

    _codec = EnvelopeCodec(psk: psk, fromAddress: _fromAddress());
    _broker = BrokerClient(codec: _codec, controllerId: controllerId)
      ..onWall = _onWall
      ..onThumb = _onThumb
      ..onState = _onConn
      ..onLog = _pushLog;
    _discovery = Discovery(codec: _codec, controllerId: controllerId)
      ..onDevices = _onDiscovered
      ..onLog = _pushLog;

    await _discovery.start();
    _connectBroker();
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
      await prefs.setString(_Keys.controllerId, controllerId);
    }
    notifyListeners();
    _connectBroker();
  }

  void _connectBroker() {
    if (brokerHost.isEmpty) {
      _pushLog('未配置 broker 地址，跳过连接');
      return;
    }
    _broker.connect(
      host: brokerHost,
      port: brokerPort,
      secure: brokerSecure,
    );
  }

  /// 手动触发一次设备发现广播。
  void refreshDiscovery() => _discovery.discover();

  void reconnect() {
    _broker.disconnect();
    _connectBroker();
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

  void _onDiscovered(List<AnnounceInfo> list) {
    _discovered
      ..clear()
      ..addAll(list);
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
    _broker.send(type, to: _to(groupId: groupId, deviceId: deviceId),
        payload: payload);
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

  /// 一键同步播放(§9.1)：下发 prepare，broker 收齐 ready 后广播 play_at。
  void prepare({
    required String playlistId,
    required String groupId,
    int startIndex = 0,
    int seekMs = 0,
  }) {
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
    super.dispose();
  }
}
