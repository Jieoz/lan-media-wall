import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../protocol/auth_mode.dart';
import '../protocol/messages.dart';
import '../state/wall_state.dart';
import 'cache_management.dart';
import 'device_wall_filter.dart';
import 'device_wall_layout.dart';
import 'invite_screen.dart';
import 'music_terminal_dialog.dart';
import 'push_workflow.dart';


/// 设备墙栏(设计合同 §4.1 左栏) —— 控制端常驻主视图。
///
/// 组织:发现/添加动作条 → 分组筛选/管理 → 设备卡列表。
/// 每张设备卡显示缩略图/名/组/在线相位/缓存态,并提供「配置盒子」(改名/设组/音量)。
///
/// 点分组 chip = **筛选设备墙**;编辑按钮才改组名。筛选态只活在本 pane,
/// 不污染编排页目标,避免误伤整组推送。
class DeviceWallPane extends StatefulWidget {
  const DeviceWallPane({super.key});

  @override
  State<DeviceWallPane> createState() => _DeviceWallPaneState();
}

class _DeviceWallPaneState extends State<DeviceWallPane> {
  /// null / [DeviceWallFilter.all] = 显示全部;否则只显示该 groupId。
  String? _filterGroupId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WallState>();
    final devices = state.wallDevices;
    final groups = state.groups;
    // 若筛选组已被删除,回退到全部。
    if (_filterGroupId != null &&
        !DeviceWallFilter.isAll(_filterGroupId) &&
        !groups.any((g) => g.groupId == _filterGroupId)) {
      _filterGroupId = null;
    }
    final visible = DeviceWallFilter.apply(
      devices,
      filterGroupId: _filterGroupId,
      groupOf: (d) => d.status?.groupId,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ActionsBar(state: state),
        const Divider(height: 1),
        Expanded(
          child: devices.isEmpty
              ? _EmptyHint(state: state)
              : ListView(
                  padding: const EdgeInsets.all(8),
                  children: [
                    _GroupsHeader(
                      state: state,
                      groups: groups,
                      filterGroupId: _filterGroupId,
                      onFilterChanged: (id) =>
                          setState(() => _filterGroupId = id),
                    ),
                    const SizedBox(height: 4),
                    if (visible.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          DeviceWallFilter.isAll(_filterGroupId)
                              ? '暂无设备'
                              : '该分组当前没有可见设备 · 点「全部」看整墙',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      )
                    else
                      for (final d in visible)
                        _DeviceCard(state: state, device: d, groups: groups),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ActionsBar extends StatelessWidget {
  const _ActionsBar({required this.state});
  final WallState state;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final compact = DeviceWallLayout.compactActions(constraints.maxWidth);
      return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
              icon: const Icon(Icons.add_link),
              label: Text(compact ? '添加' : '添加设备'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxWidth: 560, maxHeight: 720),
                    child: const InviteScreen(),
                  ),
                ),
              ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(compact ? '分组' : '新建组'),
              onPressed: () => _createGroupDialog(context, state),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.system_update_alt),
              label: Text(compact ? '升级' : '推送升级'),
              onPressed: () => _remoteUpdateDialog(context, state),
            )),
          ]),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.power_settings_new),
            label: Text(compact ? '待机/恢复' : '分组 / 全部待机与恢复'),
            onPressed: () => _runtimeModeBatchDialog(context, state),
          ),
        ],
      ),
    );
    });
  }
}

Future<void> _runtimeModeBatchDialog(
    BuildContext context, WallState state) async {
  var target = 'all';
  var busy = false;
  var output = '';
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('分组 / 全部待机与恢复'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                value: target,
                decoration: const InputDecoration(labelText: '目标范围'),
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('全部设备')),
                  for (final group in state.groups)
                    DropdownMenuItem(
                      value: 'group:${group.groupId}',
                      child: Text('分组：${group.name.isEmpty ? group.groupId : group.name}'),
                    ),
                ],
                onChanged: busy ? null : (value) =>
                    setLocal(() => target = value ?? 'all'),
              ),
              const SizedBox(height: 8),
              const Text('逐台发送并等待 Player 结果；离线、旧版本、超时和拒绝会分别列出。'),
              if (output.isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(child: SelectableText(output)),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('关闭')),
          OutlinedButton(
            onPressed: busy ? null : () async {
              final ids = target == 'all'
                  ? state.devices.map((d) => d.deviceId)
                  : state.membersOf(target.substring('group:'.length))
                      .map((d) => d.deviceId);
              setLocal(() { busy = true; output = '等待逐台确认…'; });
              final results = await state.restoreDevicesRuntimeMode(ids);
              setLocal(() {
                busy = false;
                output = results.entries.map((entry) {
                  final r = entry.value;
                  return '${entry.key}: ${r.ok ? '已恢复 ${r.mode?.name ?? ''}' : '失败 ${r.error}'}';
                }).join('\n');
              });
            },
            child: const Text('恢复前态'),
          ),
          FilledButton(
            onPressed: busy ? null : () async {
              final ids = target == 'all'
                  ? state.devices.map((d) => d.deviceId)
                  : state.membersOf(target.substring('group:'.length))
                      .map((d) => d.deviceId);
              setLocal(() { busy = true; output = '等待逐台确认…'; });
              final results = await state.setDevicesRuntimeMode(
                  ids, RuntimeMode.standby);
              setLocal(() {
                busy = false;
                output = results.entries.map((entry) {
                  final r = entry.value;
                  return '${entry.key}: ${r.ok && r.mode == RuntimeMode.standby ? '已进入待机' : '失败 ${r.error}'}';
                }).join('\n');
              });
            },
            child: const Text('进入待机'),
          ),
        ],
      ),
    ),
  );
}

/// §23 远程自更新:选 APK → 暴露为被控端可 GET 的 URL(得 sha256) → 填目标
/// versionCode + 目标(某台/某组/全部) → 下发 update_app。被控端四护栏二次校验才装。
///
/// [lockDevice] 非空时(从单设备详情弹窗「推送升级」入口进入):目标预锁定为该台
/// (targetKind='device'、targetDeviceId=该 device.deviceId),且隐藏目标类型选择器,
/// 只给这一台推。为空(顶部整墙入口)时保持原行为:默认 all、可自由选 全部/组/单台。
Future<void> _remoteUpdateDialog(BuildContext context, WallState state,
    {WallDevice? lockDevice}) async {
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['apk'],
    withData: false,
  );
  final path = picked?.files.single.path;
  if (path == null) return;
  final apk = File(path);

  // The target itself is never typed: uploadApkForUpdate reads it from manifest.
  final lockedStatus = lockDevice?.status;
  final knownVersionCode = lockedStatus?.updateVersionCode;
  final groups = state.groups;
  final devices = state.wallDevices;
  // lockDevice 非空 → 预锁定到该台;否则整墙入口默认 all。
  var targetKind = lockDevice != null ? 'device' : 'all';
  String? targetGroupId = groups.isEmpty ? null : groups.first.groupId;
  String? targetDeviceId = lockDevice?.deviceId ??
      (devices.isEmpty ? null : devices.first.deviceId);
  var uploading = false;
  String? uploadedUrl, uploadedSha;

  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('远程更新固件'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('APK:${apk.uri.pathSegments.last}',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              const Text('目标版本将从 APK manifest 自动读取，禁止手填。',
                  style: TextStyle(fontSize: 12, color: Colors.blueGrey)),
              if (knownVersionCode != null) ...[
                const SizedBox(height: 4),
                Text('该台当前 versionCode：$knownVersionCode（APK 必须严格更大）',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.blueGrey)),
              ],
              const SizedBox(height: 8),
              // 单设备入口:目标已锁定为该台,不再给目标类型选择器(只显示锁定提示)。
              if (lockDevice != null)
                Text(
                  '目标:${lockDevice.deviceName.isEmpty ? lockDevice.deviceId : lockDevice.deviceName}（已锁定这一台）',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                )
              else
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: targetKind,
                  decoration: const InputDecoration(labelText: '目标类型'),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('全部设备')),
                    DropdownMenuItem(value: 'group', child: Text('指定分组')),
                    DropdownMenuItem(value: 'device', child: Text('指定单台')),
                  ],
                  onChanged: (v) => setLocal(() => targetKind = v ?? 'all'),
                ),
              if (lockDevice == null && targetKind == 'group') ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: targetGroupId,
                  decoration: const InputDecoration(labelText: '分组'),
                  items: [
                    for (final g in groups)
                      DropdownMenuItem(
                          value: g.groupId,
                          child: Text('组:${g.name.isEmpty ? g.groupId : g.name}')),
                  ],
                  onChanged: (v) => setLocal(() => targetGroupId = v),
                ),
              ],
              if (lockDevice == null && targetKind == 'device') ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: targetDeviceId,
                  decoration: const InputDecoration(labelText: '单台设备'),
                  items: [
                    for (final d in devices)
                      DropdownMenuItem(
                          value: d.deviceId,
                          child: Text(d.deviceName.isEmpty
                              ? d.deviceId
                              : '${d.deviceName} (${d.deviceId})')),
                  ],
                  onChanged: (v) => setLocal(() => targetDeviceId = v),
                ),
              ],
              const SizedBox(height: 12),
              if (uploadedUrl != null)
                Text('已上传 ✓ sha256:${uploadedSha!.substring(0, 12)}…',
                    style: const TextStyle(color: Colors.green, fontSize: 12))
              else
                Text(
                  uploading ? '准备中…' : '点「准备并下发」生成 APK 下载地址，再下发更新指令',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: uploading ? null : () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: uploading
                ? null
                : () async {

                    final groupId = targetKind == 'group' ? targetGroupId : null;
                    final deviceId = targetKind == 'device' ? targetDeviceId : null;
                    if (targetKind == 'group' && groupId == null) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('没有可选分组')));
                      return;
                    }
                    if (targetKind == 'device' && deviceId == null) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text('没有可选设备')));
                      return;
                    }
                    setLocal(() => uploading = true);
                    try {
                      final r = await state.uploadApkForUpdate(apk: apk);
                      if (knownVersionCode != null &&
                          r.versionCode <= knownVersionCode) {
                        throw StateError(
                            'APK versionCode ${r.versionCode} 必须严格大于该台当前 $knownVersionCode');
                      }
                      uploadedUrl = r.url;
                      uploadedSha = r.sha256;
                      state.updateApp(
                        url: r.url,
                        versionCode: r.versionCode,
                        sha256: r.sha256,
                        versionName: r.versionName,
                        groupId: groupId,
                        deviceId: deviceId,
                      );
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } catch (e) {
                      setLocal(() => uploading = false);
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text('更新失败:$e')));
                      }
                    }
                  },
            child: const Text('准备并下发'),
          ),
        ],
      ),
    ),
  );
  if (ok == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已下发更新指令;被控端校验通过后将下载→安装。'
            '正常仅重启 App;个别老机型（legacy）可能整机重启，Wi-Fi 会短暂中断后自恢复')));
  }
}

/// 分组筛选/管理头。
///
/// - 点 chip = **筛选设备墙**(「全部」或某组)
/// - 下方编辑按钮 = 改组名/同步
/// - chip 删除 = 删组(default 不可删)
class _GroupsHeader extends StatelessWidget {
  const _GroupsHeader({
    required this.state,
    required this.groups,
    required this.filterGroupId,
    required this.onFilterChanged,
  });
  final WallState state;
  final List<WallGroup> groups;
  final String? filterGroupId;
  final ValueChanged<String?> onFilterChanged;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('暂无分组 · 点「新建组」创建第一个', style: TextStyle(fontSize: 12)),
      );
    }
    final filterAll = DeviceWallFilter.isAll(filterGroupId);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              filterAll
                  ? '分组筛选 · 全部 (${groups.length} 组)'
                  : '分组筛选 · 仅看选中组',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 2),
            Text('点 chip 筛选墙面 · 点 ✎ 改组名',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                FilterChip(
                  label: const Text('全部'),
                  selected: filterAll,
                  onSelected: (_) => onFilterChanged(null),
                ),
                for (final g in groups)
                  InputChip(
                    selected: !filterAll && filterGroupId == g.groupId,
                    label: Text(
                        '${g.name.isEmpty ? g.groupId : g.name} · ${g.members.length}台'),
                    avatar: Icon(
                        g.sync ? Icons.sync : Icons.sync_disabled,
                        size: 16),
                    onPressed: () => onFilterChanged(
                      filterGroupId == g.groupId ? null : g.groupId,
                    ),
                    onDeleted: g.groupId == 'default'
                        ? null
                        : () => _confirmDeleteGroup(context, state, g),
                    deleteIcon: g.groupId == 'default'
                        ? null
                        : const Icon(Icons.close, size: 16),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final g in groups)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    icon: const Icon(Icons.edit_outlined, size: 14),
                    label: Text(
                      g.name.isEmpty ? g.groupId : g.name,
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () => _editGroupDialog(context, state, g),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 单台设备卡:缩略图 + 名/组/相位/缓存态 + 配置入口。
class _DeviceCard extends StatelessWidget {
  const _DeviceCard(
      {required this.state, required this.device, required this.groups});
  final WallState state;
  final WallDevice device;
  final List<WallGroup> groups;

  @override
  Widget build(BuildContext context) {
    final thumb = state.thumbOf(device.deviceId);
    final st = device.status;
    final (phaseColor, phaseText) = switch (device.phase) {
      LinkPhase.connected => (Colors.green, '已连接'),
      LinkPhase.connecting => (Colors.orange, '连接中'),
      LinkPhase.discovered => (Colors.blueGrey, '已发现'),
      LinkPhase.failed => (Colors.red, '失败'),
    };
    final cacheSummary = _cacheSummary(st);

    return Card(
      child: InkWell(
        onTap: () => _configureDeviceDialog(context, state, device, groups),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              // 缩略图预览(设备墙 §6.4);无图时占位。
              Container(
                width: 72,
                height: 48,
                color: Colors.black26,
                child: thumb != null
                    ? Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true)
                    : const Icon(Icons.tv, size: 24),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.deviceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.circle, size: 8, color: phaseColor),
                        const SizedBox(width: 4),
                        Text(phaseText,
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(width: 8),
                        if (st != null)
                          Flexible(
                            child: Text('组:${st.groupId} · $cacheSummary',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall),
                          ),
                        if (device.ip.isNotEmpty)
                          Text('IP ${device.ip}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                    if (device.error != null)
                      Text(device.error!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.error)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  String _cacheSummary(DeviceStatus? st) {
    if (st == null || st.cache.isEmpty) return '缓存 —';
    final total = st.cache.length;
    final ready = st.cache.values.where((v) => v == 'ready').length;
    return '缓存 $ready/$total';
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.state});
  final WallState state;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tv_off, size: 48, color: Colors.white38),
            const SizedBox(height: 12),
            const Text('暂未发现设备',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              '控制端正在周期广播发现。确保盒子与本机同网段,\n'
              '或点上方「添加设备」扫码/手填 IP。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('立即刷新发现'),
              onPressed: state.refreshDiscovery,
            ),
          ],
        ),
      ),
    );
  }
}

// ---- 对话框:新建组 / 改组 / 删组 / 配置盒子 ----

void _showCommandFailure(BuildContext context, String action, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text('$action失败: $error')));
}

Future<void> _createGroupDialog(BuildContext context, WallState state) async {
  final idCtl = TextEditingController();
  final nameCtl = TextEditingController();
  var sync = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('新建分组'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idCtl,
              decoration: const InputDecoration(
                labelText: '组 id (英文/数字,如 hall-2)',
                hintText: '稳定标识,建议 ASCII',
              ),
            ),
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(labelText: '显示名 (如 二号厅)'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('组内同步播放'),
              value: sync,
              onChanged: (v) => setLocal(() => sync = v),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('创建')),
        ],
      ),
    ),
  );
  if (ok != true) return;
  final gid = idCtl.text.trim();
  if (gid.isEmpty) return;
  try {
    state.createGroup(
      groupId: gid,
      name: nameCtl.text.trim().isEmpty ? null : nameCtl.text.trim(),
      sync: sync,
    );
  } catch (e) {
    _showCommandFailure(context, '新建分组', e);
  }
}

Future<void> _editGroupDialog(
    BuildContext context, WallState state, WallGroup g) async {
  final nameCtl = TextEditingController(text: g.name);
  var sync = g.sync;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text('分组 ${g.groupId}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(labelText: '显示名'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('组内同步播放'),
              value: sync,
              onChanged: (v) => setLocal(() => sync = v),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    ),
  );
  if (ok != true) return;
  try {
    state.updateGroup(
      groupId: g.groupId,
      name: nameCtl.text.trim(),
      sync: sync,
    );
  } catch (e) {
    _showCommandFailure(context, '保存分组', e);
  }
}

Future<void> _confirmDeleteGroup(
    BuildContext context, WallState state, WallGroup g) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('删除分组「${g.name.isEmpty ? g.groupId : g.name}」?'),
      content: Text('组内 ${g.members.length} 台设备将回落到 default 组。此操作可通过重新建组恢复。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    state.deleteGroup(groupId: g.groupId);
  } catch (e) {
    _showCommandFailure(context, '删除分组', e);
  }
}

/// 单台面板(§v1.13):一处集中该 deviceId 的 状态/版本 展示、播放控制(暂停/恢复/
/// 停止/上一项/下一项)、重启设备(§9.4,二次确认)、单播推送内容(§9.4b)、单台
/// 推送升级(§23),外加原有的 改名/设组/音量/连接(§19 configure_device)。
///
/// 「应用」提交改名/设组/音量,可选一并推送连接;播放控制与重启是即时动作,
/// 推送内容/升级会先关本弹窗再在父 context 打开各自的流程弹窗。
Future<void> _configureDeviceDialog(BuildContext context, WallState state,
    WallDevice device, List<WallGroup> groups) async {
  final nameCtl = TextEditingController(text: device.deviceName);
  final brokerHostCtl = TextEditingController();
  final brokerPortCtl = TextEditingController(text: '8770');
  final pskCtl = TextEditingController();
  final st = device.status;
  var groupId = st?.groupId ?? '';
  final revision = st?.configSnapshot?.revision;
  final snapshot = st?.configSnapshot;
  final snapshotValues = <String, dynamic>{
    if (snapshot?.deviceName != null) 'device_name': snapshot!.deviceName,
    if (snapshot?.groupId != null) 'group_id': snapshot!.groupId,
    'volume': snapshot?.volume,
    'muted': snapshot?.muted,
  };
  var volume = ((snapshotValues['volume'] as num?)?.toDouble() ?? (st?.volume ?? 80).toDouble());
  var muted = snapshotValues['muted'] == true;
  var useWss = false;
  var pushTransport = false;
  var clearBroker = false;
  final canPushPsk = state.authMode != AuthMode.open;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(device.deviceName.isEmpty
            ? '单台面板 · ${device.deviceId}'
            : '单台面板 · ${device.deviceName}'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DeviceStatusView(device: device),
                const Divider(height: 20),
                // 播放控制(即时下发,单播这一台)。
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('播放控制',
                      style: Theme.of(ctx).textTheme.labelLarge),
                ),
                const SizedBox(height: 6),
                _DeviceTransportRow(state: state, deviceId: device.deviceId),
                const SizedBox(height: 12),
                // §19 改名/设组/音量(「应用」时统一提交)。
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('设备配置',
                      style: Theme.of(ctx).textTheme.labelLarge),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(labelText: '设备显示名'),
                ),
                const SizedBox(height: 8),
                if (groups.isNotEmpty)
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: groups.any((g) => g.groupId == groupId)
                        ? groupId
                        : null,
                    decoration: const InputDecoration(labelText: '分组'),
                    items: [
                      for (final g in groups)
                        DropdownMenuItem(
                            value: g.groupId,
                            child: Text(g.name.isEmpty ? g.groupId : g.name)),
                    ],
                    onChanged: (v) => setLocal(() => groupId = v ?? groupId),
                  ),
                Row(
                  children: [
                    const Icon(Icons.volume_up, size: 18),
                    Expanded(
                      child: Slider(
                        value: volume,
                        min: 0,
                        max: 100,
                        divisions: 100,
                        label: volume.round().toString(),
                        onChanged: (v) => setLocal(() => volume = v),
                      ),
                    ),
                    SizedBox(width: 32, child: Text('${volume.round()}')),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('静音'),
                  value: muted,
                  onChanged: (v) => setLocal(() => muted = v),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('点「应用配置」后等待播放端确认',
                      style: Theme.of(ctx).textTheme.bodySmall),
                ),
                const Divider(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('连接 / 中枢',
                      style: Theme.of(ctx).textTheme.labelLarge),
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('推送播放端连接配置'),
                  subtitle: const Text(
                      '独立连接命令会重建 transport；切 host 会短暂断链'),
                  value: pushTransport,
                  onChanged: (v) => setLocal(() {
                    pushTransport = v;
                    if (!v) clearBroker = false;
                  }),
                ),
                if (pushTransport) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('清空 broker，回发现/P2P'),
                    value: clearBroker,
                    onChanged: (v) => setLocal(() => clearBroker = v),
                  ),
                  if (!clearBroker) ...[
                    TextField(
                      controller: brokerHostCtl,
                      decoration: const InputDecoration(
                        labelText: 'Broker 主机',
                        hintText: '如 192.168.1.10',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: brokerPortCtl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Broker 端口',
                        hintText: '8770',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('使用 WSS'),
                      value: useWss,
                      onChanged: (v) => setLocal(() => useWss = v),
                    ),
                  ],
                  TextField(
                    controller: pskCtl,
                    obscureText: true,
                    enabled: canPushPsk,
                    decoration: InputDecoration(
                      labelText: canPushPsk ? 'PSK（留空则不下发）' : 'PSK（当前 open 链路不可改）',
                      helperText: canPushPsk
                          ? '仅鉴权链路可改；播放端仍校验 env.authed'
                          : 'open 模式禁止远程改密钥',
                    ),
                  ),
                ],
                const Divider(height: 20),
                // 分层：常用 → 维护 → 危险。即时动作先关弹窗再走流程。
                Text('常用', style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.playlist_play),
                      label: const Text('推送内容'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        showPushToDeviceDialog(context, state, device);
                      },
                    ),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.library_music),
                      label: const Text('音乐终端'),
                      onPressed: st?.supportsMusicShuffle == true
                          ? () {
                              Navigator.pop(ctx);
                              showMusicTerminalDialog(context, state, device);
                            }
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('维护', style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.sd_storage),
                      label: const Text('缓存管理'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        showCacheManagementDialog(context, state, device);
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.system_update_alt),
                      label: const Text('推送升级'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _remoteUpdateDialog(context, state, lockDevice: device);
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('下载日志'),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        try {
                          final f = await state.downloadPlayerLogs(deviceId: device.deviceId);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context)
                              ..clearSnackBars()
                              ..showSnackBar(SnackBar(content: Text('日志已保存到 ${f.path}')));
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context)
                              ..clearSnackBars()
                              ..showSnackBar(SnackBar(content: Text('下载日志失败: $e')));
                          }
                        }
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.bug_report_outlined),
                      label: const Text('调试快照'),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        try {
                          final text = await state.requestDebugSnapshot(deviceId: device.deviceId);
                          if (context.mounted) {
                            await _showCopyableDebugSnapshot(context, device, text);
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context)
                              ..clearSnackBars()
                              ..showSnackBar(SnackBar(content: Text('调试快照失败: $e')));
                          }
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('危险操作',
                    style: Theme.of(ctx)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: Colors.red.shade700)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.orange),
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('重启播放 App'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _confirmRestartApp(context, state, device);
                      },
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red),
                      icon: const Icon(Icons.power_settings_new),
                      label: const Text('重启整机(高危)'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _confirmRebootDevice(context, state, device);
                      },
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('从控制端移除'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _confirmForgetDevice(context, state, device);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('应用配置')),
        ],
      ),
    ),
  );
  if (ok != true) return;

  String? brokerHost;
  int? brokerPort;
  bool? useWssOut;
  String? pskOut;
  var clearBrokerOut = false;
  if (pushTransport) {
    if (clearBroker) {
      clearBrokerOut = true;
    } else {
      brokerHost = brokerHostCtl.text.trim();
      if (brokerHost.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(const SnackBar(
                content: Text('推送连接时请填写 Broker 主机，或勾选清空回发现/P2P')));
        }
        return;
      }
      final port = int.tryParse(brokerPortCtl.text.trim());
      if (port == null || port < 1 || port > 65535) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(const SnackBar(content: Text('Broker 端口须为 1–65535')));
        }
        return;
      }
      brokerPort = port;
      useWssOut = useWss;
    }
    final pskText = pskCtl.text;
    if (pskText.isNotEmpty) {
      if (!canPushPsk) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(const SnackBar(content: Text('当前 open 链路禁止远程改 PSK')));
        }
        return;
      }
      pskOut = pskText;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认推送连接配置？'),
        content: Text(clearBrokerOut
            ? '将清空该播放端 broker，并重建 transport 回发现/P2P。链路会短暂断开。'
            : '将把 broker=$brokerHost:$brokerPort'
                '${useWssOut == true ? " (WSS)" : ""}'
                '${pskOut != null ? " 并更新 PSK" : ""}'
                ' 写入该播放端并重建 transport。链路会短暂断开。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.orange),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认推送')),
        ],
      ),
    );
    if (confirm != true) return;
  }

  try {
    final configRequest = state.configureDevice(
      deviceId: device.deviceId,
      deviceName: nameCtl.text.trim().isEmpty ? null : nameCtl.text.trim(),
      groupId: groupId.isEmpty ? null : groupId,
      volume: volume.round(),
      muted: muted,
      baseRevision: revision,
    );
    if (pushTransport) {
      state.configureTransport(
        deviceId: device.deviceId,
        brokerHost: clearBrokerOut ? '' : brokerHost!,
        brokerPort: clearBrokerOut ? null : brokerPort,
        useWss: clearBrokerOut ? null : useWssOut,
      );
    }
    if (pskOut != null) state.rotateDeviceKey(deviceId: device.deviceId, psk: pskOut);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('配置已投递，等待播放端确认 ($configRequest)')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('配置失败: $e')));
    }
  }
}

/// 单台播放控制行(§9/§v1.13):暂停/恢复/停止/上一项/下一项,全部锁定该 deviceId 单播。
class _DeviceTransportRow extends StatelessWidget {
  const _DeviceTransportRow({required this.state, required this.deviceId});
  final WallState state;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    void act(void Function() fn, String toast) {
      try {
        fn();
      } catch (e) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text('操作失败: $e')));
        return;
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(toast)));
    }

    Widget btn(IconData icon, String label, void Function() onTap) =>
        OutlinedButton.icon(
          icon: Icon(icon, size: 18),
          label: Text(label),
          onPressed: onTap,
        );

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // §D 措辞真相：下发即回执「命令已发送，等待设备确认」，绝不在 ACK 前声称
        // 已暂停/已恢复/已停止；真实播放态由设备回传的 wall 快照反映。
        btn(Icons.pause, '暂停',
            () => act(() => state.pause(deviceId: deviceId), sentAwaitingAck('暂停这一台'))),
        btn(Icons.play_arrow, '恢复',
            () => act(() => state.resume(deviceId: deviceId), sentAwaitingAck('恢复这一台'))),
        btn(Icons.stop, '停止',
            () => act(() => state.stop(deviceId: deviceId), sentAwaitingAck('停止这一台'))),
        btn(Icons.skip_previous, '上一项',
            () => act(() => state.prev(deviceId: deviceId), sentAwaitingAck('上一项'))),
        btn(Icons.skip_next, '下一项',
            () => act(() => state.next(deviceId: deviceId), sentAwaitingAck('下一项'))),
      ],
    );
  }
}

/// 从控制端忘记一台设备:清本机发现缓存/直连/状态卡,不卸载盒子端 App。
Future<void> _confirmForgetDevice(
    BuildContext context, WallState state, WallDevice device) async {
  final name = device.deviceName.isEmpty ? device.deviceId : device.deviceName;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('从控制端移除「$name」?'),
      content: const Text(
        '只会从这个控制端的设备列表/发现缓存里移除,不会卸载或停止盒子上的播放端。'
        '以后这台盒子重新广播、扫码或手动添加时还会回来。',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除')),
      ],
    ),
  );
  if (ok != true) return;
  await state.forgetDevice(device.deviceId);
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('已从控制端移除「$name」')));
  }
}


Future<void> _showCopyableDebugSnapshot(
  BuildContext context,
  WallDevice device,
  String text,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('调试快照 · ${device.deviceName.isEmpty ? device.deviceId : device.deviceName}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: SelectableText(text.isEmpty ? '(空快照)' : text),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('复制全部'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx)
                ..clearSnackBars()
                ..showSnackBar(const SnackBar(content: Text('调试快照已复制')));
            }
          },
        ),
      ],
    ),
  );
}

/// §9.4 只重启播放 App(安全)。经 root 守护进程 RESTART_APP:只 force-stop+拉起
/// 播放 App,保住 Wi-Fi 与整机 uptime,不整机重启。
Future<void> _confirmRestartApp(
    BuildContext context, WallState state, WallDevice device) async {
  final name = device.deviceName.isEmpty ? device.deviceId : device.deviceName;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('重启「$name」的播放 App?'),
      content: const Text(
        '只重启播放软件(不整机重启),Wi-Fi 与开机时长保持不变。当前播放会短暂中断,'
        '随后按 last_task 恢复上一个任务。',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重启 App')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    state.restart(deviceId: device.deviceId);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('已下发 App 重启指令给「$name」')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('重启失败: $e')));
    }
  }
}

/// §10 整机重启二次确认——高危。QZX_C1 warm reboot 会导致 SDIO Wi-Fi 卡初始化超时
/// (-110)、wlan0 消失且只有冷启动能恢复,故与 app-only 的「重启播放 App」严格区分,
/// 并明确警示网络中断风险。日常重启请优先用「重启播放 App」。
Future<void> _confirmRebootDevice(
    BuildContext context, WallState state, WallDevice device) async {
  final name = device.deviceName.isEmpty ? device.deviceId : device.deviceName;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('重启整台「$name」?(高危)'),
      content: const Text(
        '将重启整台盒子。⚠️ 部分 QZX_C1 盒子 warm reboot 后 Wi-Fi 无法自动恢复,'
        '可能需要现场断电冷启动才能重新联网。日常重启请改用「重启播放 App」。'
        '确认要整机重启吗?',
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认整机重启')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    state.reboot(deviceId: device.deviceId);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('已下发整机重启指令给「$name」')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('重启失败: $e')));
    }
  }
}

/// 单台 状态/版本 一览(§5.1):版本(appVersion)/在线相位/当前播放项/缓存态/组/
/// 音量/错误/last_seen,做成好读的一页。占位阶段(status==null)只显示相位与 IP。
class _DeviceStatusView extends StatelessWidget {
  const _DeviceStatusView({required this.device});
  final WallDevice device;

  @override
  Widget build(BuildContext context) {
    final st = device.status;
    final (phaseColor, phaseText) = switch (device.phase) {
      LinkPhase.connected => (Colors.green, '已连接'),
      LinkPhase.connecting => (Colors.orange, '连接中'),
      LinkPhase.discovered => (Colors.blueGrey, '已发现'),
      LinkPhase.failed => (Colors.red, '失败'),
    };
    final rows = <(String, String)>[
      ('设备 ID', device.deviceId),
      ('应用版本', st?.appVersion?.isNotEmpty == true ? st!.appVersion! : '—(未上报)'),
      ('分组', st?.groupId.isNotEmpty == true ? st!.groupId : '—'),
      ('播放态', st != null ? _stateLabel(st.state) : '—'),
      if (st?.current != null) ('当前项', st!.current!.name),
      ('音量', st != null ? '${st.volume}${st.muted ? " (静音)" : ""}' : '—'),
      ('缓存', _cacheLabel(st)),
      if (st != null && st.audioMaster) ('出声台', '是'),
      if (device.ip.isNotEmpty) ('IP', device.ip),
      ('最近在线', _lastSeenLabel(st?.lastSeen)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.circle, size: 10, color: phaseColor),
            const SizedBox(width: 6),
            Text(phaseText, style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            if (st?.appVersion?.isNotEmpty == true)
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text('v${st!.appVersion}',
                    style: const TextStyle(fontSize: 11)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 76,
                  child: Text(k,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).hintColor)),
                ),
                Expanded(
                  child: Text(v,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        if (st != null && st.errors.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('错误:${st.errors.join(" · ")}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).colorScheme.error)),
        ],
      ],
    );
  }

  static String _stateLabel(String s) => switch (s) {
        'playing' => '播放中',
        'paused' => '已暂停',
        'buffering' => '缓冲中',
        'downloading' => '下载中',
        'idle' => '空闲',
        _ => s,
      };

  static String _cacheLabel(DeviceStatus? st) {
    if (st == null || st.cache.isEmpty) return '—';
    final total = st.cache.length;
    final ready = st.cache.values.where((v) => v == 'ready').length;
    return '$ready/$total 就绪';
  }

  static String _lastSeenLabel(int? ms) {
    if (ms == null || ms <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final d = DateTime.now().difference(dt);
    if (d.inSeconds < 60) return '${d.inSeconds}s 前';
    if (d.inMinutes < 60) return '${d.inMinutes}m 前';
    if (d.inHours < 24) return '${d.inHours}h 前';
    return '${dt.year}-${dt.month.toString().padLeft(2, "0")}-${dt.day.toString().padLeft(2, "0")}';
  }
}
