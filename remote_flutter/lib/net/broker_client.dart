import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

import '../protocol/envelope.dart';
import '../protocol/messages.dart';

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

  /// 收到设备墙快照(welcome.snapshot 或 wall)。
  void Function(WallSnapshot snapshot)? onWall;

  /// 收到某台设备的缩略图 JPEG(thumb_meta + 二进制帧配对完成后)。
  void Function(String deviceId, Uint8List jpeg)? onThumb;

  /// 连接态变化。
  void Function(ConnState state)? onState;

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

  /// 等待二进制帧的缩略图元信息(§6.4：thumb_meta 之后紧跟一个二进制帧)。
  ThumbMeta? _pendingThumb;

  ConnState get state => _state;

  /// 开始连接(并允许之后自动重连)。
  void connect({required String host, required int port, bool secure = false}) {
    _host = host;
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

  /// 构造、签名并发送一个出站信封。未连接时丢弃并记录。
  void send(
    String type, {
    required String to,
    Map<String, dynamic> payload = const {},
  }) {
    final ch = _channel;
    if (ch == null || _state != ConnState.connected) {
      _log('send($type) 丢弃：未连接');
      return;
    }
    final env = codec.build(type: type, to: to, payload: payload);
    ch.sink.add(env.toJson());
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
    final vr = codec.verify(env);
    if (vr != VerifyError.ok) {
      _log('入站验签失败(${env.type}): $vr');
      return;
    }
    switch (env.type) {
      case 'welcome':
        final snap = (env.payload['snapshot'] as Map?)?.cast<String, dynamic>();
        if (snap != null) onWall?.call(WallSnapshot.fromMap(snap));
        _log('已接入(welcome)');
        break;
      case 'wall':
        onWall?.call(WallSnapshot.fromMap(env.payload));
        break;
      case 'thumb_meta':
        _pendingThumb = ThumbMeta.fromMap(env.payload);
        break;
      case 'ack':
        _log('ack: ${env.payload}');
        break;
      case 'error':
        _log('error: ${env.payload}');
        break;
      default:
        _log('忽略入站类型: ${env.type}');
    }
  }

  void _onBinary(Uint8List bytes) {
    final meta = _pendingThumb;
    if (meta == null) {
      _log('收到二进制帧但无配对的 thumb_meta，丢弃');
      return;
    }
    _pendingThumb = null;
    if (meta.bytes > 0 && bytes.length != meta.bytes) {
      _log('缩略图字节数不符(meta=${meta.bytes}, got=${bytes.length})');
    }
    onThumb?.call(meta.deviceId, bytes);
  }

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
    _pendingThumb = null;
  }

  void _setState(ConnState s) {
    if (_state == s) return;
    _state = s;
    onState?.call(s);
  }

  void _log(String line) => onLog?.call(line);
}
