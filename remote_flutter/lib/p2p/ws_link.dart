import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

/// 一条到单个被控端的 WS 直连抽象（protocol_spec.md §14.3）。
///
/// 抽象出接口便于在单测里用 fake 替换真实 socket（见 test/p2p_*_test.dart）。
abstract class WsLink {
  /// 文本帧流（已是解码后的 String）。
  Stream<String> get textStream;

  /// 二进制帧流（§6.4 缩略图 thumb_meta 之后紧跟的 JPEG 字节帧）。
  /// 此前 p2p 直连只订阅 [textStream]、二进制帧被直接过滤丢弃，是「p2p 看不到
  /// 缩略图」的根因之一。
  Stream<Uint8List> get binaryStream;

  /// 连接就绪 future（握手完成）。
  Future<void> get ready;

  /// 发送一帧文本。
  void sendText(String data);

  /// 关闭连接。
  Future<void> close();
}

/// 工厂：给定 ws/wss URL 造一条 [WsLink]。便于注入 fake。
typedef WsLinkFactory = WsLink Function(Uri uri);

/// 基于 `web_socket_channel` 的真实实现。
class IoWsLink implements WsLink {
  IoWsLink(this._ch);

  factory IoWsLink.connect(Uri uri) {
    final ch = IOWebSocketChannel.connect(
      uri,
      pingInterval: const Duration(seconds: 20),
    );
    return IoWsLink(ch);
  }

  final IOWebSocketChannel _ch;

  /// 底层单订阅流转成广播，便于 text/binary 两个派生流各自订阅（否则单订阅流
  /// 被订阅两次会抛 Bad state）。text 与 binary 各自按到达顺序分发，thumb_meta
  /// 与其紧跟的二进制帧的相对顺序由协调端两个 listener 分别接收后配对。
  late final Stream<dynamic> _shared = _ch.stream.asBroadcastStream();

  @override
  Stream<String> get textStream =>
      _shared.where((e) => e is String).cast<String>();

  @override
  Stream<Uint8List> get binaryStream => _shared
      .where((e) => e is! String)
      .map((e) => e is Uint8List ? e : Uint8List.fromList((e as List).cast<int>()));

  @override
  Future<void> get ready => _ch.ready;

  @override
  void sendText(String data) => _ch.sink.add(data);

  @override
  Future<void> close() async {
    try {
      await _ch.sink.close();
    } catch (_) {}
  }
}
