import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../protocol/envelope.dart';
import '../protocol/messages.dart';
import '../state/wall_state.dart';

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
  bool _sync = true;
  bool _loop = true;
  final List<MediaItem> _items = [];
  bool _uploading = false;
  String _uploadHint = '';

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

  bool get _canSend => _groupId != null && _items.isNotEmpty;

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
  Widget _barrierProgress(WallState state) {
    final g = _group;
    if (g == null) return const SizedBox.shrink();
    final members = state.membersOf(g.groupId);
    if (members.isEmpty) return const SizedBox.shrink();
    // 用各台 status.cache 估算就绪度:所有条目 ready 视为该台就绪。
    var ready = 0;
    for (final m in members) {
      final c = m.cache;
      if (c.isNotEmpty && c.values.every((v) => v == 'ready')) ready++;
    }
    final frac = members.isEmpty ? 0.0 : ready / members.length;
    return _Section(
      title: '预缓存就绪 $ready/${members.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: frac),
          const SizedBox(height: 6),
          Text(
            ready == members.length
                ? '全员就绪,可一键同步起播(将从头统一开始)'
                : '等待各台下载+校验完成;全员就绪后才统一起播(§21 栅栏)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  // ---- playlist 编辑(本地上传 + URL) ----
  Widget _playlistEditor(WallState state) {
    return _Section(
      title: '播放列表 (${_items.length} 项)',
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
          if (_items.isEmpty && !_uploading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '上传本机图片/视频,或加 http URL。图片需设停留时长。\n'
                '内容先缓存到各盒子本地,全员就绪后统一从头播放。',
                style: TextStyle(fontSize: 12),
              ),
            )
          else
            ...List.generate(_items.length, (i) {
              final it = _items[i];
              return ListTile(
                dense: true,
                leading: Icon(it.isImage ? Icons.image : Icons.movie),
                title: Text(it.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(it.isImage
                    ? '图片 · ${it.durationMs ?? 0}ms · ${_sizeStr(it.size)}'
                    : '视频${it.durationMs != null ? " · ${it.durationMs}ms" : ""} · ${_sizeStr(it.size)}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => _items.removeAt(i)),
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
                  value: _sync,
                  onChanged: (v) => setState(() => _sync = v),
                ),
              ),
              Expanded(
                child: SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('循环'),
                  value: _loop,
                  onChanged: (v) => setState(() => _loop = v),
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
                label: const Text('①仅下发缓存 (不播)'),
                onPressed: _canSend ? () => _doPrefetch(state) : null,
              ),
              FilledButton.icon(
                icon: const Icon(Icons.play_circle),
                label: const Text('②推送并播放'),
                onPressed: _canSend ? () => _doBarrierPlay(state) : null,
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

  // ---- 本地上传(§20 A+B) ----
  Future<void> _pickAndUpload(WallState state, String type) async {
    final result = await FilePicker.platform.pickFiles(
      type: type == 'image' ? FileType.image : FileType.video,
      allowMultiple: true,
      withData: false, // 用文件路径流式上传,避免大视频占内存
    );
    if (result == null || result.files.isEmpty) return;
    setState(() {
      _uploading = true;
      _uploadHint = '准备上传…';
    });
    try {
      for (final f in result.files) {
        final path = f.path;
        if (path == null) continue;
        final name = f.name;
        int? durationMs = type == 'image' ? 8000 : null;
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
        setState(() => _items.add(item));
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
    final durCtl = TextEditingController(text: type == 'image' ? '8000' : '');
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
              TextField(
                controller: durCtl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: isImage ? '停留时长 ms (必填)' : '时长 ms (可选)'),
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
    final dur = int.tryParse(durCtl.text.trim());
    if (isImage && (dur == null || dur <= 0)) {
      _toast('图片必须设有效停留时长');
      return;
    }
    setState(() {
      _items.add(MediaItem(
        itemId: uuid4().substring(0, 8),
        type: isImage ? 'image' : 'video',
        name: name,
        url: url,
        durationMs: dur,
      ));
    });
  }

  void _doPrefetch(WallState state) {
    final pid = _newPlaylistId();
    state.sendPlaylist(
      playlistId: pid,
      groupId: _groupId!,
      sync: _sync,
      loop: _loop,
      items: _items,
    );
    state.cachePrefetch(_items, groupId: _groupId);
    _toast('已下发列表 + 预缓存 (${_items.length} 项)');
  }

  void _doBarrierPlay(WallState state) {
    final pid = _newPlaylistId();
    state.sendPlaylist(
      playlistId: pid,
      groupId: _groupId!,
      sync: _sync,
      loop: _loop,
      items: _items,
    );
    state.cachePrefetch(_items, groupId: _groupId);
    // §21 栅栏:等全员 cache=ready 才统一起播。
    state.prepareWithBarrier(playlistId: pid, groupId: _groupId!);
    _toast(_sync ? '已发起同步起播(等全员就绪)' : '已发起播放');
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
          _ctlBtn(Icons.pause, '暂停', g == null ? null : () => state.pause(groupId: g)),
          _ctlBtn(Icons.play_arrow, '恢复', g == null ? null : () => state.resume(groupId: g)),
          _ctlBtn(Icons.stop, '停止', g == null ? null : () => state.stop(groupId: g)),
          _ctlBtn(Icons.skip_previous, '上一项', g == null ? null : () => state.prev(groupId: g)),
          _ctlBtn(Icons.skip_next, '下一项', g == null ? null : () => state.next(groupId: g)),
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
            onChanged: g == null ? null : (v) => state.setVolume(v, groupId: g),
          ),
          Row(
            children: [
              _ctlBtn(Icons.volume_off, '静音', g == null ? null : () => state.setMute(true, groupId: g)),
              const SizedBox(width: 8),
              _ctlBtn(Icons.volume_up, '取消静音', g == null ? null : () => state.setMute(false, groupId: g)),
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
                state.setAudioMaster(groupId: g!.groupId, deviceIds: ids);
                _toast('已指定出声台 ${ids.length} 台');
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
