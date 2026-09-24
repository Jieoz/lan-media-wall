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

/// 设备墙顶栏计数。只看每台的接入相位和控制端当前是不是 P2P。
///
/// 控制端在 P2P：已连接的算 P2P，失败的算「连不上」。
/// 控制端在 Broker：在线已连接的算 Broker。发现到但没连上的不算任何一种，
/// 避免把「还没拨号」说成连不上。
class DeviceLinkCensus {
  const DeviceLinkCensus({
    required this.p2pConnected,
    required this.brokerConnected,
    required this.unreachable,
  });

  final int p2pConnected;
  final int brokerConnected;
  final int unreachable;

  static DeviceLinkCensus count({
    required bool controllerIsP2p,
    required Iterable<({bool connected, bool failed})> devices,
  }) {
    var p2p = 0;
    var broker = 0;
    var unreachable = 0;
    for (final d in devices) {
      if (d.connected && controllerIsP2p) {
        p2p++;
      } else if (d.connected) {
        broker++;
      } else if (d.failed) {
        unreachable++;
      }
    }
    return DeviceLinkCensus(
      p2pConnected: p2p,
      brokerConnected: broker,
      unreachable: unreachable,
    );
  }

  /// 顶栏一行。三种都出数字，包括 0，避免「没写」被看成「没有这种设备」。
  String get label =>
      'P2P 已连接 $p2pConnected · Broker $brokerConnected · 连不上 $unreachable';

  /// 单卡标记。未连接不标传输方式，只由相位文案说明。
  static String? cardMark({
    required bool controllerIsP2p,
    required bool connected,
  }) {
    if (!connected) return null;
    return controllerIsP2p ? 'P2P' : 'Broker';
  }
}
