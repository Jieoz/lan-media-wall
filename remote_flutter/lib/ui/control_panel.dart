import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../protocol/envelope.dart';
import '../protocol/messages.dart';
import '../state/wall_state.dart';

/// 控制面板：选 group、编辑 playlist、cache_prefetch、一键同步播放，以及
/// pause/resume/stop/next/prev/音量/静音/出声台/分组等控制(§6/§9)。
class ControlPanel extends StatefulWidget {
  const ControlPanel({super.key});

  @override
  State<ControlPanel> createState() => _ControlPanelState();
}

class _ControlPanelState extends State<ControlPanel> {
  String? _groupId;
  bool _sync = true;
  bool _loop = true;
  final List<MediaItem> _items = [];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WallState>();
    final groups = state.groups;
    // 维持选中组有效
    if (_groupId != null && state.groupById(_groupId!) == null) {
      _groupId = null;
    }
    _groupId ??= groups.isNotEmpty ? groups.first.groupId : null;

    return Scaffold(
      appBar: AppBar(title: const Text('控制')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _groupSelector(state, groups),
          const SizedBox(height: 16),
          _playlistEditor(state),
          const SizedBox(height: 16),
          _transportControls(state),
          const SizedBox(height: 16),
          _volumeControls(state),
          const SizedBox(height: 16),
          _audioMasterControls(state),
          const SizedBox(height: 16),
          _assignGroupControls(state),
        ],
      ),
    );
  }

  WallGroup? get _group =>
      _groupId == null ? null : context.read<WallState>().groupById(_groupId!);

  // ---- 组选择 ----
  Widget _groupSelector(WallState state, List<WallGroup> groups) {
    return _Section(
      title: '目标分组',
      child: groups.isEmpty
          ? const Text('暂无分组(等待设备墙快照)')
          : DropdownButton<String>(
              isExpanded: true,
              value: _groupId,
              items: [
                for (final g in groups)
                  DropdownMenuItem(
                    value: g.groupId,
                    child: Text(
                        '${g.name.isEmpty ? g.groupId : g.name}  ·  ${g.members.length}台  ·  ${g.sync ? "同步" : "各播各的"}'),
                  ),
              ],
              onChanged: (v) => setState(() => _groupId = v),
            ),
    );
  }

  // ---- playlist 编辑 ----
  Widget _playlistEditor(WallState state) {
    return _Section(
      title: '播放列表 (${_items.length} 项)',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '加视频',
            icon: const Icon(Icons.movie),
            onPressed: () => _addItemDialog('video'),
          ),
          IconButton(
            tooltip: '加图片',
            icon: const Icon(Icons.image),
            onPressed: () => _addItemDialog('image'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('单文件=1 项；轮播=多项。图片需设停留时长。'),
            )
          else
            ...List.generate(_items.length, (i) {
              final it = _items[i];
              return ListTile(
                dense: true,
                leading: Icon(it.isImage ? Icons.image : Icons.movie),
                title: Text(it.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(it.isImage
                    ? '图片 · ${it.durationMs ?? 0}ms'
                    : '视频${it.durationMs != null ? " · ${it.durationMs}ms" : ""}'),
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
                  title: const Text('组内同步 sync'),
                  value: _sync,
                  onChanged: (v) => setState(() => _sync = v),
                ),
              ),
              Expanded(
                child: SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('循环 loop'),
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
                label: const Text('预缓存'),
                onPressed: _items.isEmpty ? null : () => _doPrefetch(state),
              ),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.playlist_add_check),
                label: const Text('下发列表'),
                onPressed:
                    _canSend ? () => _doSendPlaylist(state) : null,
              ),
              FilledButton.icon(
                icon: const Icon(Icons.play_circle),
                label: const Text('一键同步播放'),
                onPressed: _canSend ? () => _doSyncPlay(state) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool get _canSend => _groupId != null && _items.isNotEmpty;

  String _newPlaylistId() => 'pl-${_groupId ?? "g"}-${uuid4().substring(0, 6)}';

  void _doPrefetch(WallState state) {
    state.cachePrefetch(_items, groupId: _groupId);
    _toast('已下发 cache_prefetch (${_items.length} 项)');
  }

  void _doSendPlaylist(WallState state) {
    state.sendPlaylist(
      playlistId: _newPlaylistId(),
      groupId: _groupId!,
      sync: _sync,
      loop: _loop,
      items: _items,
    );
    _toast('已下发 playlist');
  }

  void _doSyncPlay(WallState state) {
    final pid = _newPlaylistId();
    // 先下发列表(携带 sync 标志)，再走 §9.1 prepare → broker 收齐 ready 后 play_at。
    state.sendPlaylist(
      playlistId: pid,
      groupId: _groupId!,
      sync: _sync,
      loop: _loop,
      items: _items,
    );
    state.prepare(playlistId: pid, groupId: _groupId!);
    _toast(_sync ? '已发 prepare(同步起播)' : '已发 prepare(各播各的)');
  }

  Future<void> _addItemDialog(String type) async {
    final nameCtl = TextEditingController();
    final urlCtl = TextEditingController();
    final durCtl = TextEditingController(text: type == 'image' ? '8000' : '');
    final isImage = type == 'image';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isImage ? '添加图片' : '添加视频'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(labelText: '名称 name'),
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
                labelText: isImage ? '停留时长 duration_ms (必填)' : '时长 duration_ms (可选)',
              ),
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
    );
    if (ok != true) return;
    if (!mounted) return;
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
        type: type,
        name: name,
        url: url,
        durationMs: dur,
      ));
    });
  }

  // ---- 传输控制(组) ----
  Widget _transportControls(WallState state) {
    final g = _groupId;
    return _Section(
      title: '播放控制 (整组)',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _ctlBtn(Icons.pause, '暂停',
              g == null ? null : () => state.pause(groupId: g)),
          _ctlBtn(Icons.play_arrow, '恢复',
              g == null ? null : () => state.resume(groupId: g)),
          _ctlBtn(Icons.stop, '停止',
              g == null ? null : () => state.stop(groupId: g)),
          _ctlBtn(Icons.skip_previous, '上一项',
              g == null ? null : () => state.prev(groupId: g)),
          _ctlBtn(Icons.skip_next, '下一项',
              g == null ? null : () => state.next(groupId: g)),
        ],
      ),
    );
  }

  // ---- 音量 / 静音 ----
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
                : (v) => state.setVolume(v, groupId: g),
          ),
          Row(
            children: [
              _ctlBtn(Icons.volume_off, '静音',
                  g == null ? null : () => state.setMute(true, groupId: g)),
              const SizedBox(width: 8),
              _ctlBtn(Icons.volume_up, '取消静音',
                  g == null ? null : () => state.setMute(false, groupId: g)),
            ],
          ),
        ],
      ),
    );
  }

  // ---- set_audio_master(多选出声台) ----
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

  // ---- assign_group(单机改组) ----
  Widget _assignGroupControls(WallState state) {
    return _Section(
      title: '改设备分组 assign_group',
      child: _AssignGroupPicker(
        devices: state.devices,
        groups: state.groups,
        onApply: (deviceId, groupId) {
          state.assignGroup(deviceId: deviceId, groupId: groupId);
          _toast('已把 $deviceId 移到 $groupId');
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

/// 卡片式分区。
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

/// 组音量滑杆(松手才发命令，避免刷屏)。
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
            onChangeEnd: widget.onChanged == null
                ? null
                : (v) => widget.onChanged!(v.round()),
          ),
        ),
        SizedBox(
            width: 36,
            child: Text('${_v.round()}', textAlign: TextAlign.end)),
      ],
    );
  }
}

/// 出声台多选(默认沿用各机当前 audio_master 状态)。
class _AudioMasterPicker extends StatefulWidget {
  const _AudioMasterPicker({required this.members, required this.onApply});
  final List<DeviceStatus> members;
  final void Function(List<String> deviceIds) onApply;

  @override
  State<_AudioMasterPicker> createState() => _AudioMasterPickerState();
}

class _AudioMasterPickerState extends State<_AudioMasterPicker> {
  late Set<String> _selected = {
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

/// 选一台设备 + 目标组 → assign_group。
class _AssignGroupPicker extends StatefulWidget {
  const _AssignGroupPicker({
    required this.devices,
    required this.groups,
    required this.onApply,
  });
  final List<DeviceStatus> devices;
  final List<WallGroup> groups;
  final void Function(String deviceId, String groupId) onApply;

  @override
  State<_AssignGroupPicker> createState() => _AssignGroupPickerState();
}

class _AssignGroupPickerState extends State<_AssignGroupPicker> {
  String? _deviceId;
  String? _groupId;

  @override
  Widget build(BuildContext context) {
    if (widget.devices.isEmpty) {
      return const Text('暂无设备');
    }
    final deviceIds = widget.devices.map((d) => d.deviceId).toSet();
    if (_deviceId != null && !deviceIds.contains(_deviceId)) _deviceId = null;
    final groupIds = widget.groups.map((g) => g.groupId).toSet();
    if (_groupId != null && !groupIds.contains(_groupId)) _groupId = null;
    return Column(
      children: [
        DropdownButton<String>(
          isExpanded: true,
          hint: const Text('选择设备'),
          value: _deviceId,
          items: [
            for (final d in widget.devices)
              DropdownMenuItem(
                  value: d.deviceId,
                  child: Text(d.deviceName ?? d.deviceId)),
          ],
          onChanged: (v) => setState(() => _deviceId = v),
        ),
        DropdownButton<String>(
          isExpanded: true,
          hint: const Text('目标分组'),
          value: _groupId,
          items: [
            for (final g in widget.groups)
              DropdownMenuItem(
                  value: g.groupId,
                  child: Text(g.name.isEmpty ? g.groupId : g.name)),
          ],
          onChanged: (v) => setState(() => _groupId = v),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonal(
            onPressed: (_deviceId != null && _groupId != null)
                ? () => widget.onApply(_deviceId!, _groupId!)
                : null,
            child: const Text('改组'),
          ),
        ),
      ],
    );
  }
}
