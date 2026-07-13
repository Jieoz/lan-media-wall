import 'package:flutter/foundation.dart';

import '../protocol/messages.dart';

/// 编排栏的**播放列表草稿**模型(§6.3)。
///
/// 把原先散落在 `OrchestrationPane` Widget 里的瞬态字段(条目、同步/循环开关、
/// 载入的 playlist 身份)提到一个可测试的 [ChangeNotifier]:多选导入按 `item_id`
/// 去重且保序、上移/下移/删除/清空、以及从被控端「当前 active_playlist」整体载入。
/// 对外暴露的 [items] 是只读视图,调用方不能绕过通知直接改内部列表。
class PlaylistDraft extends ChangeNotifier {
  final List<MediaItem> _items = [];

  /// 载入的既有 playlist 身份(§6.3 append 复用)。新建草稿时为 null。
  String? playlistId;

  /// 载入来源的分组;新建草稿时为 null,由 UI 的当前选组决定。
  String? groupId;

  /// 组内同步起播(§21)。默认开。
  bool sync = true;

  /// 整列循环。默认开。
  bool loop = true;

  /// 只读有序视图:外部 `add`/`removeAt` 抛 [UnsupportedError],避免绕过通知。
  List<MediaItem> get items => List.unmodifiable(_items);

  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;

  /// 多选导入:按追加顺序保留首次出现,丢弃 `item_id` 重复项(含入参内部重复)。
  /// 仅在确有新增时通知。
  void addAll(Iterable<MediaItem> incoming) {
    final seen = _items.map((e) => e.itemId).toSet();
    var added = false;
    for (final item in incoming) {
      if (seen.add(item.itemId)) {
        _items.add(item);
        added = true;
      }
    }
    if (added) notifyListeners();
  }

  /// 追加单项(去重),供 URL/上传回填复用。
  void add(MediaItem item) => addAll([item]);

  /// 上移/下移或任意重排。越界为无操作(不通知)。
  void move(int from, int to) {
    if (from < 0 || from >= _items.length || to < 0 || to >= _items.length) {
      return;
    }
    final next = PlaylistEditing.move(_items, from, to);
    _items
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  /// 删除一项。越界为无操作(不通知)。
  void removeAt(int index) {
    if (index < 0 || index >= _items.length) return;
    _items.removeAt(index);
    notifyListeners();
  }

  /// 清空条目(保留 playlist 身份/开关)。空列表清空为无操作(不通知)。
  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }

  /// 从被控端当前 [ActivePlaylist] 整体载入:替换条目与播放选项、记住其身份。
  void load(ActivePlaylist active) {
    playlistId = active.playlistId;
    groupId = active.groupId.isEmpty ? null : active.groupId;
    sync = active.sync;
    loop = active.loop;
    _items
      ..clear()
      ..addAll(active.items);
    notifyListeners();
  }

  /// 丢弃载入身份,回到「新建」态(条目保留,由调用方决定是否 [clear])。
  void detachPlaylistId() {
    playlistId = null;
  }
}
