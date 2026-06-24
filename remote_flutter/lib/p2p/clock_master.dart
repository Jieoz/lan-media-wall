import '../protocol/envelope.dart';

/// p2p 主时钟（protocol_spec.md §14.3 / §8）。
///
/// 模式 C 下遥控端兼任 broker 的时钟角色：被控端把 §8.1 的 `time_sync` 直接发给遥控端，
/// 遥控端回 `time_sync_ack`。`server_time` = 遥控端本地时钟。
///
/// 纯逻辑：注入 [nowFn] 便于单测；不触碰 socket。
class ClockMaster {
  ClockMaster({int Function()? nowFn}) : _now = nowFn ?? nowMs;

  final int Function() _now;

  /// 遥控端本地“主时钟”当前毫秒（§14.3：server_time = 遥控端本地时钟）。
  int serverTime() => _now();

  /// 给定一个入站 `time_sync` 的 payload，产出 `time_sync_ack` 的 payload（§8.1）。
  ///
  /// 入参：
  ///  - [reqPayload]：player 发来的 `{"t1": <player_send_ms>}`。
  ///  - [reqMsgId]：原 time_sync 的 `msg_id`（回写到 `req_msg_id`，§8.1 v1.1 关联）。
  ///  - [recvMs]：遥控端收到该请求的本地时刻（t2）；缺省取 [serverTime]。
  ///
  /// 回包形如 `{"t1":<echo>,"t2":<recv>,"t3":<send>,"req_msg_id":<echo>}`。
  /// t3（遥控端发出时刻）在产出时点用 [serverTime] 取，尽量贴近真实发送时刻。
  Map<String, dynamic> ackPayload(
    Map<String, dynamic> reqPayload, {
    String? reqMsgId,
    int? recvMs,
  }) {
    final t1 = _asInt(reqPayload['t1']);
    final t2 = recvMs ?? serverTime();
    final t3 = serverTime();
    return {
      't1': t1,
      't2': t2,
      't3': t3,
      if (reqMsgId != null) 'req_msg_id': reqMsgId,
    };
  }

  static int _asInt(Object? v) =>
      v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);
}
