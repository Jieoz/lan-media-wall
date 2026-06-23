import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/envelope.dart';
import '../protocol/messages.dart';

/// 设备发现(§7)：
///  - 向 UDP 广播地址(255.255.255.255:8772)发 `discover`，被控端单播回 `announce`。
///  - 接收 `announce`(带 §3 sig，用 [EnvelopeCodec.checkSig] 防伪造)，回填 device_id/name/ip。
///  - 持久化“上次成功设备清单(IP+名)”到 shared_preferences；重启先读缓存，再广播刷新。
///
/// 说明：控制仍走 broker WS；UDP 仅做发现/兜底(§7)。
class Discovery {
  Discovery({required this.codec, required this.controllerId});

  static const int discoverPort = 8772;
  static const String _prefsKey = 'discovery.last_devices';

  /// 与全系统一致的信封编解码器(此处仅用其 checkSig 验签出站/入站)。
  EnvelopeCodec codec;

  /// 本端 id(用于 announce 的路由地址)。
  String controllerId;

  /// 发现到/缓存的设备清单变化时回调(已去重，按 device_id)。
  void Function(List<AnnounceInfo> devices)? onDevices;

  /// 诊断日志。
  void Function(String line)? onLog;

  RawDatagramSocket? _socket;
  final Map<String, AnnounceInfo> _devices = {};

  List<AnnounceInfo> get devices => _devices.values.toList(growable: false);

  /// 启动 UDP 监听并加载持久化清单。
  Future<void> start() async {
    await _loadCached();
    try {
      final sock = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0, // 任意本地端口；announce 单播回到此源端口
      );
      sock.broadcastEnabled = true;
      sock.listen(_onEvent);
      _socket = sock;
      _log('UDP 发现已启动(本地端口 ${sock.port})');
    } catch (e) {
      _log('UDP 绑定失败: $e');
    }
  }

  /// 广播一个 discover 包(已签名)。
  void discover() {
    final sock = _socket;
    if (sock == null) {
      _log('discover 跳过：socket 未就绪');
      return;
    }
    final env = codec.build(
      type: 'discover',
      to: 'all',
      payload: {'controller_id': controllerId},
    );
    final data = utf8.encode(env.toJson());
    try {
      sock.send(data, InternetAddress('255.255.255.255'), discoverPort);
      _log('已广播 discover');
    } catch (e) {
      _log('discover 发送失败: $e');
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    final Envelope env;
    try {
      env = Envelope.fromJson(utf8.decode(dg.data));
    } catch (e) {
      _log('announce 解析失败: $e');
      return;
    }
    if (env.type != 'announce') return;
    if (!codec.checkSig(env)) {
      _log('announce 验签失败，丢弃');
      return;
    }
    final info = AnnounceInfo.fromMap(env.payload);
    if (info.deviceId.isEmpty) return;
    _devices[info.deviceId] = info;
    _log('发现设备 ${info.deviceName}(${info.ip})');
    _persist();
    onDevices?.call(devices);
  }

  Future<void> _loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final list = (jsonDecode(raw) as List).cast<dynamic>();
      for (final e in list) {
        final m = (e as Map).cast<String, dynamic>();
        final info = AnnounceInfo.fromMap(m);
        if (info.deviceId.isNotEmpty) _devices[info.deviceId] = info;
      }
      _log('已载入缓存设备 ${_devices.length} 台');
      onDevices?.call(devices);
    } catch (e) {
      _log('载入缓存设备失败: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _devices.values.map((e) => e.toMap()).toList();
      await prefs.setString(_prefsKey, jsonEncode(list));
    } catch (e) {
      _log('持久化设备清单失败: $e');
    }
  }

  void dispose() {
    _socket?.close();
    _socket = null;
  }

  void _log(String line) => onLog?.call(line);
}
