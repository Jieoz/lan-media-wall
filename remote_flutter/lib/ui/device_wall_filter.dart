/// 设备墙分组筛选的纯逻辑 —— 无 Flutter 依赖,便于单元测试。
///
/// 规则:
/// - [filterGroupId] 为 null / 空 / 哨兵 `__all__` → 不过滤,返回全部
/// - 否则只保留 `deviceGroupId == filterGroupId` 的设备
/// - 尚无 status 的占位卡(groupId 未知)在筛选某组时隐藏,避免误显
class DeviceWallFilter {
  const DeviceWallFilter._();

  /// 「全部」哨兵;UI 用它表示未筛选。
  static const String all = '__all__';

  static bool isAll(String? filterGroupId) =>
      filterGroupId == null ||
      filterGroupId.isEmpty ||
      filterGroupId == all;

  /// 单台是否匹配当前筛选。
  static bool matches({
    required String? deviceGroupId,
    required String? filterGroupId,
  }) {
    if (isAll(filterGroupId)) return true;
    if (deviceGroupId == null || deviceGroupId.isEmpty) return false;
    return deviceGroupId == filterGroupId;
  }

  /// 过滤设备列表。[groupOf] 从条目取出 groupId(占位可为 null)。
  static List<T> apply<T>(
    List<T> devices, {
    required String? filterGroupId,
    required String? Function(T device) groupOf,
  }) {
    if (isAll(filterGroupId)) return List<T>.from(devices);
    return devices
        .where((d) => matches(
              deviceGroupId: groupOf(d),
              filterGroupId: filterGroupId,
            ))
        .toList(growable: false);
  }
}
