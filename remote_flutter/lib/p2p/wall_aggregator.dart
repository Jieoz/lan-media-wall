import '../protocol/messages.dart';

/// p2p 状态墙聚合（protocol_spec.md §14.3）。
///
/// 无 broker 的 `wall` 聚合帧：遥控端直接聚合各被控端的 `status`，本地合并成
/// [WallSnapshot] 供 UI 渲染。
///
/// 纯逻辑：持有“device_id → 最近一帧 status”，并由 status.group_id 反推分组。
class WallAggregator {
  /// device_id → 最近一帧 DeviceStatus。
  final Map<String, DeviceStatus> _devices = {};

  /// device_id → 该设备最近活跃时刻（epoch ms），用于在线判定/排序。
  final Map<String, int> _lastSeen = {};

  int get deviceCount => _devices.length;

  /// 合并一帧 `status`（§5.1）。[seenAt] 为遥控端收到时刻（缺省自动取 now）。
  /// 返回合并后的设备条目。
  DeviceStatus mergeStatus(DeviceStatus status, {int? seenAt}) {
    final t = seenAt ?? DateTime.now().millisecondsSinceEpoch;
    // 若 status 未带 last_seen，则用本地收到时刻补齐（§5.2 存活字段）。
    final merged = status.lastSeen == null
        ? status.copyWith(lastSeen: t)
        : status;
    _devices[merged.deviceId] = merged;
    _lastSeen[merged.deviceId] = t;
    return merged;
  }

  /// 标记某设备离线（直连 socket 断开时调用）。保留其最后一帧，仅置 online=false。
  void markOffline(String deviceId) {
    final d = _devices[deviceId];
    if (d == null) return;
    _devices[deviceId] = d.copyWith(online: false);
  }

  /// 移除一个设备（彻底丢弃，例如用户删除）。
  void remove(String deviceId) {
    _devices.remove(deviceId);
    _lastSeen.remove(deviceId);
  }

  void clear() {
    _devices.clear();
    _lastSeen.clear();
  }

  /// 把当前所有设备按 group_id 归并成 [WallGroup] 列表。
  /// 组的 sync/playlist_id 取该组成员中“有 playlist_id 的最新一帧”为代表。
  List<WallGroup> buildGroups() {
    final byGroup = <String, List<DeviceStatus>>{};
    for (final d in _devices.values) {
      final gid = d.groupId.isEmpty ? '(未分组)' : d.groupId;
      (byGroup[gid] ??= []).add(d);
    }
    final groups = <WallGroup>[];
    for (final entry in byGroup.entries) {
      final members = entry.value.map((d) => d.deviceId).toList()..sort();
      // 取任一带 playlist_id 的成员作为组播放列表代表。
      String? playlistId;
      for (final d in entry.value) {
        if (d.playlistId != null && d.playlistId!.isNotEmpty) {
          playlistId = d.playlistId;
          break;
        }
      }
      groups.add(WallGroup(
        groupId: entry.key,
        name: entry.key,
        sync: true,
        playlistId: playlistId,
        members: members,
      ));
    }
    groups.sort((a, b) => a.groupId.compareTo(b.groupId));
    return groups;
  }

  /// 产出本地聚合的设备墙快照（替代 broker 的 `wall` 帧，§14.3）。
  /// [serverTime] 由遥控端主时钟（[ClockMaster.serverTime]）提供。
  WallSnapshot snapshot({required int serverTime}) {
    final devices = _devices.values.toList()
      ..sort((a, b) => a.deviceId.compareTo(b.deviceId));
    return WallSnapshot(
      serverTime: serverTime,
      groups: buildGroups(),
      devices: devices,
    );
  }
}
