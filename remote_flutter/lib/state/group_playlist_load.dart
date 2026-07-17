import '../protocol/messages.dart';

/// 「载入分组当前清单」的**纯逻辑**(§6.3 group read-back)。
///
/// 单台载入([PlaylistDraft.loadFromDevice])只读一台;分组载入要在一组在线成员里
/// 挑一个**代表**,把它上报的 `active_playlist` 作为草稿,同时如实统计组内一致性
/// (一致/不同/未上报),让操作员看到真相而不是被隐藏的分歧。此文件不依赖 Flutter
/// widget,可脱离 UI 单测。
class GroupPlaylistLoadResult {
  /// 是否成功选出可载入的代表(其 active_playlist 非空)。
  final bool ok;

  /// 被选中的代表设备(失败时为 null)。
  final DeviceStatus? representative;

  /// 代表上报的可载入清单(失败时为 null)。UI 用它喂 [PlaylistDraft.load]。
  final ActivePlaylist? draft;

  /// 代表在 active_playlist 中的当前位置(如上报)。
  final int? currentIndex;

  /// 组内在线且与代表指纹一致的成员数(含代表本身)。
  final int matchCount;

  /// 组内在线、上报了非空 active_playlist、但指纹与代表不同的成员数。
  final int divergeCount;

  /// 组内在线但未上报可用 active_playlist 的成员数。
  final int missingCount;

  /// 组内在线成员总数(= matchCount + divergeCount + missingCount)。
  final int onlineCount;

  /// 面向操作员的中文摘要(toast/snackbar 文案)。
  final String message;

  const GroupPlaylistLoadResult({
    required this.ok,
    this.representative,
    this.draft,
    this.currentIndex,
    this.matchCount = 0,
    this.divergeCount = 0,
    this.missingCount = 0,
    this.onlineCount = 0,
    required this.message,
  });
}

/// 一台成员的清单指纹:`playlist_id` + 有序 `item_id` join。完整比较对播放列表
/// 规模(几十项)足够便宜,且能区分「同 id 但条目/顺序被改」的情况。
String playlistFingerprint(ActivePlaylist active) {
  final ids = active.items.map((e) => e.itemId).join(',');
  return '${active.playlistId}#${active.items.length}#$ids';
}

/// 代表是否比另一台「更适合当代表」(仅在两者都持有非空清单时用于打破平手)。
/// 播放中/缓冲中优先于空闲;仍平手时按 deviceId 字典序稳定取小。
bool _prefer(DeviceStatus a, DeviceStatus b) {
  int rank(DeviceStatus d) {
    switch (d.state) {
      case 'playing':
      case 'buffering':
        return 0;
      case 'paused':
      case 'downloading':
        return 1;
      default: // idle / 未知
        return 2;
    }
  }

  final ra = rank(a), rb = rank(b);
  if (ra != rb) return ra < rb;
  return a.deviceId.compareTo(b.deviceId) <= 0;
}

/// 从一组成员状态里挑代表并统计一致性。
///
/// [members] 应为**该分组的成员** DeviceStatus(调用方用 `state.membersOf(groupId)`
/// 传入);此函数内部只认「在线且 active_playlist 非空」的成员做候选,离线/未上报
/// 计入 missing。[selectedGroupId] 为当前目标分组,用于优先匹配。
///
/// 代表选择策略(§需求):
///  a. 优先 `active_playlist.groupId == selectedGroupId` 的成员;
///  b. 否则任一在线、active_playlist 非空的成员;
///  c. 平手时 playing/buffering 优先于 idle;
///  d. 仍平手按 deviceId 字典序稳定取小。
GroupPlaylistLoadResult loadGroupPlaylist(
  List<DeviceStatus> members, {
  required String? selectedGroupId,
}) {
  if (members.isEmpty) {
    return const GroupPlaylistLoadResult(
      ok: false,
      message: '该分组暂无成员;请先在设备墙把设备加入此组',
    );
  }

  final online = members.where((d) => d.online).toList(growable: false);
  if (online.isEmpty) {
    return const GroupPlaylistLoadResult(
      ok: false,
      message: '该分组无在线设备;无法读取当前清单',
    );
  }

  // 候选 = 在线且上报了**非空** active_playlist 的成员。
  final candidates = online
      .where((d) =>
          d.activePlaylist != null && d.activePlaylist!.items.isNotEmpty)
      .toList(growable: false);

  if (candidates.isEmpty) {
    return GroupPlaylistLoadResult(
      ok: false,
      onlineCount: online.length,
      missingCount: online.length,
      message: '该分组在线设备均未上报 active_playlist;请先推送清单或升级播放端',
    );
  }

  // 策略 a:优先属于本组的候选;若无则退回全部候选(策略 b)。
  final grouped = (selectedGroupId != null && selectedGroupId.isNotEmpty)
      ? candidates
          .where((d) => d.activePlaylist!.groupId == selectedGroupId)
          .toList(growable: false)
      : const <DeviceStatus>[];
  final pool = grouped.isNotEmpty ? grouped : candidates;

  // 策略 c/d:在 pool 内按偏好取代表。
  DeviceStatus rep = pool.first;
  for (final d in pool.skip(1)) {
    if (_prefer(d, rep)) rep = d;
  }
  final repFp = playlistFingerprint(rep.activePlaylist!);

  // 一致性统计:遍历所有在线成员。
  var match = 0, diverge = 0, missing = 0;
  for (final d in online) {
    final ap = d.activePlaylist;
    if (ap == null || ap.items.isEmpty) {
      missing++;
    } else if (playlistFingerprint(ap) == repFp) {
      match++;
    } else {
      diverge++;
    }
  }

  final repName =
      (rep.deviceName == null || rep.deviceName!.isEmpty) ? rep.deviceId : rep.deviceName!;
  final message = _summarize(
    repName: repName,
    match: match,
    diverge: diverge,
    missing: missing,
    online: online.length,
  );

  return GroupPlaylistLoadResult(
    ok: true,
    representative: rep,
    draft: rep.activePlaylist,
    currentIndex: rep.currentIndex,
    matchCount: match,
    divergeCount: diverge,
    missingCount: missing,
    onlineCount: online.length,
    message: message,
  );
}

/// 生成如实反映分歧的操作员文案。全一致 → 简洁成功;有分歧/缺报 → 明确列出。
String _summarize({
  required String repName,
  required int match,
  required int diverge,
  required int missing,
  required int online,
}) {
  if (diverge == 0 && missing == 0) {
    return '已从代表 $repName 载入;组内 $match/$online 台一致';
  }
  final parts = <String>['组内 $match 台一致'];
  if (diverge > 0) parts.add('$diverge 台不同');
  if (missing > 0) parts.add('$missing 台未上报');
  return '已从代表 $repName 载入;${parts.join('、')}';
}
