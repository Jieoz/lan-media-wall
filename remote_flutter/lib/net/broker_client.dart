import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

import '../protocol/auth_mode.dart';
import '../protocol/envelope.dart';
import '../protocol/messages.dart';
import '../protocol/remote_endpoint.dart';
import '../protocol/thumb_pairing.dart';

/// 连接态。
enum ConnState { disconnected, connecting, connected }

/// broker 长连接客户端：
///  - WS(S) 连接 + 指数退避重连(1s,2s,4s … 上限 30s，对齐 §1)。
///  - 连接成功后发 `hello`(controller)，等 broker 回 `welcome`(带设备墙快照)。
///  - 入站分发：welcome / wall(快照) / thumb_meta(+紧跟的二进制帧配对) / ack / error。
///  - 出站统一用 [EnvelopeCodec] 签名(§3)；入站统一验签后再分发。
class BrokerClient {
  BrokerClient({required this.codec, required this.controllerId});

  /// 与全系统一致的信封编解码器(签名/验签)。
  EnvelopeCodec codec;

  /// 本遥控端 id（用于 hello）。
  String controllerId;

  /// 收到设备墙快照(welcome.snapshot 或 wall).
  void Function(WallSnapshot snapshot)? onWall;

  /// 收到某台设备的缩略图 JPEG(thumb_meta + 二进制帧配对完成后)。
  void Function(String deviceId, Uint8List jpeg)? onThumb;

  /// 收到被控端回传的诊断快照文本。
  void Function(String deviceId, String detail)? onDiagnostic;

  /// 收到被控端更新状态。
  void Function(String deviceId, String state, String detail, int versionCode)? onUpdateStatus;

  /// 收到被控端回传的日志文件内容。
  void Function(String deviceId, String text, String fileName)? onLogDownload;

  /// §27 收到播放端回传的 cache_cleanup_result 终态帧(raw payload; WallState 解析
  /// 成 [CacheCleanupResult] 并喂给一体化归约器 —— 与 P2P 路径汇合到同一 reducer)。
  void Function(Map<String, dynamic> payload)? onCacheCleanupResult;

  /// §28 收到播放端回传的 cache_inventory_result 终态帧。
  void Function(Map<String, dynamic> payload)? onCacheInventoryResult;

  /// §19 player confirmation for safe config patches and high-risk config paths.
  void Function(Map<String, dynamic> payload)? onConfigPatchResult;

  void Function(Map<String, dynamic> payload)? onRuntimeModeResult;
  void Function(Map<String, dynamic> payload)? onMusicPlaylistResult;

  /// 连接态变化。
  void Function(ConnState state)? onState;

  /// 协调端在 welcome 中声明的 auth_mode（§13）变化（端侧据此自适应签名/验签）。
  void Function(AuthMode mode)? onAuthMode;

  /// 协调端在 welcome 中声明的 key_mode（§17.3）变化（端侧据此用 PSK / device_key 签验）。
  void Function(KeyMode mode)? onKeyMode;

  /// 协调端在 welcome 中声明的 topology（§14）字符串变化（仅诊断展示）。
  void Function(String topology)? onTopology;

  /// 诊断日志。
  void Function(String line)? onLog;

  String _host = '';
  int _port = 8770;
  bool _secure = false;

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _wantConnected = false;
  int _backoffMs = 1000;
  ConnState _state = ConnState.disconnected;

  /// 缩略图两帧配对(§6.4：thumb_meta 之后紧跟一个二进制帧)。与 p2p 路径复用
  /// 同一套 [ThumbPairing]，避免两端解析/存储逻辑分叉。
  late final ThumbPairing _thumbs = ThumbPairing(
    onThumb: (id, jpeg) => onThumb?.call(id, jpeg),
    onLog: _log,
  );

  ConnState get state => _state;

  /// 开始连接(并允许之后自动重连)。
  void connect({required String host, required int port, bool secure = false}) {
    _host = normalizeRemoteHost(host);
    _port = port;
    _secure = secure;
    _wantConnected = true;
    _backoffMs = 1000;
    _reconnectTimer?.cancel();
    _open();
  }

  /// 主动断开并停止重连。
  void disconnect() {
    _wantConnected = false;
    _reconnectTimer?.cancel();
    _closeChannel();
    _setState(ConnState.disconnected);
  }

  void dispose() {
    _disposed = true;
    _wantConnected = false;
    _reconnectTimer?.cancel();
    _closeChannel();
  }

  void _open() {
    if (_disposed || !_wantConnected) return;
    if (_host.isEmpty) {
      _log('broker host 为空，跳过连接');
      return;
    }
    _closeChannel();
    _setState(ConnState.connecting);
    final scheme = _secure ? 'wss' : 'ws';
    final uri = Uri.parse('$scheme://$_host:$_port');
    final IOWebSocketChannel ch;
    try {
      ch = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 20),
      );
    } catch (e) {
      _log('连接异常: $e');
      _scheduleReconnect();
      return;
    }
    _channel = ch;
    _sub = ch.stream.listen(
      _onData,
      onError: (Object e) => _onError(e),
      onDone: _onDone,
      cancelOnError: false,
    );
    ch.ready.then((_) {
      if (_channel != ch) return; // 已被新的连接取代
      _setState(ConnState.connected);
      _backoffMs = 1000;
      _sendHello();
    }).catchError((Object e) {
      if (_channel != ch) return;
      _log('握手失败: $e');
      _scheduleReconnect();
    });
  }

  void _sendHello() {
    send(
      'hello',
      to: 'broker',
      payload: Commands.hello(controllerId: controllerId),
    );
  }

  /// §13/§17.3：据 welcome.payload 校正本端 auth_mode / key_mode（协调端为权威）。
  /// key_mode 字段缺失 → 按 `global` 处理（向后兼容）。
  void _applyWelcomeModes(Map<String, dynamic> payload) {
    if (payload.containsKey('auth_mode')) {
      final mode = AuthMode.parse(payload['auth_mode']);
      codec.authMode = mode;
      onAuthMode?.call(mode);
      _log('auth_mode=${mode.wire}');
    }
    // 缺省/缺失 → global（§17.3）。welcome 一旦到达即按其声明对齐。
    final km = KeyMode.parse(payload['key_mode']);
    if (codec.keyMode != km) {
      codec.keyMode = km;
      onKeyMode?.call(km);
      _log('key_mode=${km.wire}');
    }
  }

  /// 构造、签名并发送一个出站信封。未连接时丢弃并记录。
  bool send(
    String type, {
    required String to,
    Map<String, dynamic> payload = const {},
  }) {
    final ch = _channel;
    if (ch == null || _state != ConnState.connected) {
      _log('send($type) 丢弃：未连接');
      return false;
    }
    final env = codec.build(type: type, to: to, payload: payload);
    ch.sink.add(env.toJson());
    return true;
  }

  void _onData(dynamic data) {
    if (data is String) {
      _onText(data);
    } else if (data is List<int>) {
      _onBinary(Uint8List.fromList(data));
    } else {
      _log('未知帧类型: ${data.runtimeType}');
    }
  }

  void _onText(String text) {
    final Envelope env;
    try {
      env = Envelope.fromJson(text);
    } catch (e) {
      _log('JSON 解析失败: $e');
      return;
    }
    // §13/§17.3 引导：welcome 是协调端对本端策略的权威声明。它本身由 broker 用其
    // auth_mode/key_mode 签名，而本端引导期可能口径不同（如默认 global），导致先验签必失败。
    // 因此对 welcome 先按其 payload 声明校正 authMode/keyMode，再用校正后的口径验签。
    if (env.type == 'welcome') {
      _applyWelcomeModes(env.payload);
    }
    final vr = codec.verify(env);
    if (vr != VerifyError.ok) {
      _log('入站验签失败(${env.type}): $vr');
      return;
    }
    switch (env.type) {
      case 'welcome':
        if (env.payload.containsKey('topology')) {
          final topo = env.payload['topology'].toString();
          onTopology?.call(topo);
          _log('topology=$topo');
        }
        final snap = (env.payload['snapshot'] as Map?)?.cast<String, dynamic>();
        if (snap != null) onWall?.call(WallSnapshot.fromMap(snap));
        _log('已接入(welcome)');
        break;
      case 'wall':
        onWall?.call(WallSnapshot.fromMap(env.payload));
        break;
      case 'thumb_meta':
        _thumbs.onMeta(env.payload);
        break;
      case 'diagnostic_status':
        onDiagnostic?.call(
          env.payload['device_id']?.toString() ?? '',
          env.payload['detail']?.toString() ?? '',
        );
        break;
      case 'update_status':
        onUpdateStatus?.call(
          env.payload['device_id']?.toString() ?? '',
          env.payload['state']?.toString() ?? '',
          env.payload['detail']?.toString() ?? '',
          (env.payload['version_code'] as num?)?.toInt() ?? 0,
        );
        break;
      case 'download_logs_result':
        onLogDownload?.call(
          env.payload['device_id']?.toString() ?? '',
          env.payload['text']?.toString() ?? '',
          env.payload['file_name']?.toString() ?? 'player.log',
        );
        break;
      case 'cache_cleanup_result':
        // §27: broker 已做 player→controller 方向/角色校验; 这里只解析并汇入
        // WallState 的一体化归约器(与 P2P 路径完全同一 reducer)。
        onCacheCleanupResult?.call(env.payload);
        break;
      case 'cache_inventory_result':
        onCacheInventoryResult?.call(env.payload);
        break;
      case 'config_patch_result':
        onConfigPatchResult?.call(env.payload);
        break;
      case 'runtime_mode_result':
        onRuntimeModeResult?.call(env.payload);
        break;
      case 'music_playlist_result':
        onMusicPlaylistResult?.call(env.payload);
        break;
      case 'ack':
        _log('ack: ${env.payload}');
        break;
      case 'error':
        _log('error: ${env.payload}');
        break;
      case 'status':
      case 'time_sync':
      case 'ready':
        // On the broker (dedicated) path these are consumed SERVER-SIDE: the
        // broker folds status/ready into the aggregate `wall` frame and answers
        // time_sync itself, so a controller here should never see them raw.
        // Seeing one means the peer is behaving p2p over a broker transport —
        // logged explicitly (not silently dropped) so `online=null` on the wall
        // is attributable to "no wall frame arrived", per E0001. The p2p path
        // (P2pCoordinator) is where these are actually merged into device state.
        _log('入站 ${env.type} 落到 broker 路径被丢弃(应由 broker 聚合为 wall / 由 p2p 协调端消费)'
            ' — device=${env.payload['device_id'] ?? '?'}');
        break;
      default:
        _log('忽略入站类型: ${env.type}');
    }
  }

  void _onBinary(Uint8List bytes) => _thumbs.onBinary(bytes);

  void _onError(Object e) {
    _log('连接错误: $e');
    _scheduleReconnect();
  }

  void _onDone() {
    _log('连接关闭(code=${_channel?.closeCode})');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _closeChannel();
    _setState(ConnState.disconnected);
    if (!_wantConnected || _disposed) return;
    final delay = _backoffMs;
    _log('${delay}ms 后重连');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delay), _open);
    _backoffMs = (_backoffMs * 2).clamp(1000, 30000);
  }

  void _closeChannel() {
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _thumbs.reset();
  }

  void _setState(ConnState s) {
    if (_state == s) return;
    _state = s;
    onState?.call(s);
  }

  void _log(String line) => onLog?.call(line);
}
