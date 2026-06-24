import 'dart:async';

import 'package:web_socket_channel/io.dart';

/// 一条到单个被控端的 WS 直连抽象（protocol_spec.md §14.3）。
///
/// 抽象出接口便于在单测里用 fake 替换真实 socket（见 test/p2p_*_test.dart）。
abstract class WsLink {
  /// 文本帧流（已是解码后的 String）。
  Stream<String> get textStream;

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

  @override
  Stream<String> get textStream => _ch.stream
      .where((e) => e is String)
      .cast<String>();

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
