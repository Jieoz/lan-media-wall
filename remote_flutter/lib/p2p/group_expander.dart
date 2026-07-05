import '../protocol/messages.dart';

/// p2p 客户端侧的 `group:<gid>` 展开（protocol_spec.md §14.3 路由）。
///
/// p2p 无 broker 代为扇出：`to:"group:<gid>"` 由遥控端展开为对组内每个成员逐条发送；
/// `to:"player:<id>"` 直达对应那条直连 socket；`to:"all"` 展开为所有已知成员。
///
/// 纯逻辑：仅依据当前已知的分组成员关系与在线连接集合做计算。
class GroupExpander {
  /// 由各被控端上报的 `status.group_id` 推出“组 → 成员 device_id 列表”。
  /// 仅纳入 [connected]（当前持有直连 socket）的设备，避免向已掉线设备投递。
  static Map<String, List<String>> groupsOf(
    Iterable<DeviceStatus> devices, {
    Set<String>? connected,
  }) {
    final map = <String, List<String>>{};
    for (final d in devices) {
      if (d.deviceId.isEmpty) continue;
      if (connected != null && !connected.contains(d.deviceId)) continue;
      if (d.groupId.isEmpty) continue;
      (map[d.groupId] ??= []).add(d.deviceId);
    }
    return map;
  }

  /// 把一个信封 `to` 地址展开为目标 device_id 集合。
  ///
  ///  - `player:<id>`：单成员（若在 [connected] 中）。
  ///  - `group:<gid>`：组内全部成员（依 [devices] 的 group_id 归属）。
  ///  - `all` / `broker`：所有已连接成员（p2p 无 broker，按全体处理）。
  ///
  /// 结果对 [connected] 取交集（None 表示不过滤）。返回去重、稳定顺序的列表。
  static List<String> expand(
    String to, {
    required Iterable<DeviceStatus> devices,
    Set<String>? connected,
  }) {
    final all = <String>[
      for (final d in devices)
        if (d.deviceId.isNotEmpty) d.deviceId,
    ];
    Iterable<String> raw;
    if (to.startsWith('player:')) {
      raw = [to.substring('player:'.length)];
    } else if (to.startsWith('group:')) {
      final gid = to.substring('group:'.length).trim().toLowerCase();
      raw = [
        for (final d in devices)
          // group 比较容忍前后空格 + 大小写差异(真机上 group_id 常因这些细节漂移,
          // 导致"default" vs "default " vs "Default" 匹配失败 → 推图静默 0 台)。
          // gid 为空时视为通配(匹配所有设备),避免"未指定组"被当成"匹配空组"。
          if ((gid.isEmpty || d.groupId.trim().toLowerCase() == gid) &&
              d.deviceId.isNotEmpty)
            d.deviceId,
      ];
    } else {
      // all / broker / 其它 → 全体
      raw = all;
    }
    final seen = <String>{};
    final out = <String>[];
    for (final id in raw) {
      if (id.isEmpty) continue;
      if (connected != null && !connected.contains(id)) continue;
      if (seen.add(id)) out.add(id);
    }
    return out;
  }
}
