
import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
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
import '../ui/connection_status.dart';
import '../util/apk_manifest.dart';
import 'broker_migration.dart';
import 'cache_ops.dart';
import 'media_progress.dart';

/// 持久化键。
class _Keys {
  static const broker = 'settings.broker_host';
  static const port = 'settings.broker_port';
  static const secure = 'settings.broker_secure';
  static const psk = 'settings.psk';
  static const mediaUploadToken = 'settings.media_upload_token';
  static const controllerId = 'settings.controller_id';
  static const connectionMode = 'settings.connection_mode';
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

  /// 操作员选择的连接方式（§B）。默认 autoP2p（P2P 优先）；迁移见 [_loadSettings]。
  /// 决定 [_evaluateTopology] 是否拨号手填 broker——想走 P2P 的控制端不会因残留
  /// broker 地址被动连 broker。
  ConnectionMode _connectionMode = ConnectionMode.autoP2p;
  ConnectionMode get connectionMode => _connectionMode;

  // ---- 运行态 ----
  late final EnvelopeCodec _codec;
  late final BrokerClient _broker;
  late final Discovery _discovery;
  late final P2pCoordinator _p2p;
  bool _inited = false;
  // True only while _broker/_discovery/_p2p are allocated AND still live. init()
  // sets it when it allocates the links; _teardownLinks() clears it after
  // releasing them. Because the links are `late final`, disposing an unassigned
  // one throws LateInitializationError, so every teardown path is gated on this
  // flag — there is nothing to release when it is false, and clearing it makes
  // teardown idempotent (dispose racing init's own post-await teardown).
  bool _linksReady = false;
  // Set the instant dispose() runs. init() is async: dispose() can land while it
  // is parked at an `await` (fast unmount, or a provider torn down before the
  // first SharedPreferences load resolves). Merely making dispose() return
  // normally is not enough — the parked init() would still resume, allocate the
  // links, start discovery, and notify a dead ChangeNotifier. init() therefore
  // re-checks this flag after every await and bails (releasing anything it did
  // allocate) so no post-dispose allocation/start/notify can occur.
  bool _disposed = false;

  /// 当前拓扑（§14）。默认 p2p，发现到 broker 后切 dedicated。
  /// 这是本端 **实际运行** 的连接方式(operating topology)。
  Topology _topology = Topology.p2p;

  /// 协调端在 welcome 里 **声明** 的拓扑(declared topology)。与 [_topology] 分开记：
  /// 一个走 broker(dedicated)连接却声明 topology=p2p 的对端会让「日志说 p2p、汇总说
  /// dedicated」自相矛盾(E0001)。分开存后,诊断汇总同时打印 operating + declared,冲突
  /// 变成可解释的事实而非矛盾。null = welcome 未声明。
  String? _declaredTopology;

  /// 当前鉴权模式（§13）。默认 open。
  AuthMode _authMode = AuthMode.open;

  /// 当前密钥模式（§17.3）。默认 global（向后兼容；连上协调端 / p2p 兼任时校正）。
  KeyMode _keyMode = KeyMode.global;

  WallSnapshot _wall = const WallSnapshot();
  final Map<String, Uint8List> _thumbs = {};
  final Map<String, int> _thumbSeq = {};
  final Map<String, String> _thumbSession = {};
  final Map<String, String> _thumbItem = {};
  final Map<String, int> _thumbModeGeneration = {};

  /// §6.4 the ONE shared media-push progress state machine (E0001). Fed by
  /// [_onWall] for BOTH transports (P2P and broker converge there), so progress
  /// consumption/UI is transport-agnostic. Keyed device+item+generation with
  /// monotonic 0..100 and never-100-before-`ready` guarantees.
  final MediaProgressMachine _progress = MediaProgressMachine();

  /// §27/§28 缓存清理/清单的一体化归约器(E0001)。Broker 与 P2P 的结果接收路径都汇入
  /// 这一个 reducer(见 [_onCacheCleanupResult]/[_onCacheInventoryResult]),按
  /// request_id+device_id 键做设备隔离、幂等、陈旧拒绝、超时与终态区分。传输无关。
  final CacheOpsReducer _cacheOps = CacheOpsReducer();
  int _nextCacheReq = 0;

  /// 缓存操作视图(UI 读取: 每台设备最近的清理/清单结果、悬挂态)。
  CacheOperation? cacheOperationFor(String requestId, String deviceId) =>
      _cacheOps.operationFor(requestId, deviceId);
  bool cacheHasPending(String deviceId) => _cacheOps.hasPending(deviceId);
  Iterable<CacheOperation> get cacheOperations => _cacheOps.operations;

  /// deviceId → controller-assigned push-job generation. Bumped by [_beginPushJob]
  /// whenever a fresh push (replace playlist / local media) starts, so progress
  /// resets per job. Absent → generation 0 (passive tracking of ambient status).
  final Map<String, int> _pushGeneration = {};

  /// deviceId → controller-generated identity of its current replace job.
  /// The player echoes this only after adopting that exact command; playlist_id
  /// is reusable and therefore cannot be used as an adoption acknowledgement.
  final Map<String, String> _jobPushId = {};
  int _nextPushId = 0;
  final List<AnnounceInfo> _discovered = [];
  final List<String> _log = [];
  ConnState _conn = ConnState.disconnected;
  int _p2pPeers = 0;
  final Map<String, Completer<String>> _pendingDebugSnapshot = {};
  final Map<String, Completer<File>> _pendingLogDownload = {};
  final Map<String, String> _updateStatus = {};
  final Map<String, String> _updateDetail = {};
  final Map<String, Map<String, dynamic>> _configPatchResults = {};
  final Map<String, Completer<Map<String, dynamic>>> _pendingConfigResults = {};
  final Map<String, int> _brokerMigrationRevision = {};
  int _nextConfigRequest = 0;
  final Map<String, RuntimeModeResult> _runtimeModeResults = {};
  final Map<String, MusicPlaylistResult> _musicPlaylistResults = {};
  final Map<String, Completer<RuntimeModeResult>> _pendingRuntimeMode = {};
  final Map<String, Completer<MusicPlaylistResult>> _pendingMusicPlaylist = {};
  final Map<String, List<MediaItem>> _musicDrafts = {};
  final Map<String, List<MediaItem>> _pendingMusicItems = {};
  int _nextRuntimeModeRequest = 0;
  int _nextMusicPlaylistRequest = 0;
  BrokerMigrationBatch? _bulkBrokerMigration;

  BrokerMigrationBatch? get bulkBrokerMigration => _bulkBrokerMigration;

  /// Latest acknowledged §19 result for a device.
  Map<String, dynamic>? configPatchResultFor(String deviceId) =>
      _configPatchResults[deviceId];
  RuntimeModeResult? runtimeModeResultFor(String deviceId) =>
      _runtimeModeResults[deviceId];
  MusicPlaylistResult? musicPlaylistResultFor(String deviceId) =>
      _musicPlaylistResults[deviceId];
  List<MediaItem> musicPlaylistFor(String deviceId) {
    DeviceStatus? status;
    for (final device in _wall.devices) {
      if (device.deviceId == deviceId) {
        status = device;
        break;
      }
    }
    final snapshot = status?.activeMusicPlaylist;
    if (snapshot != null) return List.unmodifiable(snapshot.items);
    return List.unmodifiable(_musicDrafts[deviceId] ?? const <MediaItem>[]);
  }

  bool hasAuthoritativeMusicPlaylist(String deviceId) => _wall.devices
      .where((d) => d.deviceId == deviceId)
      .any((d) => d.activeMusicPlaylist != null);

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

  /// §6.4 current push-job generation for a device (0 when none started).
  int pushGenerationOf(String deviceId) => _pushGeneration[deviceId] ?? 0;

  /// §6.4 aggregated progress for one device's active push job, or null.
  DeviceJobProgress? deviceProgress(String deviceId) =>
      _progress.deviceJob(deviceId, pushGenerationOf(deviceId));

  /// §6.4 the shared progress machine (read-only use by UI/tests).
  MediaProgressMachine get progress => _progress;

  /// §6.4 fan-out progress across [deviceIds] for their own job generations.
  ({int percent, int completeDevices, int totalDevices, int errorDevices})
      batchProgress(Iterable<String> deviceIds) =>
          _progress.batchProgress(deviceIds, pushGenerationOf);

  /// §6.4/E0002 mark the start of a fresh push job for these devices, bumping
  /// each one's generation AND seeding the progress machine with the job's
  /// [expectedItems] so a re-push neither inherits stale percents nor lets a
  /// pre-command snapshot's old `ready` instantly report 100 (the stale guard
  /// in [MediaProgressMachine.beginJob] holds until the device adopts the job).
  /// [pushId] is remembered so [_onWall] can confirm adoption and release
  /// the guard for cached-instant re-pushes.
  void _beginPushJob(
    Iterable<String> deviceIds,
    Iterable<String> expectedItems, {
    required String pushId,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final items = expectedItems.toList(growable: false);
    for (final id in deviceIds) {
      if (id.isEmpty) continue;
      final gen = (_pushGeneration[id] ?? 0) + 1;
      _pushGeneration[id] = gen;
      _jobPushId[id] = pushId;
      _progress.beginJob(id, gen, items, now: now);
    }
  }

  void _clearPushJob(Iterable<String> deviceIds) {
    for (final id in deviceIds) {
      _progress.resetDevice(id);
      _pushGeneration.remove(id);
      _jobPushId.remove(id);
    }
  }

  /// §6.4/E0004 test seam: drive a fresh push job exactly as [sendPlaylist]'s
  /// replace branch does, without the network `_send` (which needs live links).
  /// Lets a WallState-level regression prove the REAL edge-triggered adoption in
  /// [_onWall] — not a hand-called [MediaProgressMachine.confirmJobStarted].
  @visibleForTesting
  void debugBeginPushJob(
    Iterable<String> deviceIds,
    Iterable<String> expectedItems, {
    required String pushId,
  }) =>
      _beginPushJob(deviceIds, expectedItems, pushId: pushId);

  /// §6.4/E0004 test seam: feed a wall snapshot through the identical ingestion
  /// path a broker/P2P frame takes ([_onWall]), so tests exercise the true
  /// pushId-adoption / stale-guard / interrupt logic rather than re-simulating it.
  @visibleForTesting
  void debugIngestWall(WallSnapshot snap) => _onWall(snap);

  @visibleForTesting
  void debugClearPushJob(Iterable<String> deviceIds) =>
      _clearPushJob(deviceIds);

  /// §27/§28 test seam: feed a raw cache result frame through the identical
  /// ingestion path a broker/P2P frame takes ([_onCacheCleanupResult] /
  /// [_onCacheInventoryResult]), so UI/state tests exercise the real converged
  /// reducer matching (stale/idempotent/terminal) rather than re-simulating it.
  /// Test seam: when true, cache_cleanup/inventory begin as pending but do not
  /// call the live transport. Widget/unit tests can then settle via
  /// [debugIngestCacheCleanupResult] without needing init()/links. Production
  /// always leaves this false so undeliverable sends still fail closed.
  @visibleForTesting
  bool debugHoldOutboundCache = false;

  @visibleForTesting
  void debugIngestCacheCleanupResult(Map<String, dynamic> payload) =>
      _onCacheCleanupResult(payload);

  @visibleForTesting
  void debugIngestCacheInventoryResult(Map<String, dynamic> payload) =>
      _onCacheInventoryResult(payload);

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

  /// §B 由**实际拓扑 + 对端/连接态**派生的连接标签，绝不因保存成功乐观显示已连接。
  String get connectionStatusLabel =>
      connectionLabel(topology: _topology, peers: _p2pPeers, conn: _conn);
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
  ///
  /// init() 是异步的:每个 `await` 都是一个可被 [dispose] 抢先的悬挂点(快速卸载 /
  /// provider 尚未收到首个设置就被拆)。因此每个 await 之后都重新检查 [_disposed]:
  /// 一旦已析构就不再分配/启动/通知,并释放此前已分配的链路,保证不会有任何
  /// post-dispose 的分配、启动或对已死 ChangeNotifier 的 notify。
  Future<void> init() async {
    if (_inited || _disposed) return;
    _inited = true;
    await _loadSettings();
    if (_disposed) return; // 析构发生在读设置期间:不分配任何链路。

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
      ..onCacheCleanupResult = _onCacheCleanupResult
      ..onCacheInventoryResult = _onCacheInventoryResult
      ..onConfigPatchResult = _onConfigPatchResult
      ..onRuntimeModeResult = _onRuntimeModeResult
      ..onMusicPlaylistResult = _onMusicPlaylistResult
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
      ..onCacheCleanupResult = _onCacheCleanupResult
      ..onCacheInventoryResult = _onCacheInventoryResult
      ..onConfigPatchResult = _onConfigPatchResult
      ..onRuntimeModeResult = _onRuntimeModeResult
      ..onMusicPlaylistResult = _onMusicPlaylistResult
      ..onLog = _pushLog;
    _linksReady = true;

    await _discovery.start();
    if (_disposed) {
      // 析构发生在发现启动期间。dispose() 已跑过 _teardownLinks() 并清了
      // _linksReady,但 Discovery.start() 可能在 dispose 之后才 resume 并重新
      // 绑定 socket/定时器。此处链路必然已分配(在 await 前),直接再 dispose 一次
      // (三者皆幂等)以关掉这次可能的重绑,且不评估拓扑/通知已死的 ChangeNotifier。
      _broker.dispose();
      _discovery.dispose();
      _p2p.dispose();
      _linksReady = false;
      return;
    }
    _evaluateTopology();
  }

  /// 释放已分配的链路,恰好一次。仅 [dispose] 调用;[_linksReady] 兼作幂等闸门:
  /// 未分配(dispose-before-init / 无 init)时为 false,直接空操作,避开对未赋值
  /// `late final` 的访问(LateInitializationError);释放后清零,重复调用即空操作。
  void _teardownLinks() {
    if (!_linksReady) return;
    _linksReady = false;
    _broker.dispose();
    _discovery.dispose();
    _p2p.dispose();
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
    // §B 连接方式迁移：显式持久化值优先；否则由既有设置推断——存过 broker 地址的
    // 老用户迁到 broker 模式（保持其当前行为），否则默认 autoP2p（P2P 优先）。
    final storedMode = prefs.getString(_Keys.connectionMode);
    if (storedMode != null) {
      _connectionMode = ConnectionModeStore.fromStore(storedMode);
    } else {
      _connectionMode = brokerHost.isNotEmpty
          ? ConnectionMode.broker
          : ConnectionMode.autoP2p;
      await prefs.setString(_Keys.connectionMode, _connectionMode.storeKey);
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
    ConnectionMode? connectionMode,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (connectionMode != null) {
      _connectionMode = connectionMode;
      await prefs.setString(_Keys.connectionMode, connectionMode.storeKey);
    }
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
    // §B 连接方式是操作员意图的权威：autoP2p 模式**忽略**手填/发现的 broker，走
    // 发现 → P2P 直连；只有 broker 模式才主动拨号 broker。这样一个想走 P2P 的控制端
    // 不会因残留 broker 地址被动连 broker。
    if (_connectionMode == ConnectionMode.broker) {
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
    _dropThumb(deviceId);
    _dropThumb(resolved);
    _p2p.forgetDevice(deviceId);
    if (resolved != deviceId) _p2p.forgetDevice(resolved);
    _progress.forgetDevice(deviceId);
    if (resolved != deviceId) _progress.forgetDevice(resolved);
    _pushGeneration.remove(deviceId);
    _pushGeneration.remove(resolved);
    _jobPushId.remove(deviceId);
    _jobPushId.remove(resolved);
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
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final device in snap.devices) {
      final thumbItem = _thumbItem[device.deviceId];
      final thumbGeneration = _thumbModeGeneration[device.deviceId];
      if (!device.online ||
          device.runtimeMode != RuntimeMode.visual ||
          device.current == null ||
          (thumbItem != null && thumbItem != device.current!.itemId) ||
          (thumbGeneration != null &&
              thumbGeneration != device.modeGeneration)) {
        _dropThumb(device.deviceId);
      }
      final state = device.updateState;
      if (state != null && state.isNotEmpty) {
        _updateStatus[device.deviceId] = state;
        _updateDetail[device.deviceId] = device.updateDetail ?? '';
      }
      final hasActiveJob = _pushGeneration.containsKey(device.deviceId);
      final gen = pushGenerationOf(device.deviceId);
      // Only the per-replace push_id is an adoption ACK. playlist_id can be
      // reused, so equality there is not an edge and may describe the old job.
      final jobPushId = _jobPushId[device.deviceId];
      final devicePushId = device.pushId;
      final reportsPushId = devicePushId != null && devicePushId.isNotEmpty;
      final expectsPushId = jobPushId != null && jobPushId.isNotEmpty;
      final adopted = expectsPushId && devicePushId == jobPushId;
      if (adopted) {
        _progress.confirmJobStarted(device.deviceId, gen);
      }
      // E0004 defect 1: a status frame that reports a DIFFERENT non-empty
      // push_id belongs to the old (or another) job — it is not this job's
      // progress. Reject the whole frame rather than feeding its cache under the
      // current generation. Otherwise a lingering `push-old` frame carrying
      // `downloading:<100` would trip the machine's legacy fresh-evidence
      // fallback, release the stale guard, and let the dead job's downloading /
      // error / ready pollute the new job. The wire already carries push_id, so
      // adoption is decided here explicitly — never guessed from a download %.
      final foreignPushFrame = expectsPushId && reportsPushId && !adopted;
      // §6.4/E0002 a device that dropped offline mid-job must not keep a live
      // bar at a high percent reading as success → freeze its in-flight items
      // into an interrupted (failed) terminal state.
      if (hasActiveJob && !device.online) {
        _progress.interruptDevice(device.deviceId, gen, now: now);
      }
      // §6.4 feed the ONE shared progress machine from every device's status
      // cache. Both P2P (WallAggregator.snapshot→onWall) and broker (link
      // onWall) reach here, so progress consumption is transport-agnostic. The
      // machine enforces monotonic 0..100, reset-per-generation, stale-drop, and
      // never-100-before-`ready`. Cache is an inventory, not a push job: before
      // this controller successfully sends replace (or after CLEAR), ignore it.
      //
      // Skip ingest when the frame is foreign (E0004 defect 1) OR the device is
      // offline (E0002 risk 3): an offline snapshot still carries the
      // pre-disconnect cache inventory, and after interruptDevice() has frozen
      // the job as failed we must not re-ingest that stale inventory in the same
      // frame — a lingering `ready` there would otherwise contradict the freeze.
      if (hasActiveJob && device.online && !foreignPushFrame) {
        _progress.ingestDeviceCache(
          device.deviceId,
          device.cache,
          gen,
          now: now,
        );
      }
    }
    // §6.4/E0002 NOTE on update cadence: we notify once per wall snapshot. There
    // is no separate progress-revision throttle because the WallSnapshot object
    // itself changes every frame (state/last_seen/etc.) and must be published
    // regardless of whether progress moved — a revision gate here would coalesce
    // nothing. Update frequency is therefore bounded by the player status/wall
    // snapshot cadence, not by per-item progress deltas. The machine still
    // suppresses genuine no-op progress mutations internally (its `changed`
    // flag / revision), so no redundant progress recomputation occurs.
    notifyListeners();
  }

  void _onThumb(ThumbMeta meta, Uint8List jpeg) {
    final device = deviceById(meta.deviceId);
    if (device == null || device.current == null) return;
    if (meta.itemId.isEmpty ||
        meta.runtimeMode.isEmpty ||
        meta.modeGeneration == null ||
        meta.sessionId.isEmpty ||
        meta.seq <= 0 ||
        meta.bytes <= 0) {
      _pushLog('丢弃身份不完整的缩略图(${meta.deviceId})');
      return;
    }
    if (meta.bytes > 0 && jpeg.length != meta.bytes) {
      _pushLog('丢弃损坏缩略图(${meta.deviceId}): 字节长度不符');
      return;
    }
    if (meta.itemId.isNotEmpty && device.current?.itemId != meta.itemId) {
      _pushLog('丢弃过期缩略图(${meta.deviceId}): 播放项已变化');
      return;
    }
    if (meta.modeGeneration != null &&
        meta.modeGeneration != device.modeGeneration) {
      _pushLog('丢弃过期缩略图(${meta.deviceId}): 模式代次已变化');
      return;
    }
    if (device.runtimeMode != RuntimeMode.visual ||
        (meta.runtimeMode.isNotEmpty &&
            meta.runtimeMode != device.runtimeMode.name)) {
      _pushLog('丢弃过期缩略图(${meta.deviceId}): 当前不是图片/视频模式');
      return;
    }
    final previousSession = _thumbSession[meta.deviceId];
    final previousSeq = previousSession == meta.sessionId
        ? (_thumbSeq[meta.deviceId] ?? -1)
        : -1;
    if (meta.seq <= previousSeq) return;
    _thumbSession[meta.deviceId] = meta.sessionId;
    _thumbSeq[meta.deviceId] = meta.seq;
    _thumbItem[meta.deviceId] = meta.itemId;
    _thumbModeGeneration[meta.deviceId] = meta.modeGeneration!;
    _thumbs[meta.deviceId] = jpeg;
    notifyListeners();
  }

  void _dropThumb(String deviceId) {
    _thumbs.remove(deviceId);
    _thumbSeq.remove(deviceId);
    _thumbSession.remove(deviceId);
    _thumbItem.remove(deviceId);
    _thumbModeGeneration.remove(deviceId);
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
    // Record what the coordinator DECLARED, verbatim, before any coercion. This
    // is the value the connection log shows; keeping it lets the diagnostic
    // summary explain a declared≠operating split instead of contradicting itself.
    _declaredTopology = topo;
    final t = switch (topo) {
      'cohosted' => Topology.cohosted,
      'p2p' => Topology.p2p,
      _ => Topology.dedicated,
    };
    // A broker-declared p2p is not adoptable as an OPERATING topology: we reached
    // it over a broker (dedicated) transport and opened no direct peer links, so
    // p2p_peers stays 0. We keep operating=dedicated (honest) and surface the
    // declared value separately rather than silently overwriting the log.
    if (t != _topology && !isP2p) {
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
    _pushLog('[$deviceId] 升级状态: ${updateStateLabel(state)} '
        '($state) v$versionCode $detail');
    notifyListeners();
  }

  /// 人类可读的升级状态措辞。关键：`legacy_activation_dispatched` 是「已就绪、待重启
  /// 生效」的成功态，绝不能被误读为失败(§field-and-6037055a3d：老机型走 legacy 分支
  /// 时被控端返回该态，控制端曾错当失败)。
  static String updateStateLabel(String state) {
    switch (state) {
      case 'downloading':
        return '下载中';
      case 'installing':
        return '安装中(将重启 App)';
      case 'legacy_activation_dispatched':
        return '已就绪·待整机重启生效(非失败)';
      case 'rejected':
        return '被拒绝(护栏)';
      case 'failed':
        return '失败';
      default:
        return state;
    }
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

  // ---- §27/§28 缓存清理/清单结果接收(Broker + P2P 汇合到同一归约器) ----
  /// §27 播放端回终态 cache_cleanup_result。两传输的接收路径都调这里(无平行状态)。
  /// 解析成防御式模型后交给归约器匹配悬挂操作:落到不存在/已终态的键 → 归约器记陈旧
  /// (绝不完成更新的操作、绝不二次变更)。
  void _onCacheCleanupResult(Map<String, dynamic> payload) {
    final r = CacheCleanupResult.fromMap(payload);
    final settled = _cacheOps.onCleanupResult(r, nowMs: _nowMs());
    if (settled == null) {
      _pushLog('[${r.deviceId}] 陈旧/迟到 cache_cleanup_result(req=${r.requestId})已忽略');
      return;
    }
    _pushLog('[${r.deviceId}] cache_cleanup_result: ${settled.status.name} '
        'freed=${r.freedBytes} deleted=${r.deleted.length} '
        'skipped=${r.skipped.length} failed=${r.failed.length}');
    notifyListeners();
  }

  /// §28 播放端回终态 cache_inventory_result。
  void _onCacheInventoryResult(Map<String, dynamic> payload) {
    final r = CacheInventoryResult.fromMap(payload);
    final settled = _cacheOps.onInventoryResult(r, nowMs: _nowMs());
    if (settled == null) {
      _pushLog('[${r.deviceId}] 陈旧/迟到 cache_inventory_result(req=${r.requestId})已忽略');
      return;
    }
    _pushLog('[${r.deviceId}] cache_inventory_result: ${r.items.length} 项');
    notifyListeners();
  }

  void _onRuntimeModeResult(Map<String, dynamic> payload) {
    final result = RuntimeModeResult.fromMap(payload);
    if (result.deviceId.isEmpty) return;
    _runtimeModeResults[result.deviceId] = result;
    // runtime_mode_result is a device-confirmed fact, not an optimistic command
    // ACK. Fold it into the current immutable wall snapshot immediately so all
    // status views (including Overlay dialogs) converge without waiting for the
    // next periodic wall broadcast.
    final wall = _wall;
    if (result.ok && result.mode != null) {
      var matched = false;
      final devices = wall.devices.map((device) {
        if (device.deviceId != result.deviceId) return device;
        matched = true;
        return device.copyWith(
          runtimeMode: result.mode,
          previousActiveMode: result.previousActiveMode,
        );
      }).toList(growable: false);
      if (matched) {
        _wall = WallSnapshot(
          serverTime: wall.serverTime,
          groups: wall.groups,
          devices: devices,
        );
      }
    }
    final pending = _pendingRuntimeMode.remove(result.requestId);
    if (pending != null && !pending.isCompleted) pending.complete(result);
    _pushLog('[${result.deviceId}] runtime_mode_result '
        '${result.ok ? result.mode?.name ?? 'ok' : 'failed:${result.error}'}');
    notifyListeners();
  }

  void _onMusicPlaylistResult(Map<String, dynamic> payload) {
    final result = MusicPlaylistResult.fromMap(payload);
    if (result.deviceId.isEmpty) return;
    _musicPlaylistResults[result.deviceId] = result;
    final pendingItems = _pendingMusicItems.remove(result.requestId);
    if (result.ok && pendingItems != null) {
      _musicDrafts[result.deviceId] = List.of(pendingItems);
    }
    final pending = _pendingMusicPlaylist.remove(result.requestId);
    if (pending != null && !pending.isCompleted) pending.complete(result);
    _pushLog('[${result.deviceId}] music_playlist_result '
        '${result.ok ? 'revision=${result.revision}' : 'failed:${result.error}'}');
    notifyListeners();
  }

  void _onConfigPatchResult(Map<String, dynamic> payload) {
    final deviceId = payload['device_id']?.toString() ?? '';
    if (deviceId.isEmpty) return;
    _configPatchResults[deviceId] = Map<String, dynamic>.from(payload);
    final requestId = payload['request_id']?.toString() ?? '';
    if (requestId.isNotEmpty) {
      final pending = _pendingConfigResults.remove(requestId);
      if (pending != null && !pending.isCompleted) {
        pending.complete(Map<String, dynamic>.from(payload));
      }
    }
    final ok = payload['ok'] == true;
    final conflict = payload['conflict'] == true;
    _pushLog('[$deviceId] config_patch_result ${ok ? 'applied' : conflict ? 'conflict' : 'rejected'} '
        'rev=${payload['revision'] ?? '?'}');
    notifyListeners();
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  String _appendControllerDiagnostics(String deviceId, String playerText) {
    final b = StringBuffer(playerText);
    b.writeln();
    b.writeln();
    b.writeln('===== controller_summary =====');
    b.writeln('time_ms=${DateTime.now().millisecondsSinceEpoch}');
    b.writeln('target_device_id=$deviceId');
    // operating = how this controller is actually connected; declared = what the
    // coordinator announced in welcome. When they differ (e.g. a broker that
    // declares topology=p2p) BOTH are printed so the split is explicit, not the
    // self-contradiction E0001 flagged (log said p2p, summary said dedicated).
    b.writeln('topology_operating=$_topology topology_declared=${_declaredTopology ?? 'none'} '
        'conn=$_conn p2p_peers=$_p2pPeers auth_mode=$_authMode key_mode=$_keyMode');
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

  Set<String>? _send(String type, Map<String, dynamic> payload,
      {String? groupId, String? deviceId}) {
    // Transport links are allocated in init(). A command issued before init()
    // (or after dispose released them) cannot possibly be delivered — fail with
    // a clean StateError like the other undeliverable paths below, rather than
    // leaking a LateInitializationError from the uninitialized _broker/_p2p.
    // Critically this happens BEFORE any generation/progress mutation, so a
    // failed delivery never leaves a ghost push generation behind.
    if (!_linksReady) {
      throw StateError('链路未就绪（init 未完成或已析构），命令未投递（目标: '
          '${_to(groupId: groupId, deviceId: deviceId)}）');
    }
    final to = _to(groupId: groupId, deviceId: deviceId);
    if (isP2p) {
      final delivered = _p2p.sendTargets(type, to: to, payload: payload);
      if (delivered.isEmpty) {
        throw StateError('没有可投递的已连接设备（目标: $to）');
      }
      return delivered;
    }
    if (!_broker.send(type, to: to, payload: payload)) {
      throw StateError('broker 未连接，命令未投递（目标: $to）');
    }
    // Broker acceptance cannot identify downstream recipients.
    return null;
  }

  // ---- 出站命令(供 UI 调用) ----
  /// 预缓存下发(§21)。[deviceId] 非空 → 只发这一台(单播,§9.4b 单台推送)。
  void cachePrefetch(List<MediaItem> items, {String? groupId, String? deviceId}) {
    _send('cache_prefetch', Commands.cachePrefetch(items),
        groupId: groupId, deviceId: deviceId);
  }

  /// 某台设备的最近状态(能力/在线判定用)。未知 → null。
  DeviceStatus? statusFor(String deviceId) {
    for (final d in _wall.devices) {
      if (d.deviceId == deviceId) return d;
    }
    return null;
  }

  String _newCacheRequestId() =>
      '$controllerId-cc-${++_nextCacheReq}-${DateTime.now().microsecondsSinceEpoch}';

  /// §27 单台缓存清理。能力真值前置:目标未广告 cache_cleanup_v1 → 直接终态
  /// unsupported,从不下发(绝不静默超时冒充支持)。离线 → 直接终态 offline。否则登记
  /// pending 并下发 controller→player 请求(单播)。返回归约器登记的操作供 UI 追踪。
  ///
  /// 删除权威在播放端:此处只发 item_ids/范围,绝不发路径。应用后清理必须带
  /// [expectedPushId](与当前采纳代次绑定,fail-closed)。
  CacheOperation cacheCleanup({
    required String deviceId,
    String mode = 'unreferenced',
    List<String>? itemIds,
    bool dryRun = false,
    String? expectedPushId,
    String reason = 'manual',
  }) {
    final st = statusFor(deviceId);
    final supported = st?.supportsCacheCleanup ?? false;
    final online = st?.online ?? false;
    final reqId = _newCacheRequestId();
    final operationFingerprint = cacheCleanupFingerprint(
      target: 'device:$deviceId', mode: mode, dryRun: dryRun,
      itemIds: itemIds, expectedPushId: expectedPushId, reason: reason);
    final op = _cacheOps.beginCleanup(
      requestId: reqId, deviceId: deviceId, dryRun: dryRun,
      operationFingerprint: operationFingerprint, nowMs: _nowMs(),
      supported: supported, online: online);
    if (op.isPending && !debugHoldOutboundCache) {
      _dispatchCache(deviceId, reqId, op, () => _send(
          'cache_cleanup',
          // deviceId MUST also go into the payload (via Commands._target), not
          // only the envelope `to:`. Broker/player derive operation_fingerprint
          // target from payload device_id/group_id; if omitted they both use
          // "all" and the controller's stored "device:<id>" fingerprint rejects
          // every result as operation_fingerprint_mismatch.
          Commands.cacheCleanup(
            requestId: reqId, mode: mode, itemIds: itemIds, dryRun: dryRun,
            expectedPushId: expectedPushId, reason: reason,
            deviceId: deviceId),
          deviceId: deviceId));
    } else if (!op.isPending) {
      _pushLog('[$deviceId] cache_cleanup 未下发(${op.status.name}): ${op.detail}');
    }
    notifyListeners();
    return op;
  }

  /// §28 单台缓存清单(按需)。能力/在线前置同 [cacheCleanup]。
  CacheOperation cacheInventory({required String deviceId}) {
    final st = statusFor(deviceId);
    final supported = st?.supportsCacheInventory ?? false;
    final online = st?.online ?? false;
    final reqId = _newCacheRequestId();
    final op = _cacheOps.beginInventory(
      requestId: reqId, deviceId: deviceId, nowMs: _nowMs(),
      supported: supported, online: online);
    if (op.isPending && !debugHoldOutboundCache) {
      _dispatchCache(deviceId, reqId, op, () => _send(
          'cache_inventory',
          // Same payload-target rule as cacheCleanup: include device_id so
          // routing identity and any future fingerprint/gate stay consistent.
          Commands.cacheInventory(requestId: reqId, deviceId: deviceId),
          deviceId: deviceId));
    } else if (!op.isPending) {
      _pushLog('[$deviceId] cache_inventory 未下发(${op.status.name}): ${op.detail}');
    }
    notifyListeners();
    return op;
  }

  /// 重试:用新 request_id 重开某设备的清理(旧终态保留)。能力/在线重新判定。
  CacheOperation cacheCleanupRetry({
    required String deviceId,
    String mode = 'unreferenced',
    List<String>? itemIds,
    bool dryRun = false,
    String? expectedPushId,
    String reason = 'manual',
  }) =>
      cacheCleanup(
        deviceId: deviceId, mode: mode, itemIds: itemIds, dryRun: dryRun,
        expectedPushId: expectedPushId, reason: reason);

  /// 收割超时(UI/状态刷新时调)。任何悬挂操作到期转 timeout 终态并通知。
  void reapCacheTimeouts() {
    final expired = _cacheOps.expire(_nowMs());
    if (expired.isNotEmpty) {
      for (final o in expired) {
        _pushLog('[${o.deviceId}] cache ${o.kind} 超时(req=${o.requestId})');
      }
      notifyListeners();
    }
  }

  /// 关闭详情面板时清理某设备的已终态记录(悬挂保留)。
  void clearCacheResultsFor(String deviceId) {
    _cacheOps.clearSettledFor(deviceId);
    notifyListeners();
  }

  /// 下发缓存请求;投递失败不留幽灵 pending —— 立刻收割成 timeout 终态(投递失败与
  /// 「发出去没回」同样对待,不伪造成功)。
  void _dispatchCache(
      String deviceId, String reqId, CacheOperation op, void Function() send) {
    try {
      send();
    } catch (e) {
      _cacheOps.failUndelivered(reqId, deviceId, _nowMs(), '命令未投递: $e');
      _pushLog('[$deviceId] cache ${op.kind} 未投递(req=$reqId): $e');
    }
  }

  Future<Map<String, RuntimeModeResult>> setDevicesRuntimeMode(
      Iterable<String> deviceIds, RuntimeMode mode) async {
    final out = <String, RuntimeModeResult>{};
    await Future.wait(deviceIds.toSet().map((deviceId) async {
      try {
        out[deviceId] = await setDeviceRuntimeMode(deviceId, mode);
      } catch (e) {
        out[deviceId] = RuntimeModeResult(
          requestId: '', deviceId: deviceId, ok: false, error: e.toString(),
        );
      }
    }));
    return out;
  }

  Future<Map<String, RuntimeModeResult>> restoreDevicesRuntimeMode(
      Iterable<String> deviceIds) async {
    final out = <String, RuntimeModeResult>{};
    await Future.wait(deviceIds.toSet().map((deviceId) async {
      try {
        out[deviceId] = await restoreDeviceRuntimeMode(deviceId);
      } catch (e) {
        out[deviceId] = RuntimeModeResult(
          requestId: '', deviceId: deviceId, ok: false, error: e.toString(),
        );
      }
    }));
    return out;
  }

  Future<RuntimeModeResult> setDeviceRuntimeMode(
      String deviceId, RuntimeMode mode) {
    final device = deviceById(deviceId);
    if (device == null || !device.online) {
      return Future.error(StateError('设备离线'));
    }
    if (!device.supportsRuntimeModes) {
      return Future.error(UnsupportedError('设备不支持运行模式，请先升级 Player'));
    }
    final requestId = 'mode-${++_nextRuntimeModeRequest}-${_nowMs()}';
    final completer = Completer<RuntimeModeResult>();
    _pendingRuntimeMode[requestId] = completer;
    try {
      _send('set_runtime_mode', Commands.setRuntimeMode(
        requestId: requestId, deviceId: deviceId, mode: mode,
      ), deviceId: deviceId);
    } catch (e) {
      _pendingRuntimeMode.remove(requestId);
      completer.completeError(e);
      return completer.future;
    }
    Timer(const Duration(seconds: 10), () {
      final pending = _pendingRuntimeMode.remove(requestId);
      if (pending != null && !pending.isCompleted) {
        pending.complete(RuntimeModeResult(
          requestId: requestId, deviceId: deviceId, ok: false,
          error: 'timeout',
        ));
      }
    });
    return completer.future;
  }

  Future<RuntimeModeResult> restoreDeviceRuntimeMode(String deviceId) {
    final device = deviceById(deviceId);
    if (device == null || !device.online) {
      return Future.error(StateError('设备离线'));
    }
    if (!device.supportsRuntimeModes) {
      return Future.error(UnsupportedError('设备不支持运行模式，请先升级 Player'));
    }
    final requestId = 'restore-${++_nextRuntimeModeRequest}-${_nowMs()}';
    final completer = Completer<RuntimeModeResult>();
    _pendingRuntimeMode[requestId] = completer;
    try {
      _send('restore_runtime_mode', Commands.restoreRuntimeMode(
        requestId: requestId, deviceId: deviceId,
      ), deviceId: deviceId);
    } catch (e) {
      _pendingRuntimeMode.remove(requestId);
      completer.completeError(e);
      return completer.future;
    }
    Timer(const Duration(seconds: 10), () {
      final pending = _pendingRuntimeMode.remove(requestId);
      if (pending != null && !pending.isCompleted) {
        pending.complete(RuntimeModeResult(
          requestId: requestId, deviceId: deviceId, ok: false,
          error: 'timeout',
        ));
      }
    });
    return completer.future;
  }

  Future<MusicPlaylistResult> sendDeviceMusicPlaylist({
    required String deviceId,
    required List<MediaItem> items,
    String? playlistId,
    int? revision,
  }) {
    final device = deviceById(deviceId);
    if (device == null || !device.online) {
      return Future.error(StateError('设备离线'));
    }
    if (!device.supportsMusicShuffle) {
      return Future.error(UnsupportedError('设备不支持音乐终端，请先升级 Player'));
    }
    final requestId = 'music-${++_nextMusicPlaylistRequest}-${_nowMs()}';
    final nextRevision = revision ?? nextMusicPlaylistRevision(
      device.musicPlaylistRevision,
      _musicPlaylistResults[deviceId]?.revision,
    );
    final completer = Completer<MusicPlaylistResult>();
    _pendingMusicPlaylist[requestId] = completer;
    _pendingMusicItems[requestId] = List.of(items);
    try {
      _send('music_playlist', Commands.musicPlaylist(
        requestId: requestId,
        deviceId: deviceId,
        playlistId: playlistId ?? 'music-$deviceId',
        revision: nextRevision,
        items: items,
      ), deviceId: deviceId);
    } catch (e) {
      _pendingMusicPlaylist.remove(requestId);
      _pendingMusicItems.remove(requestId);
      completer.completeError(e);
      return completer.future;
    }
    Timer(const Duration(seconds: 15), () {
      final pending = _pendingMusicPlaylist.remove(requestId);
      _pendingMusicItems.remove(requestId);
      if (pending != null && !pending.isCompleted) {
        pending.complete(MusicPlaylistResult(
          requestId: requestId, deviceId: deviceId, ok: false,
          error: 'timeout',
        ));
      }
    });
    return completer.future;
  }

  /// 下发 playlist(§6.3)。[deviceId] 非空 → 单播给这一台(§9.4b 单台推送);
  /// player 侧 hPlaylist 不做 targetsMe 过滤,靠信封 `to: player:<id>` 精确投递。
  void sendPlaylist({
    required String playlistId,
    required String groupId,
    required bool sync,
    required LoopMode loopMode,
    required List<MediaItem> items,
    String mode = 'append',
    String? deviceId,
  }) {
    String? pushId;
    final affected = deviceId != null && deviceId.isNotEmpty
        ? <String>[deviceId]
        : _wall.devices
            .where((d) => d.groupId == groupId)
            .map((d) => d.deviceId)
            .toList();
    // Generate the wire identity now, but do not mutate local progress until
    // _send confirms that the command was actually delivered.
    if (mode == 'replace' && items.isNotEmpty) {
      pushId = '${controllerId}-${++_nextPushId}-${DateTime.now().microsecondsSinceEpoch}';
    }
    final deliveredTargets = _send(
      'playlist',
      Commands.playlist(
        playlistId: playlistId,
        groupId: groupId,
        sync: sync,
        loopMode: loopMode,
        items: items,
        mode: mode,
        pushId: pushId,
      ),
      groupId: groupId,
      deviceId: deviceId,
    );
    // P2P commits only exact successful recipients. Broker acceptance has no
    // per-device result, so it uses the addressed target set.
    final committed = deliveredTargets ?? affected.toSet();
    if (mode == 'replace' && isP2p) {
      _p2p.cancelSyncForTargets(committed);
    }
    if (mode == 'replace' && items.isNotEmpty) {
      _beginPushJob(
        committed,
        items.map((it) => it.itemId),
        pushId: pushId!,
      );
    } else if (mode == 'replace' && items.isEmpty) {
      // CLEAR ends the job identity too. Later cache snapshots are inventory,
      // not a new task, and therefore cannot resurrect the cleared progress.
      _clearPushJob(committed);
    }
  }

  String? _pushIdForDeviceIds(Iterable<String> deviceIds) {
    final ids = deviceIds.map((id) => _jobPushId[id]).whereType<String>().toSet();
    return ids.length == 1 ? ids.single : null;
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
    final targets = _wall.devices
        .where((d) => d.groupId == groupId)
        .map((d) => d.deviceId);
    final pushId = _pushIdForDeviceIds(targets);
    if (pushId == null) throw StateError('当前播放任务缺少唯一 push_id');
    if (isP2p) {
      _p2p.startSync(
        playlistId: playlistId,
        groupId: groupId,
        startIndex: startIndex,
        seekMs: seekMs,
        pushId: pushId,
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
        pushId: pushId,
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

  /// Applies only low-risk fields. The player returns `config_patch_result` with
  /// per-field outcomes; transport and key changes use dedicated commands.
  String configureDevice({
    required String deviceId,
    String? deviceName,
    String? groupId,
    int? volume,
    bool? muted,
    int? baseRevision,
  }) {
    final requestId = 'cfg-${DateTime.now().millisecondsSinceEpoch}-${++_nextConfigRequest}';
    _send('configure_device', Commands.configPatch(
      deviceId: deviceId,
      requestId: requestId,
      baseRevision: baseRevision,
      patch: {
        if (deviceName != null) 'device_name': deviceName,
        if (groupId != null) 'group_id': groupId,
        if (volume != null) 'volume': volume,
        if (muted != null) 'muted': muted,
      },
    ));
    return requestId;
  }

  String configureTransport({
    required String deviceId,
    required String brokerHost,
    int? brokerPort,
    bool? useWss,
  }) {
    final requestId = 'transport-${DateTime.now().millisecondsSinceEpoch}-${++_nextConfigRequest}';
    _send('transport_configure', Commands.transportConfigure(
      deviceId: deviceId, brokerHost: brokerHost, brokerPort: brokerPort,
      useWss: useWss,
      transportMode: brokerHost.trim().isEmpty ? 'auto' : 'broker',
      requestId: requestId,
    ));
    return requestId;
  }

  Future<void> _clearTransportAndWait(String deviceId) async {
    final previousRevision = deviceById(deviceId)?.configSnapshot?.revision ?? -1;
    final requestId =
        'transport-${DateTime.now().millisecondsSinceEpoch}-${++_nextConfigRequest}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingConfigResults[requestId] = completer;
    try {
      _send('transport_configure', Commands.transportConfigure(
        deviceId: deviceId,
        brokerHost: '',
        transportMode: 'p2p',
        requestId: requestId,
      ));
      final result =
          await completer.future.timeout(const Duration(seconds: 8));
      if (result['ok'] != true) {
        throw StateError('播放端拒绝清除 Broker 配置');
      }
      final applied =
          (result['applied'] as Map?)?.cast<String, dynamic>() ?? const {};
      final appliedRevision = result['revision'] is num
          ? (result['revision'] as num).toInt()
          : -1;
      if ((applied['broker_host']?.toString() ?? '').trim().isNotEmpty ||
          applied['transport_mode'] != 'p2p' ||
          appliedRevision <= previousRevision) {
        throw StateError('播放端未确认持久化 P2P 传输模式');
      }
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(deadline)) {
        final snapshot = deviceById(deviceId)?.configSnapshot;
        if (snapshot != null &&
            snapshot.revision == appliedRevision &&
            (snapshot.brokerHost ?? '').trim().isEmpty &&
            snapshot.transportMode == 'p2p') {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      throw StateError('播放端未在状态中回读已持久化的 P2P 配置');
    } finally {
      _pendingConfigResults.remove(requestId);
    }
  }

  /// Clear the persisted Broker override while the current Broker link is still
  /// alive, then move this controller to discovery/P2P. A Player sends its durable
  /// readback before rebuilding transport, so a successful result cannot be an
  /// optimistic UI-only acknowledgement.
  Future<Map<String, String>> restoreDevicesToP2p(
      Iterable<String> deviceIds) async {
    final ids = deviceIds.toSet();
    if (ids.isEmpty) throw ArgumentError('至少选择一台播放端');
    if (ids.length != 1) {
      throw ArgumentError('P2P 还原必须逐台执行，避免部分设备切换失败后失联');
    }
    final results = <String, String>{};
    await Future.wait(ids.map((id) async {
      try {
        await _clearTransportAndWait(id);
        results[id] = '已清除 Broker 配置';
      } catch (e) {
        results[id] = '失败：$e';
      }
    }));
    final cleared = results.entries
        .where((entry) => entry.value == '已清除 Broker 配置')
        .map((entry) => entry.key)
        .toSet();
    if (cleared.isEmpty) return results;

    await updateSettings(connectionMode: ConnectionMode.autoP2p);
    final directDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(directDeadline) &&
        !cleared.every(_p2p.connectedIds.contains)) {
      _discovery.discover();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    for (final id in cleared) {
      results[id] = _p2p.connectedIds.contains(id)
          ? 'P2P 已连接'
          : '失败：播放端已清除 Broker，但 20 秒内未建立 P2P 直连';
    }
    return results;
  }

  Future<void> _configureTransportAndWait(
      String deviceId, BrokerTarget target) async {
    final previousRevision = deviceById(deviceId)?.configSnapshot?.revision ?? -1;
    final requestId =
        'transport-${DateTime.now().millisecondsSinceEpoch}-${++_nextConfigRequest}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingConfigResults[requestId] = completer;
    try {
      _send('transport_configure', Commands.transportConfigure(
        deviceId: deviceId,
        brokerHost: target.host,
        transportMode: 'broker',
        brokerPort: target.port,
        useWss: target.secure,
        requestId: requestId,
        rollbackTimeoutMs: 30000,
      ));
      final result =
          await completer.future.timeout(const Duration(seconds: 8));
      if (result['ok'] != true) {
        throw StateError(result['conflict'] == true
            ? '配置版本冲突'
            : '播放端拒绝 Broker 配置');
      }
      final applied =
          (result['applied'] as Map?)?.cast<String, dynamic>() ?? const {};
      final appliedHost =
          normalizeRemoteHost(applied['broker_host']?.toString() ?? '');
      final appliedPort = applied['broker_port'] as int?;
      final appliedSecure = applied['use_wss'] as bool?;
      final appliedMode = applied['transport_mode']?.toString();
      final appliedRevision = result['revision'] is int
          ? result['revision'] as int
          : -1;
      if (appliedHost != normalizeRemoteHost(target.host) ||
          appliedPort != target.port ||
          appliedSecure != target.secure ||
          appliedMode != 'broker' ||
          appliedRevision <= previousRevision) {
        throw StateError('播放端回读值与目标 Broker 不一致');
      }
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(deadline)) {
        final snapshot = deviceById(deviceId)?.configSnapshot;
        if (snapshot != null &&
            snapshot.revision == appliedRevision &&
            snapshot.transportMode == 'broker' &&
            normalizeRemoteHost(snapshot.brokerHost ?? '') ==
                normalizeRemoteHost(target.host) &&
            snapshot.brokerPort == target.port &&
            snapshot.useWss == target.secure) {
          _brokerMigrationRevision[deviceId] = appliedRevision;
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw StateError('未在旧链路收到精确 revision 的 Broker 状态快照');
    } finally {
      _pendingConfigResults.remove(requestId);
    }
  }

  Future<void> _probeBroker(BrokerTarget target) async {
    final socket = await WebSocket.connect(target.endpoint)
        .timeout(const Duration(seconds: 5));
    await socket.close(WebSocketStatus.normalClosure, 'preflight');
  }

  bool _deviceConnectedToBroker(String deviceId, BrokerTarget target) {
    final device = deviceById(deviceId);
    final snapshot = device?.configSnapshot;
    final expectedRevision = _brokerMigrationRevision[deviceId];
    if (device == null || !device.online || snapshot == null ||
        expectedRevision == null) return false;
    return normalizeRemoteHost(snapshot.brokerHost ?? '') ==
            normalizeRemoteHost(target.host) &&
        snapshot.brokerPort == target.port &&
        snapshot.useWss == target.secure &&
        snapshot.transportMode == 'broker' &&
        snapshot.revision == expectedRevision;
  }

  /// Transactionally move selected Players from live P2P links to one Broker.
  /// Partial failure leaves this controller on P2P; retry resends only failed
  /// boxes. The controller switches after every box acknowledges persistence and
  /// success requires Broker online plus exact transport-config readback.
  Future<BrokerMigrationBatch> migrateDevicesToBroker({
    required Iterable<String> deviceIds,
    required String host,
    required int port,
    required bool secure,
    bool retryCurrent = false,
  }) async {
    final normalized = normalizeRemoteHost(host);
    if (normalized.isEmpty || normalized == '0.0.0.0' || normalized == '::') {
      throw const FormatException('Broker 地址无效');
    }
    if (port < 1 || port > 65535) {
      throw const FormatException('Broker 端口必须在 1–65535');
    }
    final target = BrokerTarget(host: normalized, port: port, secure: secure);
    final existing = _bulkBrokerMigration;
    final batch = retryCurrent &&
            existing != null &&
            existing.target.endpoint == target.endpoint
        ? existing
        : BrokerMigrationBatch(
            target: target,
            deviceIds: deviceIds.toSet(),
          );
    _bulkBrokerMigration = batch;
    notifyListeners();
    final runner = BrokerMigrationRunner(
      probe: _probeBroker,
      apply: _configureTransportAndWait,
      switchController: (next) async {
        // Drop P2P snapshots before changing topology. Otherwise an endpoint
        // readback received over the old socket could be mistaken for proof that
        // the Player registered on the target Broker.
        final migratingIds = batch.devices.keys.toSet();
        _wall = WallSnapshot(
          serverTime: _wall.serverTime,
          groups: _wall.groups,
          devices: _wall.devices
              .where((device) => !migratingIds.contains(device.deviceId))
              .toList(growable: false),
        );
        if (!_disposed) notifyListeners();
        await updateSettings(
          connectionMode: ConnectionMode.broker,
          host: next.host,
          port: next.port,
          secure: next.secure,
        );
      },
      isConnected: _deviceConnectedToBroker,
    );
    return runner.run(
      batch: batch,
      onChanged: (_) {
        if (!_disposed) notifyListeners();
      },
    );
  }

  /// Recovery path for the initial P2P → Broker rollout. Players that did not
  /// authenticate roll back themselves to P2P after 30s; this controller follows
  /// them, waits for discovery/reconnect, retries only failed IDs, then the normal
  /// runner switches back to Broker after all acknowledgements.
  Future<BrokerMigrationBatch> recoverP2pAndRetryBrokerMigration() async {
    final batch = _bulkBrokerMigration;
    if (batch == null) throw StateError('没有可恢复的批量迁移');
    await updateSettings(connectionMode: ConnectionMode.autoP2p);
    batch.controllerSwitched = false;
    notifyListeners();
    await Future<void>.delayed(const Duration(seconds: 8));
    return migrateDevicesToBroker(
      deviceIds: batch.devices.keys,
      host: batch.target.host,
      port: batch.target.port,
      secure: batch.target.secure,
      retryCurrent: true,
    );
  }

  String rotateDeviceKey({required String deviceId, required String psk}) {
    final requestId = 'key-${DateTime.now().millisecondsSinceEpoch}-${++_nextConfigRequest}';
    _send('rotate_device_key', Commands.rotateDeviceKey(
      deviceId: deviceId, psk: psk, requestId: requestId,
    ));
    return requestId;
  }

  /// broker 模式优先上传到 broker 媒体库;P2P/无 broker 时复用控制端本机临时 HTTP 服务。
  Future<({String url, String sha256, int versionCode, String? versionName})>
      uploadApkForUpdate({
    required File apk,
    void Function(int sent, int total)? onProgress,
  }) async {
    final archive =
        ZipDecoder().decodeBytes(await apk.readAsBytes(), verify: true);
    final manifestBytes = archive.findFile('AndroidManifest.xml')?.readBytes();
    if (manifestBytes == null) {
      throw const FormatException('APK 缺少 AndroidManifest.xml');
    }
    final manifest = validatePlayerApkManifest(parseApkManifest(manifestBytes));
    if (!isP2p && brokerHost.isNotEmpty) {
      final item = await MediaUpload.uploadToBroker(
        file: apk,
        brokerHost: brokerHost,
        type: 'app',
        name: apk.uri.pathSegments.last,
        uploadToken: mediaUploadToken,
        onProgress: onProgress,
      );
      return (
        url: item.url,
        sha256: item.sha256 ?? '',
        versionCode: manifest.versionCode,
        versionName: manifest.versionName,
      );
    }

    final item = await uploadLocalMedia(
      file: apk,
      type: 'app',
      name: apk.uri.pathSegments.last,
      onProgress: onProgress,
    );
    return (
      url: item.url,
      sha256: item.sha256 ?? '',
      versionCode: manifest.versionCode,
      versionName: manifest.versionName,
    );
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
    final targetIds = deviceId != null && deviceId.isNotEmpty
        ? <String>[deviceId]
        : _wall.devices.where((d) => d.groupId == groupId).map((d) => d.deviceId);
    final pushId = _pushIdForDeviceIds(targetIds);
    if (pushId == null) throw StateError('当前播放任务缺少唯一 push_id');
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
        pushId: pushId,
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
          pushId: pushId,
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
    // Mark disposed FIRST so an init() still parked at an await bails on resume
    // (see init()): no post-dispose allocation/start/notify. _teardownLinks()
    // releases whatever init() already allocated, exactly once — a no-op on the
    // dispose-before-init / no-init path where the `late final` links are unset.
    _disposed = true;
    _teardownLinks();
    _localMedia.stop();
    super.dispose();
  }
}
