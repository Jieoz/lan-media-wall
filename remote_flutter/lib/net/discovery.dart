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

  /// 周期广播定时器：不再"绑完就干等",而是主动、反复探测(§7/§14.5)。
  Timer? _periodicTimer;

  /// 周期发现间隔。启动后立即发一次,再按此间隔重发,直到 [dispose]。
  static const Duration discoverInterval = Duration(seconds: 5);

  List<AnnounceInfo> get devices => _devices.values.toList(growable: false);

  /// 启动 UDP 监听并加载持久化清单。
  ///
  /// 修 Bug「自动发现不可用」根因:此前 [start] 只绑定 socket + 读缓存,**从不主动
  /// 广播 discover**,被控端永远收不到探测,只有 UI 手动刷新才发一次。现在启动即
  /// 广播一次,并开一个周期定时器持续重发,让新上线/刚联网的被控端能被自动发现。
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
      return;
    }
    // 启动即探测一次,随后周期重发(§7 零配置自动发现的关键)。
    await refreshBroadcasts();
    discover();
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(discoverInterval, (_) {
      // 每轮先刷新网卡广播地址(适应联网/换网),再探测。
      refreshBroadcasts().whenComplete(discover);
    });
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
    // 全局广播 255.255.255.255 在部分 AP/交换机上被丢弃;补发到各网卡的
    // **子网定向广播地址**(如 192.168.1.255),两路并发提升发现命中率。
    var sent = 0;
    try {
      sock.send(data, InternetAddress('255.255.255.255'), discoverPort);
      sent++;
    } catch (e) {
      _log('全局广播失败: $e');
    }
    for (final bcast in _subnetBroadcasts()) {
      try {
        sock.send(data, InternetAddress(bcast), discoverPort);
        sent++;
      } catch (_) {/* 单个网卡失败不影响其它 */}
    }
    if (sent > 0) _log('已广播 discover ($sent 路)');
  }

  /// 枚举各 IPv4 网卡的子网定向广播地址(假定 /24,覆盖绝大多数家用/展厅网段)。
  /// 有线 + WiFi 双出口时都会各得一个,解决单播广播被过滤的问题(§5/§7)。
  List<String> _subnetBroadcasts() {
    final out = <String>[];
    try {
      // NetworkInterface.list 是异步的;这里用已缓存的同步近似不可行,故走一个
      // best-effort:失败就只靠全局广播。实际枚举在 [refreshBroadcasts] 预取。
      out.addAll(_cachedBroadcasts);
    } catch (_) {}
    return out;
  }

  final List<String> _cachedBroadcasts = [];

  /// 预取各网卡子网广播地址(异步),供后续 [discover] 使用。start() 会调一次,
  /// 之后每次周期发现也刷新,以适应联网/换网。
  Future<void> refreshBroadcasts() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final next = <String>[];
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            next.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
          }
        }
      }
      _cachedBroadcasts
        ..clear()
        ..addAll(next.toSet());
    } catch (e) {
      _log('枚举网卡广播地址失败: $e');
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
    // §13：按当前 auth_mode 接受签名（open 放行空 sig；required 强制验签）。
    if (!codec.acceptSig(env)) {
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

  /// 手动登记一台被控端(扫码/粘贴其 enroll `lmw://` URI，§15 反向)。
  /// 等价于一次成功的 UDP 发现：并入清单、持久化、通知 —— 随后 [WallState]
  /// 的拓扑评估会自动对其建立 p2p 直连。deviceId 为空时忽略。
  void addManual(AnnounceInfo info) {
    if (info.deviceId.isEmpty) return;
    _devices[info.deviceId] = info;
    _log('手动添加设备 ${info.deviceName}(${info.ip})');
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
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _socket?.close();
    _socket = null;
  }

  void _log(String line) => onLog?.call(line);
}
