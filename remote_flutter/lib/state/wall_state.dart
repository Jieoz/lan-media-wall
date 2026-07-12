
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/broker_client.dart';
import '../net/discovery.dart';
import '../net/media_upload.dart';
import '../p2p/p2p_coordinator.dart';
import '../protocol/auth_mode.dart';
import '../protocol/envelope.dart';
import '../protocol/messages.dart';
import '../protocol/pair_uri.dart';
import '../protocol/remote_endpoint.dart';

/// 持久化键。
class _Keys {
  static const broker = 'settings.broker_host';
  static const port = 'settings.broker_port';
  static const secure = 'settings.broker_secure';
  static const psk = 'settings.psk';
  static const mediaUploadToken = 'settings.media_upload_token';
  static const controllerId = 'settings.controller_id';
}

/// 一台设备在墙上的接入态（§14.5 可见性）。发现/添加即以占位卡出现，
/// 随连接推进更新，失败带原因——不再等 state 快照才可见、不再静默。
enum LinkPhase { discovered, connecting, connected, failed }

extension LinkPhaseLabel on LinkPhase {
  String get label => switch (this) {
        LinkPhase.discovered => '已发现',
        LinkPhase.connecting => '连接中',
        LinkPhase.connected => '已连接',
        LinkPhase.failed => '失败',
      };
}

/// 墙面 UI 的统一设备视图项：把「发现/手动添加的占位」与「WS 已连回传的
/// [DeviceStatus]」合并成一张卡。[status] 为 null 表示尚无状态快照（占位），
/// [phase] 给出接入进度，[error] 在失败时给出原因。
class WallDevice {
  const WallDevice({
    required this.deviceId,
    required this.deviceName,
    required this.phase,
    this.status,
    this.ip = '',
    this.error,
  });

  final String deviceId;
  final String deviceName;
  final LinkPhase phase;

  /// 已连回传的完整状态；占位阶段为 null。
  final DeviceStatus? status;
  final String ip;
  final String? error;

  bool get isPlaceholder => status == null;
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
  String mediaUploadToken = '';
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

  /// 当前密钥模式（§17.3）。默认 global（向后兼容；连上协调端 / p2p 兼任时校正）。
  KeyMode _keyMode = KeyMode.global;

  WallSnapshot _wall = const WallSnapshot();
  final Map<String, Uint8List> _thumbs = {};
  final List<AnnounceInfo> _discovered = [];
  final List<String> _log = [];
  ConnState _conn = ConnState.disconnected;
  int _p2pPeers = 0;
  final Map<String, Completer<String>> _pendingDebugSnapshot = {};
  final Map<String, Completer<File>> _pendingLogDownload = {};
  final Map<String, String> _updateStatus = {};
  final Map<String, String> _updateDetail = {};

  /// broker 单播只按 device_id 路由；同一台设备同一时刻只挂一个 pending 请求，
  /// 因此用 device_id 作 key。空 device_id（组播/广播场景）统一落到 '*' 桶，
  /// 保证回调必能找到对应 completer 完成它，而不是永远超时。
  static const String _anyDeviceKey = '*';
  String _pendingKey(String? deviceId) =>
      (deviceId == null || deviceId.isEmpty) ? _anyDeviceKey : deviceId;

  /// §14.5 可见性：每台 device_id 的接入进度与失败原因（p2p 直连回调驱动；
  /// broker 模式下由 wall 快照的 online 推断）。与 _discovered/_wall 合并成 [wallDevices]。
  final Map<String, LinkPhase> _linkPhase = {};
  final Map<String, String> _linkError = {};
  final Set<String> _forgottenDevices = {};

  /// 根因 A 修复:占位 id(`host:port`,扫码无真实 device_id 时的兜底键) → 真实
  /// device_id 的别名映射。p2p 归一([P2pCoordinator.onPeerIdentified])发生时登记。
  /// [wallDevices] 据此把「占位卡」折叠进「真实卡」,同一台盒子只剩一张卡。
  final Map<String, String> _idAlias = {};

  /// 当前 broker 接入目标（用于避免发现重复触发时反复重连）。
  String _brokerTarget = '';

  // ---- getters ----
  WallSnapshot get wall => _wall;
  List<WallGroup> get groups => _wall.groups;
  List<DeviceStatus> get devices => _wall.devices;
  List<AnnounceInfo> get discovered => List.unmodifiable(_discovered);
  ConnState get conn => _conn;
  AuthMode get authMode => _authMode;
  KeyMode get keyMode => _keyMode;
  Topology get topology => _topology;
  bool get isP2p => _topology == Topology.p2p;
  int get p2pPeers => _p2pPeers;

  /// p2p 下“已连 N 台”，broker 下沿用连接态。
  bool get connected =>
      isP2p ? _p2pPeers > 0 : _conn == ConnState.connected;
  List<String> get logLines => List.unmodifiable(_log);

  /// §14.5 墙面统一设备视图（修 Bug 2「添加/发现却看不到设备」）：
  ///  - 先放所有 WS 已回传状态的设备（[DeviceStatus] 覆盖占位，用 device_id 去重）；
  ///  - 再补上「已发现/手动添加但尚未回传状态」的设备，以占位卡出现，带接入态；
  ///  - 每台都带 [LinkPhase]（发现/连接中/已连接/失败）与失败原因，不再静默。
  ///
  /// 这样粘贴二维码 / UDP 发现 / 手填 IP 的设备**立即可见**，不必等 state 快照。
  List<WallDevice> get wallDevices {
    final out = <WallDevice>[];
    final seen = <String>{};
    // 1. WS 已回传状态的设备优先，DeviceStatus 覆盖占位。
    for (final d in _wall.devices) {
      if (_forgottenDevices.contains(d.deviceId)) continue;
      seen.add(d.deviceId);
      // broker 模式无逐台直连回调：online 即视为已连接，否则回落到记录的相位。
      final phase = _linkPhase[d.deviceId] ??
          (d.online ? LinkPhase.connected : LinkPhase.discovered);
      AnnounceInfo? discovered;
      for (final a in _discovered) {
        if (_resolveId(a.deviceId) == d.deviceId) {
          discovered = a;
          break;
        }
      }
      out.add(WallDevice(
        deviceId: d.deviceId,
        deviceName: d.deviceName ?? d.deviceId,
        phase: d.online ? LinkPhase.connected : phase,
        status: d,
        ip: discovered?.ip ?? '',
        error: _linkError[d.deviceId],
      ));
    }
    // 2. 发现/手动添加但还没状态快照的 → 占位卡。
    //    根因 A 修复：占位 id(`host:port`,扫码无真实 device_id)一旦经 p2p 归一
    //    ([_idAlias]),就解析到真实 device_id。若该真实 id 已在上一步出过卡(status
    //    已回传),则跳过——否则会出现「占位卡 + 真实卡」双卡。相位/失败原因也按真实
    //    id 取(归一时已迁移过去)。
    for (final a in _discovered) {
      final id = _resolveId(a.deviceId);
      if (_forgottenDevices.contains(a.deviceId) || _forgottenDevices.contains(id)) continue;
      if (seen.contains(id)) continue;
      seen.add(id);
      out.add(WallDevice(
        deviceId: id,
        deviceName: a.deviceName.isNotEmpty ? a.deviceName : id,
        phase: _linkPhase[id] ?? LinkPhase.discovered,
        ip: a.ip,
        error: _linkError[id],
      ));
    }
    return out;
  }

  /// 由当前连接信息生成一张配对 URI（§15 + §17.4）。
  ///  - broker 模式：用当前 broker host/port。
  ///  - p2p 模式：无单一 broker；用本机作为协调端，host 留空交由 UI 提示手填本机 IP。
  ///
  /// 密钥下发（§17.4 零感知）：
  ///  - open：不含任何密钥。
  ///  - global：携带全局 PSK（= v1.2；老 broker / 兼容回退）。
  ///  - derived：协调端用 PSK 为受邀端 identity 现场派生 device_key，QR 只带 `dk`+`id`，
  ///    **永不下发 PSK**。需要受邀端 identity → 由 [inviteeId]（如 `win-lobby-01`）拼成
  ///    `player:<inviteeId>` 派生；[inviteeId] 为空时退化为 global（仍携带 PSK，确保可用）。
  /// [group] 为要邀请加入的目标组（默认 "lobby"）。
  PairUri buildPairUri({
    String group = 'lobby',
    String? overrideHost,
    String? inviteeId,
  }) {
    final host = overrideHost?.trim().isNotEmpty == true
        ? overrideHost!.trim()
        : (isP2p ? '' : brokerHost);
    final port = isP2p ? 8770 : brokerPort;
    // open：纯进组，不含密钥。
    if (_authMode == AuthMode.open) {
      return PairUri(
        connHost: host, port: port, group: group,
        mode: _authMode, keyMode: KeyMode.global, wss: brokerSecure,
      );
    }
    final invitee = inviteeId?.trim() ?? '';
    // derived + 持 PSK + 已知受邀端 id → 派生该端 device_key，QR 不含 PSK（§17.4）。
    if (_keyMode == KeyMode.derived && psk.isNotEmpty && invitee.isNotEmpty) {
      final identity = 'player:$invitee';
      return PairUri(
        connHost: host, port: port, group: group,
        mode: _authMode, keyMode: KeyMode.derived,
        dk: deriveDeviceKeyHex(psk, identity), id: identity,
        wss: brokerSecure,
      );
    }
    // 其余（global，或 derived 但未指定受邀端 id）→ 携带全局 PSK（兼容回退）。
    return PairUri(
      connHost: host, port: port, group: group,
      mode: _authMode, keyMode: KeyMode.global,
      psk: psk, wss: brokerSecure,
    );
  }

  Uint8List? thumbOf(String deviceId) => _thumbs[deviceId];

  /// 消费被控端出示的 enroll 配对 URI（§15 反向）：被控端(TV 盒/Windows)无摄像头，
  /// **出示** `lmw://pair?host=<自身IP>&port=<p2p>&id=<device_id>&name=<名>&mode=open`，
  /// 由遥控端扫码/粘贴消费。本方法解析该 URI，把该端登记进发现清单——等价于一次
  /// 成功的 UDP 发现，随后 [_evaluateTopology] 自动对其建立 p2p 直连(§14.5)，
  /// 走的是与自动发现完全相同的一条入组路径，不新造配对逻辑。
  ///
  /// 返回解析出的设备名(用于 UI 提示)；URI 非法或缺 host 时返回 null。
  String? addDeviceFromPairUri(String raw) {
    final uri = PairUri.tryParse(raw);
    if (uri == null || uri.connHost.isEmpty) return null;
    // enroll URI 的 `id` 即被控端 device_id；缺失时用 host:port 兜底成稳定键。
    final deviceId = (uri.id != null && uri.id!.isNotEmpty)
        ? uri.id!
        : '${uri.connHost}:${uri.port}';
    _forgottenDevices.remove(deviceId);
    final name =
        (uri.name != null && uri.name!.isNotEmpty) ? uri.name! : deviceId;
    _discovery.addManual(AnnounceInfo(
      deviceId: deviceId,
      deviceName: name,
      ip: uri.connHost,
    ));
    return name;
  }

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
    // 引导期 key_mode：默认 global（§17.3 向后兼容）；连上协调端读 welcome.key_mode
    // 或 p2p 兼任协调端时再校正（见 _onKeyMode / _enterP2p）。
    _keyMode = KeyMode.global;
    _codec = EnvelopeCodec(
      psk: psk,
      fromAddress: _fromAddress(),
      authMode: _authMode,
      keyMode: _keyMode,
    );
    _broker = BrokerClient(codec: _codec, controllerId: controllerId)
      ..onWall = _onWall
      ..onThumb = _onThumb
      ..onDiagnostic = _onDiagnostic
      ..onUpdateStatus = _onUpdateStatus
      ..onLogDownload = _onLogDownload
      ..onState = _onConn
      ..onAuthMode = _onAuthMode
      ..onKeyMode = _onKeyMode
      ..onTopology = _onTopologyHint
      ..onLog = _pushLog;
    _discovery = Discovery(codec: _codec, controllerId: controllerId)
      ..onDevices = _onDiscovered
      ..onLog = _pushLog;
    _p2p = P2pCoordinator(codec: _codec, controllerId: controllerId)
      ..onWall = _onWall
      ..onThumb = _onThumb
      ..onPeers = _onP2pPeers
      ..onPeerState = _onPeerState
      ..onPeerIdentified = _onPeerIdentified
      ..onDiagnostic = _onDiagnostic
      ..onUpdateStatus = _onUpdateStatus
      ..onLogDownload = _onLogDownload
      ..onLog = _pushLog;

    await _discovery.start();
    _evaluateTopology();
  }

  String _fromAddress() => 'controller:$controllerId';

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedBrokerHost = prefs.getString(_Keys.broker) ?? '';
    brokerHost = normalizeRemoteHost(savedBrokerHost);
    if (brokerHost != savedBrokerHost) {
      await prefs.setString(_Keys.broker, brokerHost);
    }
    brokerPort = prefs.getInt(_Keys.port) ?? 8770;
    brokerSecure = prefs.getBool(_Keys.secure) ?? false;
    psk = prefs.getString(_Keys.psk) ?? '';
    mediaUploadToken = prefs.getString(_Keys.mediaUploadToken) ?? '';
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
    String? newMediaUploadToken,
    String? newControllerId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (host != null) {
      brokerHost = normalizeRemoteHost(host);
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
    if (newMediaUploadToken != null) {
      mediaUploadToken = newMediaUploadToken.trim();
      await prefs.setString(_Keys.mediaUploadToken, mediaUploadToken);
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
    // §17.3：p2p 兼任协调端时，本端 key_mode 即该拓扑权威。持 PSK → derived（v1.3 默认，
    // 泄露隔离）；无 PSK（open）→ key_mode 无意义，留 global。随 hello 声明给各 player。
    _keyMode = psk.isEmpty ? KeyMode.global : KeyMode.derived;
    _codec.keyMode = _keyMode;
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

  /// Forget/remove a player from this controller. This clears controller-side
  /// discovery cache, P2P connection/status, placeholders, errors, and thumbs;
  /// it does not uninstall or stop the player box.
  Future<void> forgetDevice(String deviceId) async {
    if (deviceId.isEmpty) return;
    final resolved = _resolveId(deviceId);
    _forgottenDevices
      ..add(deviceId)
      ..add(resolved);
    await _discovery.forget(deviceId);
    if (resolved != deviceId) await _discovery.forget(resolved);
    _discovered.removeWhere((a) => a.deviceId == deviceId || a.deviceId == resolved || _resolveId(a.deviceId) == resolved);
    _idAlias.removeWhere((k, v) => k == deviceId || k == resolved || v == deviceId || v == resolved);
    _linkPhase.remove(deviceId);
    _linkPhase.remove(resolved);
    _linkError.remove(deviceId);
    _linkError.remove(resolved);
    _thumbs.remove(deviceId);
    _thumbs.remove(resolved);
    _p2p.forgetDevice(deviceId);
    if (resolved != deviceId) _p2p.forgetDevice(resolved);
    _pushLog('已从控制端移除设备 $resolved');
    _evaluateTopology();
    notifyListeners();
  }

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
    for (final device in snap.devices) {
      final state = device.updateState;
      if (state != null && state.isNotEmpty) {
        _updateStatus[device.deviceId] = state;
        _updateDetail[device.deviceId] = device.updateDetail ?? '';
      }
    }
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

  void _onKeyMode(KeyMode mode) {
    _keyMode = mode;
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

  void _onDiagnostic(String deviceId, String detail) {
    if (deviceId.isEmpty) return;
    _pushLog('[$deviceId] 调试快照: $detail');
    // 完成对应的 pending 请求（优先精确 device_id，回退广播桶）。
    final c = _pendingDebugSnapshot.remove(deviceId) ??
        _pendingDebugSnapshot.remove(_anyDeviceKey);
    if (c != null && !c.isCompleted) c.complete(detail);
  }

  void _onUpdateStatus(String deviceId, String state, String detail, int versionCode) {
    if (deviceId.isEmpty) return;
    _updateStatus[deviceId] = state;
    _updateDetail[deviceId] = detail;
    _pushLog('[$deviceId] 升级状态: $state v$versionCode $detail');
    notifyListeners();
  }

  void _onLogDownload(String deviceId, String text, String fileName) {
    if (deviceId.isEmpty) return;
    _pushLog('[$deviceId] 已收到日志 $fileName (${text.length} 字符)');
    final c = _pendingLogDownload.remove(deviceId) ??
        _pendingLogDownload.remove(_anyDeviceKey);
    if (c == null || c.isCompleted) {
      notifyListeners();
      return;
    }
    // 把回传文本落到用户能找到的位置，而不是系统临时目录。
    // Android 优先公共 Download/LANMediaWall/logs；桌面优先 ~/Downloads/LANMediaWall/logs。
    // 若系统权限/存储策略拦截，再回退到 temp，并把实际路径回显给用户。
    () async {
      try {
        final safeName = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final bundle = _appendControllerDiagnostics(deviceId, text);
        final f = await _writeLogToUserDownloads(safeName, bundle);
        _pushLog('[$deviceId] 诊断日志包已保存: ${f.path}');
        c.complete(f);
      } catch (e) {
        _pushLog('[$deviceId] 日志写盘失败: $e');
        c.completeError(e);
      }
      notifyListeners();
    }();
  }


  String _appendControllerDiagnostics(String deviceId, String playerText) {
    final b = StringBuffer(playerText);
    b.writeln();
    b.writeln();
    b.writeln('===== controller_summary =====');
    b.writeln('time_ms=${DateTime.now().millisecondsSinceEpoch}');
    b.writeln('target_device_id=$deviceId');
    b.writeln('topology=$_topology conn=$_conn p2p_peers=$_p2pPeers auth_mode=$_authMode key_mode=$_keyMode');
    b.writeln('broker=${brokerSecure ? 'wss' : 'ws'}://$brokerHost:$brokerPort');
    b.writeln('wall_devices=${wallDevices.length} groups=${groups.length}');
    for (final d in wallDevices) {
      b.writeln('device id=${d.deviceId} name=${d.deviceName} phase=${d.phase} online=${d.status?.online} ip=${d.ip} error=${d.error ?? ''} update=${_updateStatus[d.deviceId] ?? ''}:${_updateDetail[d.deviceId] ?? ''}');
    }
    b.writeln();
    b.writeln('===== controller_log =====');
    for (final line in _log.take(1000)) {
      b.writeln(line);
    }
    return b.toString();
  }

  Future<File> _writeLogToUserDownloads(String safeName, String text) async {
    final tried = <String>[];
    for (final root in _downloadRoots()) {
      final dir = Directory('$root/LANMediaWall/logs');
      tried.add(dir.path);
      try {
        if (!await dir.exists()) await dir.create(recursive: true);
        final f = File('${dir.path}/$safeName');
        await f.writeAsString(text);
        return f;
      } catch (_) {
        // Try the next platform-specific candidate.
      }
    }
    final dir = Directory('${Directory.systemTemp.path}/lan_media_wall_logs');
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File('${dir.path}/$safeName');
    await f.writeAsString(text);
    _pushLog('公共下载目录不可写，已回退到临时目录: ${f.path}; tried=${tried.join(', ')}');
    return f;
  }

  List<String> _downloadRoots() {
    if (Platform.isAndroid) {
      return const [
        '/storage/emulated/0/Download',
        '/sdcard/Download',
      ];
    }
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return const [];
    return ['$home/Downloads', '$home/下载'];
  }

  /// 供 UI 卡片读取某台设备最近一次升级状态/详情（无则返回 null）。
  String? updateStatusFor(String deviceId) => _updateStatus[deviceId];
  String? updateDetailFor(String deviceId) => _updateDetail[deviceId];

  /// §14.5 可见性：p2p 直连逐台上报接入态 → 更新占位卡的相位与失败原因。
  void _onPeerState(String deviceId, PeerLinkState state, String? reason) {
    _linkPhase[deviceId] = switch (state) {
      PeerLinkState.connecting => LinkPhase.connecting,
      PeerLinkState.connected => LinkPhase.connected,
      PeerLinkState.failed => LinkPhase.failed,
    };
    if (reason != null && reason.isNotEmpty) {
      _linkError[deviceId] = reason;
    } else {
      _linkError.remove(deviceId);
    }
    notifyListeners();
  }

  /// 根因 A 修复：p2p 身份归一发生时（[P2pCoordinator.onPeerIdentified]），把占位
  /// id(`host:port`) → 真实 device_id 登记进别名表，并把占位卡上的接入相位/失败原因
  /// 迁移到真实 id。归一后 [wallDevices] 据 [_idAlias] 把占位卡折叠进真实卡：同一台
  /// 盒子只剩一张卡（修「设备墙双卡」）。
  void _onPeerIdentified(String placeholderId, String realId) {
    if (placeholderId == realId) return;
    _idAlias[placeholderId] = realId;
    // 迁移相位：占位卡此前记录的 connecting/connected 归到真实 id（真实 id 尚无相位
    // 时才迁，避免覆盖已由真实 id 上报的更新状态）。
    final phase = _linkPhase.remove(placeholderId);
    if (phase != null) {
      _linkPhase[realId] = _linkPhase[realId] ?? phase;
    }
    final err = _linkError.remove(placeholderId);
    if (err != null && !_linkError.containsKey(realId)) {
      _linkError[realId] = err;
    }
    notifyListeners();
  }

  /// 把一个 id 解析到其归一后的真实 device_id（无别名则原样返回）。
  String _resolveId(String id) => _idAlias[id] ?? id;

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

  int _send(String type, Map<String, dynamic> payload,
      {String? groupId, String? deviceId}) {
    final to = _to(groupId: groupId, deviceId: deviceId);
    if (isP2p) {
      final delivered = _p2p.send(type, to: to, payload: payload);
      if (delivered == 0) {
        throw StateError('没有可投递的已连接设备（目标: $to）');
      }
      return delivered;
    }
    if (!_broker.send(type, to: to, payload: payload)) {
      throw StateError('broker 未连接，命令未投递（目标: $to）');
    }
    return 1;
  }

  // ---- 出站命令(供 UI 调用) ----
  /// 预缓存下发(§21)。[deviceId] 非空 → 只发这一台(单播,§9.4b 单台推送)。
  void cachePrefetch(List<MediaItem> items, {String? groupId, String? deviceId}) {
    _send('cache_prefetch', Commands.cachePrefetch(items),
        groupId: groupId, deviceId: deviceId);
  }

  /// 下发 playlist(§6.3)。[deviceId] 非空 → 单播给这一台(§9.4b 单台推送);
  /// player 侧 hPlaylist 不做 targetsMe 过滤,靠信封 `to: player:<id>` 精确投递。
  void sendPlaylist({
    required String playlistId,
    required String groupId,
    required bool sync,
    required bool loop,
    required List<MediaItem> items,
    String? deviceId,
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
      deviceId: deviceId,
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

  /// restart(§9.4)：只重启被控端播放 App(保住 Wi-Fi,不整机重启)。单台或整组。
  void restart({String? groupId, String? deviceId}) => _send(
      'restart', Commands.restart(groupId: groupId, deviceId: deviceId),
      groupId: groupId, deviceId: deviceId);

  /// reboot(§10)：整机重启——高危,会中断 Wi-Fi(QZX_C1 需冷启动恢复)。单台或整组。
  void reboot({String? groupId, String? deviceId}) => _send(
      'reboot', Commands.reboot(groupId: groupId, deviceId: deviceId),
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

  /// create_group(§18.1)：新建空分组。broker/p2p 协调端落库后回 wall 快照反映。
  void createGroup({required String groupId, String? name, bool? sync}) =>
      _send('create_group',
          Commands.createGroup(groupId: groupId, name: name, sync: sync));

  /// update_group(§18.2)：改组名/同步模式。
  void updateGroup({required String groupId, String? name, bool? sync}) =>
      _send('update_group',
          Commands.updateGroup(groupId: groupId, name: name, sync: sync));

  /// delete_group(§18.3)：删组,成员回落 [reassignTo]。
  void deleteGroup({required String groupId, String reassignTo = 'default'}) =>
      _send('delete_group',
          Commands.deleteGroup(groupId: groupId, reassignTo: reassignTo));

  /// configure_device(§19)：per-device 配置统一入口(改名/设组/音量/静音)。
  void configureDevice({
    required String deviceId,
    String? deviceName,
    String? groupId,
    int? volume,
    bool? muted,
  }) =>
      _send(
          'configure_device',
          Commands.configureDevice(
            deviceId: deviceId,
            deviceName: deviceName,
            groupId: groupId,
            volume: volume,
            muted: muted,
          ),
          deviceId: deviceId);

  /// 把 APK 暴露成被控端可 GET 的 URL,返回可下发给 update_app 的 (url, sha256)。
  /// broker 模式优先上传到 broker 媒体库;P2P/无 broker 时复用控制端本机临时 HTTP 服务。
  Future<({String url, String sha256})> uploadApkForUpdate({
    required File apk,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (!isP2p && brokerHost.isNotEmpty) {
      final item = await MediaUpload.uploadToBroker(
        file: apk,
        brokerHost: brokerHost,
        type: 'app',
        name: apk.uri.pathSegments.last,
        uploadToken: mediaUploadToken,
        onProgress: onProgress,
      );
      return (url: item.url, sha256: item.sha256 ?? '');
    }

    final item = await uploadLocalMedia(
      file: apk,
      type: 'app',
      name: apk.uri.pathSegments.last,
      onProgress: onProgress,
    );
    return (url: item.url, sha256: item.sha256 ?? '');
  }

  /// update_app(§23)：令目标被控端自更新到 [url] 指向的 APK。
  /// 被控端会二次校验(已鉴权 + versionCode 严格更新 + sha256 比对)才安装。
  void updateApp({
    required String url,
    required int versionCode,
    required String sha256,
    String? versionName,
    String? groupId,
    String? deviceId,
  }) =>
      _send(
        'update_app',
        Commands.updateApp(
          url: url,
          versionCode: versionCode,
          sha256: sha256,
          versionName: versionName,
          groupId: groupId,
          deviceId: deviceId,
        ),
        groupId: groupId,
        deviceId: deviceId,
      );

  /// 请求被控端回传调试快照，包含可下载的本地日志路径和摘要。
  Future<String> requestDebugSnapshot({String? groupId, String? deviceId}) async {
    final key = _pendingKey(deviceId);
    // 若上一次同键请求还挂着，先让它失败释放，避免回调只喂给旧 completer。
    final prevDebug = _pendingDebugSnapshot.remove(key);
    if (prevDebug != null && !prevDebug.isCompleted) {
      prevDebug.completeError(StateError('superseded'));
    }
    final completer = Completer<String>();
    _pendingDebugSnapshot[key] = completer;
    _send(
      'debug_snapshot',
      const {},
      groupId: groupId,
      deviceId: deviceId,
    );
    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } finally {
      // 无论完成还是超时，都从 map 里摘掉，避免泄漏。
      if (identical(_pendingDebugSnapshot[key], completer)) {
        _pendingDebugSnapshot.remove(key);
      }
    }
  }

  /// 请求被控端把日志内容回传并保存到控制端本地文件。
  Future<File> downloadPlayerLogs({
    String? groupId,
    String? deviceId,
    String? fileName,
  }) async {
    final key = _pendingKey(deviceId);
    final prevLog = _pendingLogDownload.remove(key);
    if (prevLog != null && !prevLog.isCompleted) {
      prevLog.completeError(StateError('superseded'));
    }
    final completer = Completer<File>();
    _pendingLogDownload[key] = completer;
    _send(
      'download_logs',
      const {},
      groupId: groupId,
      deviceId: deviceId,
    );
    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } finally {
      if (identical(_pendingLogDownload[key], completer)) {
        _pendingLogDownload.remove(key);
      }
    }
  }

  // ---- 本地媒体上传(§20 A+B) ----
  /// 模式 A 的控制端临时 HTTP 服务(p2p / 无 broker 时用)。按需惰性启动。
  final LocalMediaServer _localMedia = LocalMediaServer();

  /// 上传一个本地文件并返回可下发的 [MediaItem](url 已回填)。自动择路(§20):
  ///  - broker 模式:上传到 broker 媒体库(模式 B),失败回落模式 A。
  ///  - p2p 模式:走控制端临时 HTTP 服务(模式 A)。
  ///
  /// [onProgress] 上报上传进度(仅模式 B 有意义)。播放模型不变:被控端随后走
  /// cache_prefetch 从此 URL 下载到**本地缓存**再播放(设计合同 §0)。
  Future<MediaItem> uploadLocalMedia({
    required File file,
    required String type, // "video" | "image"
    required String name,
    int? durationMs,
    void Function(int sent, int total)? onProgress,
  }) async {
    // broker 模式且已知 broker host → 模式 B(主路径)。
    if (!isP2p && brokerHost.isNotEmpty) {
      try {
        return await MediaUpload.uploadToBroker(
          file: file,
          brokerHost: brokerHost,
          type: type,
          name: name,
          durationMs: durationMs,
          uploadToken: mediaUploadToken,
          onProgress: onProgress,
        );
      } catch (e) {
        _pushLog('broker 上传失败,回落本机临时服务: $e');
        // 落到模式 A。
      }
    }
    // 模式 A:控制端临时 HTTP 服务。需要本机 LAN IP。
    final ip = await _localIp();
    if (ip == null || ip.isEmpty) {
      throw StateError('无法确定本机 LAN IP,模式 A 上传不可用');
    }
    if (!_localMedia.running) {
      await _localMedia.start(bindHost: ip);
      _pushLog('本机媒体服务已启动($ip:${_localMedia.port})');
    }
    return MediaUpload.registerLocal(
      file: file,
      server: _localMedia,
      type: type,
      name: name,
      durationMs: durationMs,
    );
  }

  /// 一键同步播放的**预缓存栅栏**版(§21):下发 playlist(标记 sync) → 发
  /// prepare(prefetch:true),让 broker/协调端等**全员 cache=ready** 才统一起播。
  /// [deviceId] 非空 → §9.4b 单台推送起播:只把这一台纳入 ready 会话、只给它发
  /// play_at(不牵动整组)。p2p 下协调端把 targets 锁到这一台;broker 下 prepare
  /// payload 带 device_id,broker 收敛成员到该台。
  void prepareWithBarrier({
    required String playlistId,
    required String groupId,
    int startIndex = 0,
    int seekMs = 0,
    String? deviceId,
  }) {
    if (isP2p) {
      // p2p 下由协调端本地编排;用长栅栏超时(120s)等各台缓存+校验完成再回 ready(§21.3)。
      _p2p.startSync(
        playlistId: playlistId,
        groupId: groupId,
        startIndex: startIndex,
        seekMs: seekMs,
        readyTimeoutMsOverride: 120000,
        prefetchBarrier: true,
        barrierTimeoutMs: 120000,
        deviceId: deviceId,
      );
      return;
    }
    _send(
      'prepare',
      {
        ...Commands.prepare(
          playlistId: playlistId,
          groupId: groupId,
          startIndex: startIndex,
          seekMs: seekMs,
          deviceId: deviceId,
        ),
        'prefetch': true, // §21.2 走长栅栏超时,等全员缓存就绪
      },
      groupId: groupId,
      deviceId: deviceId,
    );
  }

  /// 取本机首个非回环 IPv4 地址(模式 A 对外 URL / 首启页显示用)。
  Future<String?> _localIp() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  void dispose() {
    _broker.dispose();
    _discovery.dispose();
    _p2p.dispose();
    _localMedia.stop();
    super.dispose();
  }
}
