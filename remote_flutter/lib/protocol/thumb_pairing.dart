import 'dart:typed_data';

import 'messages.dart';

/// 缩略图两帧配对状态机（§6.4）：先到一个 `thumb_meta`（JSON 文本帧），紧跟一个
/// 二进制帧承载 JPEG 字节。broker 直连（[BrokerClient]）与 p2p 直连
/// （[P2pCoordinator]）走的是同一套两帧协议，此前 broker 路径内联实现、p2p 路径
/// 直接把 thumb_meta 丢进 default 分支丢弃——导致 p2p 直连看不到缩略图。
///
/// 把配对逻辑收敛到这一个纯 Dart 类，两端复用同一实现（无分叉）：
///  - 收到 thumb_meta 文本帧 → [onMeta] 暂存元信息；
///  - 收到紧跟的二进制帧 → [onBinary] 与暂存元信息配对，字节数校验后交给 [onThumb]；
///  - 连接关闭/重置 → [reset] 清掉悬空的待配对元信息。
///
/// 无 Android/Flutter 依赖，可直接在纯 Dart 单测里驱动。
class ThumbPairing {
  ThumbPairing({this.onThumb, this.onLog});

  /// 配对完成：交出该设备的缩略图 JPEG 字节。
  void Function(String deviceId, Uint8List jpeg)? onThumb;

  /// 诊断日志。
  void Function(String line)? onLog;

  /// 等待二进制帧的缩略图元信息（thumb_meta 之后紧跟一个二进制帧）。
  ThumbMeta? _pending;

  /// 处理一个 `thumb_meta` payload：暂存，等紧跟的二进制帧。
  void onMeta(Map<String, dynamic> payload) {
    _pending = ThumbMeta.fromMap(payload);
  }

  /// 处理一个二进制帧：与暂存的 [ThumbMeta] 配对。无暂存元信息时丢弃。
  void onBinary(Uint8List bytes) {
    final meta = _pending;
    if (meta == null) {
      onLog?.call('收到二进制帧但无配对的 thumb_meta，丢弃');
      return;
    }
    _pending = null;
    if (meta.bytes > 0 && bytes.length != meta.bytes) {
      onLog?.call('缩略图字节数不符(meta=${meta.bytes}, got=${bytes.length})');
    }
    onThumb?.call(meta.deviceId, bytes);
  }

  /// 清掉悬空的待配对元信息（连接关闭/重连时调用）。
  void reset() {
    _pending = null;
  }
}
