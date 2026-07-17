import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../protocol/envelope.dart';
import '../protocol/messages.dart';
import '../state/playlist_draft.dart';
import '../state/wall_state.dart';
import 'dwell_picker.dart';

/// 播放编排栏(设计合同 §4.1 右栏) —— 主工作区。
///
/// 任务流:选组 → 编列表(本地上传 + URL + 图片停留) → 预缓存 → 全员就绪一键起播
/// → 传输/音量/出声台控制。预缓存栅栏进度实时显示每台缓存态(§21)。
class OrchestrationPane extends StatefulWidget {
  const OrchestrationPane({super.key});

  @override
  State<OrchestrationPane> createState() => _OrchestrationPaneState();
}

class _OrchestrationPaneState extends State<OrchestrationPane> {
  String? _groupId;
  String? _deviceId;
  final PlaylistDraft _draft = PlaylistDraft();
  bool _uploading = false;
  String _uploadHint = '';

  @override
  void initState() {
    super.initState();
    // The draft is the single source of truth for the editable list + options;
    // rebuild the pane whenever it mutates so the editor stays in sync.
    _draft.addListener(_onDraftChanged);
  }

  @override
  void dispose() {
    _draft.removeListener(_onDraftChanged);
    _draft.dispose();
    super.dispose();
  }

  void _onDraftChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WallState>();
    final groups = state.groups;
    if (_groupId != null && state.groupById(_groupId!) == null) _groupId = null;
    _groupId ??= groups.isNotEmpty ? groups.first.groupId : null;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _groupSelector(state, groups),
        const SizedBox(height: 12),
        _devicePlaylistSelector(state),
        const SizedBox(height: 12),
        _barrierProgress(state),
        const SizedBox(height: 12),
        _playlistEditor(state),
        const SizedBox(height: 12),
        _transportControls(state),
        const SizedBox(height: 12),
        _volumeControls(state),
        const SizedBox(height: 12),
        _audioMasterControls(state),
      ],
    );
  }

  WallGroup? get _group =>
      _groupId == null ? null : context.read<WallState>().groupById(_groupId!);

  bool get _canSend => _groupId != null && _draft.isNotEmpty;

  String _newPlaylistId() => 'pl-${_groupId ?? "g"}-${uuid4().substring(0, 6)}';

  // ---- 组选择 ----
  Widget _groupSelector(WallState state, List<WallGroup> groups) {
    return _Section(
      title: '目标分组',
      child: groups.isEmpty
          ? const Text('暂无分组 · 先在左侧设备墙「新建组」')
          : DropdownButton<String>(
              isExpanded: true,
              value: _groupId,
              items: [
                for (final g in groups)
                  DropdownMenuItem(
                    value: g.groupId,
                    child: Text(
                        '${g.name.isEmpty ? g.groupId : g.name} · ${g.members.length}台 · ${g.sync ? "同步" : "各播各的"}'),
                  ),
              ],
              onChanged: (v) => setState(() => _groupId = v),
            ),
    );
  }

  // ---- §21 预缓存栅栏进度 ----
  Widget _devicePlaylistSelector(WallState state) {
    final devices = state.wallDevices
        .where((d) => d.status?.online == true)
        .toList();
    if (_deviceId != null && !devices.any((d) => d.deviceId == _deviceId)) {
      _deviceId = null;
    }
    return _Section(
      title: '单台当前播放列表',
      child: Row(children: [
        Expanded(child: DropdownButton<String>(
          isExpanded: true,
          value: _deviceId,
          hint: const Text('选择已连接设备'),
          items: [for (final d in devices) DropdownMenuItem(
            value: d.deviceId, child: Text(d.deviceName.isEmpty ? d.deviceId : d.deviceName))],
          onChanged: (id) => setState(() {
            _deviceId = id;
            final status = id == null
                ? null
                : state.wallDevices
                    .where((d) => d.deviceId == id)
                    .firstOrNull
                    ?.status;
            if (status != null && _draft.loadFromDevice(status)) {
              // The player echoes its exact ordered active playlist and current
              // index in status. Import that as the editable draft instead of
              // constructing a new one from cache inventory.
              final group = status.activePlaylist!.groupId;
              _groupId = group.isEmpty ? _groupId : group;
            } else if (id != null) {
              // Never leave the previously selected device's playlist armed for
              // a different/legacy box.
              _draft.clear();
              _draft.detachPlaylistId();
              _toast('该设备未上报可编辑的当前播放列表；请先升级被控端');
            }
          }),
        )),
        const SizedBox(width: 8),
        FilledButton.icon(
          icon: const Icon(Icons.save), label: const Text('应用到此设备'),
          onPressed: _deviceId == null ? null : () {
            final d = state.wallDevices
                .where((item) => item.deviceId == _deviceId)
                .firstOrNull;
            final group = d?.status?.groupId ?? _groupId ?? '';
            state.sendPlaylist(playlistId: _draft.playlistId ?? _newPlaylistId(),
              groupId: group, sync: _draft.sync, loopMode: _draft.loopMode,
              items: _draft.items, mode: 'replace', deviceId: _deviceId);
            state.cachePrefetch(_draft.items, deviceId: _deviceId);
            _toast('已更新 ${d?.deviceName ?? _deviceId} 的播放列表并开始缓存；未删除缓存文件');
          },
        ),
      ]),
    );
  }

  // ---- §21 预缓存栅栏进度 ----
  Widget _barrierProgress(WallState state) {
    final g = _group;
    if (g == null) return const SizedBox.shrink();
    final members = state.membersOf(g.groupId);
    if (members.isEmpty) return const SizedBox.shrink();
    // §6.4 真实字节级进度:由共享进度状态机聚合(P2P 与 broker 同源喂入),
    // 而非仅 ready/total 的粗粒度。栏体现整批 0..100 的单调进度;完成度仍以
    // 「全员每项 ready」为准(percent 在 finalize 前被封顶 <100,§21 栅栏语义不变)。
    final batch = state.batchProgress(members.map((m) => m.deviceId));
    final frac = batch.totalDevices == 0 ? 0.0 : batch.percent / 100.0;
    final allReady = batch.completeDevices == members.length;
    // §6.4/E0002 risk 3: a device that errored (checksum/download failure) or
    // dropped offline mid-job is surfaced as a FAILURE, not a live bar — a job
    // frozen at a high percent must never read as ongoing success.
    final hasError = batch.errorDevices > 0;
    final theme = Theme.of(context);
    return _Section(
      title: hasError
          ? '预缓存中断 · ${batch.errorDevices} 台失败/掉线 · 就绪 '
              '${batch.completeDevices}/${members.length}'
          : '预缓存进度 ${batch.percent}% · 就绪 '
              '${batch.completeDevices}/${members.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            // A failed job shows a frozen determinate bar tinted with the error
            // color, not an animated one that would imply progress is ongoing.
            value: frac,
            color: hasError ? theme.colorScheme.error : null,
          ),
          const SizedBox(height: 6),
          Text(
            hasError
                ? '部分设备下载失败或中途掉线,已停止在中断处(未显示为成功)。'
                    '请检查设备连接后重试推送。'
                : allReady
                    ? '全员就绪,可一键同步起播(将从头统一开始)'
                    : '等待各台下载+校验完成;全员就绪后才统一起播(§21 栅栏)。'
                        '进度条为真实字节级聚合,校验/落盘前不显示 100%',
            style: theme.textTheme.bodySmall?.copyWith(
              color: hasError ? theme.colorScheme.error : null,
            ),
          ),
        ],
      ),
    );
  }

  // ---- playlist 编辑(本地上传 + URL) ----
  Widget _playlistEditor(WallState state) {
    return _Section(
      title: '播放列表 (${_draft.length} 项)',
      trailing: Wrap(
        spacing: 4,
        children: [
          IconButton(
            tooltip: '上传本地图片',
            icon: const Icon(Icons.add_photo_alternate),
            onPressed: _uploading ? null : () => _pickAndUpload(state, 'image'),
          ),
          IconButton(
            tooltip: '上传本地视频',
            icon: const Icon(Icons.video_call),
            onPressed: _uploading ? null : () => _pickAndUpload(state, 'video'),
          ),
          IconButton(
            tooltip: '加 URL',
            icon: const Icon(Icons.link),
            onPressed: () => _addUrlDialog('video'),
          ),
          IconButton(
            tooltip: '清空列表',
            icon: const Icon(Icons.clear_all),
            onPressed: _draft.isEmpty || _uploading ? null : _clearDraft,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_uploading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_uploadHint,
                      style: Theme.of(context).textTheme.bodySmall)),
                ],
              ),
            ),
          if (_draft.isEmpty && !_uploading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '上传本机图片/视频,或加 http URL。图片需设停留时长。\n'
                '内容先缓存到各盒子本地,全员就绪后统一从头播放。',
                style: TextStyle(fontSize: 12),
              ),
            )
          else
            ...List.generate(_draft.length, (i) {
              final it = _draft.items[i];
              return ListTile(
                dense: true,
                leading: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(it.isImage ? Icons.image : Icons.movie),
                    if (_draft.currentIndex == i)
                      const Positioned(
                        right: -7,
                        bottom: -7,
                        child: Icon(Icons.play_circle_fill, size: 15),
                      ),
                  ],
                ),
                title: Text(
                  '${i + 1}. ${it.name}${_draft.currentIndex == i ? " · 当前播放" : ""}',
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(it.isImage
                    ? '图片 · ${dwellSecondsLabel(it.durationMs)} · ${_sizeStr(it.size)}'
                    : '视频 · ${_sizeStr(it.size)}'),
                trailing: Wrap(children: [
                  if (it.isImage)
                    IconButton(tooltip: '改停留时长', icon: const Icon(Icons.timer_outlined),
                      onPressed: () => _editDwell(i)),
                  IconButton(tooltip: '上移', icon: const Icon(Icons.arrow_upward),
                    onPressed: i == 0 ? null : () => _draft.move(i, i - 1)),
                  IconButton(tooltip: '下移', icon: const Icon(Icons.arrow_downward),
                    onPressed: i == _draft.length - 1 ? null : () => _draft.move(i, i + 1)),
                  IconButton(tooltip: '从播放列表删除', icon: const Icon(Icons.delete_outline),
                    onPressed: () => _draft.removeAt(i)),
                ],
                ),
              );
            }),
          const Divider(),
          Row(
            children: [
              Expanded(
                child: SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('组内同步'),
                  value: _draft.sync,
                  onChanged: (v) => setState(() => _draft.sync = v),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: DropdownButtonFormField<LoopMode>(
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: '循环模式', contentPadding: EdgeInsets.zero,
                      border: InputBorder.none),
                    value: _draft.loopMode,
                    items: const [
                      DropdownMenuItem(
                        value: LoopMode.none, child: Text('不循环')),
                      DropdownMenuItem(
                        value: LoopMode.all, child: Text('整列循环')),
                      DropdownMenuItem(
                        value: LoopMode.one, child: Text('单项循环')),
                    ],
                    onChanged: (v) => setState(
                        () => _draft.setLoopMode(v ?? LoopMode.all)),
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.download),
                label: const Text('显式整列替换并缓存 (不播)'),
                onPressed: _canSend ? () => _doPrefetch(state) : null,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.play_circle),
                label: const Text('显式整列替换并播放'),
                onPressed: _canSend ? () => _doBarrierPlay(state) : null,
              ),
              FilledButton.icon(
                icon: const Icon(Icons.playlist_add),
                label: const Text('编排/添加项目到当前列表'),
                onPressed: _canSend ? () => _doAppend(state) : null,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('清空并停播 (保留缓存)'),
                onPressed: _groupId == null
                    ? null
                    : () => _doClearRemote(state),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _sizeStr(int? bytes) {
    if (bytes == null) return '—';
    if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    return '${bytes}B';
  }

  /// 修改草稿中某图片项的停留时长(秒 UI → 毫秒),复用 [PlaylistDraft.setDurationMs]。
  Future<void> _editDwell(int index) async {
    final it = _draft.items[index];
    final ms = await showDwellPicker(context,
        initialMs: it.durationMs, title: '「${it.name}」停留时长');
    if (ms == null) return;
    _draft.setDurationMs(index, ms);
  }

  // ---- 本地上传(§20 A+B) ----
  Future<void> _pickAndUpload(WallState state, String type) async {
    final result = await FilePicker.platform.pickFiles(
      type: type == 'image' ? FileType.image : FileType.video,
      allowMultiple: true,
      withData: false, // 用文件路径流式上传,避免大视频占内存
    );
    if (result == null || result.files.isEmpty) return;
    // §5 图片必须有停留时长:上传前用**秒** UI 让操作者确认,默认 8 秒,
    // 不再静默硬编码 8000ms。整批图片共用一个停留值。
    int? durationMs;
    if (type == 'image') {
      if (!mounted) return;
      durationMs = await showDwellPicker(context);
      if (durationMs == null) return; // 取消即放弃本次上传
    }
    setState(() {
      _uploading = true;
      _uploadHint = '准备上传…';
    });
    try {
      for (final f in result.files) {
        final path = f.path;
        if (path == null) continue;
        final name = f.name;
        setState(() => _uploadHint = '上传 $name …');
        final item = await state.uploadLocalMedia(
          file: File(path),
          type: type,
          name: name,
          durationMs: durationMs,
          onProgress: (sent, total) {
            if (total > 0) {
              setState(() => _uploadHint =
                  '上传 $name  ${(sent / total * 100).toStringAsFixed(0)}%');
            }
          },
        );
        _draft.add(item);
      }
      _toast('上传完成,已加入列表');
    } catch (e) {
      _toast('上传失败: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _addUrlDialog(String type) async {
    final nameCtl = TextEditingController();
    final urlCtl = TextEditingController();
    // 停留时长以**秒**面向操作者,提交时换算为 duration_ms(毫秒)。
    final durCtl = TextEditingController(
        text: type == 'image' ? '$kDefaultDwellSeconds' : '');
    var isImage = type == 'image';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('添加 URL 媒体'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('视频'), icon: Icon(Icons.movie)),
                  ButtonSegment(value: true, label: Text('图片'), icon: Icon(Icons.image)),
                ],
                selected: {isImage},
                onSelectionChanged: (s) => setLocal(() => isImage = s.first),
              ),
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: urlCtl,
                decoration: const InputDecoration(
                    labelText: 'URL (http/WebDAV)',
                    hintText: 'http://nas.local/media/x.mp4'),
              ),
              if (isImage)
                TextField(
                  controller: durCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: '停留时长 (必填)', suffixText: '秒'),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('添加')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final name = nameCtl.text.trim();
    final url = urlCtl.text.trim();
    if (name.isEmpty || url.isEmpty) {
      _toast('名称与 URL 必填');
      return;
    }
    int? durationMs;
    if (isImage) {
      final secs = int.tryParse(durCtl.text.trim());
      if (secs == null || secs <= 0) {
        _toast('图片必须设有效停留时长(秒)');
        return;
      }
      durationMs = secs * 1000; // 线协议仍用毫秒
    }
    _draft.add(MediaItem(
      itemId: uuid4().substring(0, 8),
      type: isImage ? 'image' : 'video',
      name: name,
      url: url,
      durationMs: durationMs,
    ));
  }

  void _clearDraft() {
    _draft.clear();
    _draft.detachPlaylistId();
    _toast('已清空编辑列表(未改动任何设备)');
  }

  /// §6.3a 清空被控端 ACTIVE 播放列表:下发空列表 replace。播放器据此停播、回到
  /// 黑屏/占位安全态、清当前索引与任务持久化,但**不删除已缓存的媒体文件**。
  void _doClearRemote(WallState state) {
    try {
      state.sendPlaylist(
        playlistId: _draft.playlistId ?? _newPlaylistId(),
        groupId: _groupId!,
        sync: _draft.sync,
        loopMode: _draft.loopMode,
        items: const [],
        mode: 'replace',
        deviceId: _deviceId,
      );
      _toast('已清空${_deviceId == null ? "整组" : "该设备"}播放列表并回到黑屏;缓存文件保留');
    } catch (e) {
      _toast('清空失败: $e');
    }
  }

  void _doPrefetch(WallState state) {
    try {
      final pid = _newPlaylistId();
      final items = _draft.items;
      state.sendPlaylist(
        playlistId: pid,
        groupId: _groupId!,
        sync: _draft.sync,
        loopMode: _draft.loopMode,
        items: items,
        mode: 'replace',
      );
      state.cachePrefetch(items, groupId: _groupId);
      _toast('已下发列表 + 预缓存 (${items.length} 项)');
    } catch (e) {
      _toast('下发失败: $e');
    }
  }

  void _doBarrierPlay(WallState state) {
    try {
      final pid = _newPlaylistId();
      final items = _draft.items;
      state.sendPlaylist(
        playlistId: pid,
        groupId: _groupId!,
        sync: _draft.sync,
        loopMode: _draft.loopMode,
        items: items,
        mode: 'replace',
      );
      state.cachePrefetch(items, groupId: _groupId);
      // §21 栅栏:等全员 cache=ready 才统一起播。
      state.prepareWithBarrier(playlistId: pid, groupId: _groupId!);
      _toast(_draft.sync ? '已发起同步起播(等全员就绪)' : '已发起播放');
    } catch (e) {
      _toast('起播失败: $e');
    }
  }

  /// §6.3 append:把当前编辑列表按 item_id 去重合并到被控端「当前有序 active_playlist」
  /// 尾部(播放器保留其现有 playlist 身份与当前播放位置),不打断正在播的内容,只补拉新增
  /// 媒体。复用被控端已加载的 playlist_id;老播放器不认 append → 回退 replace(向后兼容)。
  void _doAppend(WallState state) {
    try {
      final items = _draft.items;
      state.sendPlaylist(
        playlistId: _draft.playlistId ?? _newPlaylistId(),
        groupId: _groupId!,
        sync: _draft.sync,
        loopMode: _draft.loopMode,
        items: items,
        mode: 'append',
        deviceId: _deviceId,
      );
      state.cachePrefetch(items, groupId: _groupId, deviceId: _deviceId);
      _toast('已追加 ${items.length} 项到${_deviceId == null ? "整组" : "该设备"}当前列表(按 item_id 去重)');
    } catch (e) {
      _toast('追加失败: $e');
    }
  }

  void _runCommand(void Function() command, String success) {
    try {
      command();
      _toast(success);
    } catch (e) {
      _toast('操作失败: $e');
    }
  }

  // ---- 传输控制 ----
  Widget _transportControls(WallState state) {
    final g = _groupId;
    return _Section(
      title: '播放控制 (整组)',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _ctlBtn(
            Icons.pause,
            '暂停',
            g == null
                ? null
                : () => _runCommand(
                    () => state.pause(groupId: g), '已下发整组暂停'),
          ),
          _ctlBtn(
            Icons.play_arrow,
            '恢复',
            g == null
                ? null
                : () => _runCommand(
                    () => state.resume(groupId: g), '已下发整组恢复'),
          ),
          _ctlBtn(
            Icons.stop,
            '停止',
            g == null
                ? null
                : () => _runCommand(
                    () => state.stop(groupId: g), '已下发整组停止'),
          ),
          _ctlBtn(
            Icons.skip_previous,
            '上一项',
            g == null
                ? null
                : () => _runCommand(
                    () => state.prev(groupId: g), '已下发整组上一项'),
          ),
          _ctlBtn(
            Icons.skip_next,
            '下一项',
            g == null
                ? null
                : () => _runCommand(
                    () => state.next(groupId: g), '已下发整组下一项'),
          ),
        ],
      ),
    );
  }

  Widget _volumeControls(WallState state) {
    final g = _groupId;
    return _Section(
      title: '音量 / 静音 (整组)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GroupVolumeSlider(
            onChanged: g == null
                ? null
                : (v) => _runCommand(
                    () => state.setVolume(v, groupId: g), '已下发整组音量'),
          ),
          Row(
            children: [
              _ctlBtn(
                Icons.volume_off,
                '静音',
                g == null
                    ? null
                    : () => _runCommand(
                        () => state.setMute(true, groupId: g), '已下发整组静音'),
              ),
              const SizedBox(width: 8),
              _ctlBtn(
                Icons.volume_up,
                '取消静音',
                g == null
                    ? null
                    : () => _runCommand(
                        () => state.setMute(false, groupId: g),
                        '已下发整组取消静音'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _audioMasterControls(WallState state) {
    final g = _group;
    final members = g == null ? const <DeviceStatus>[] : state.membersOf(g.groupId);
    return _Section(
      title: '出声台 set_audio_master',
      child: members.isEmpty
          ? const Text('本组暂无成员')
          : _AudioMasterPicker(
              members: members,
              onApply: (ids) {
                _runCommand(
                  () => state.setAudioMaster(
                      groupId: g!.groupId, deviceIds: ids),
                  '已指定出声台 ${ids.length} 台',
                );
              },
            ),
    );
  }

  Widget _ctlBtn(IconData icon, String label, VoidCallback? onTap) {
    return OutlinedButton.icon(
      icon: Icon(icon, size: 18),
      label: Text(label),
      onPressed: onTap,
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _GroupVolumeSlider extends StatefulWidget {
  const _GroupVolumeSlider({required this.onChanged});
  final void Function(int volume)? onChanged;

  @override
  State<_GroupVolumeSlider> createState() => _GroupVolumeSliderState();
}

class _GroupVolumeSliderState extends State<_GroupVolumeSlider> {
  double _v = 80;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.volume_down, size: 18),
        Expanded(
          child: Slider(
            value: _v,
            min: 0,
            max: 100,
            divisions: 100,
            label: _v.round().toString(),
            onChanged: widget.onChanged == null
                ? null
                : (v) => setState(() => _v = v),
            onChangeEnd:
                widget.onChanged == null ? null : (v) => widget.onChanged!(v.round()),
          ),
        ),
        SizedBox(width: 36, child: Text('${_v.round()}', textAlign: TextAlign.end)),
      ],
    );
  }
}

class _AudioMasterPicker extends StatefulWidget {
  const _AudioMasterPicker({required this.members, required this.onApply});
  final List<DeviceStatus> members;
  final void Function(List<String> deviceIds) onApply;

  @override
  State<_AudioMasterPicker> createState() => _AudioMasterPickerState();
}

class _AudioMasterPickerState extends State<_AudioMasterPicker> {
  late final Set<String> _selected = {
    for (final d in widget.members)
      if (d.audioMaster) d.deviceId
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final d in widget.members)
              FilterChip(
                label: Text(d.deviceName ?? d.deviceId),
                selected: _selected.contains(d.deviceId),
                onSelected: (s) => setState(() {
                  if (s) {
                    _selected.add(d.deviceId);
                  } else {
                    _selected.remove(d.deviceId);
                  }
                }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonal(
            onPressed: () => widget.onApply(_selected.toList()),
            child: const Text('应用出声台'),
          ),
        ),
      ],
    );
  }
}
