import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../protocol/messages.dart';
import '../state/wall_state.dart';
import 'invite_screen.dart';

/// 设备墙栏(设计合同 §4.1 左栏) —— 控制端常驻主视图。
///
/// 组织:发现/添加动作条 → 分组管理入口 → 设备卡列表(按组分区)。
/// 每张设备卡显示缩略图/名/组/在线相位/缓存态,并提供「配置盒子」(改名/设组/音量)。
class DeviceWallPane extends StatelessWidget {
  const DeviceWallPane({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WallState>();
    final devices = state.wallDevices;
    final groups = state.groups;

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
                    _GroupsHeader(state: state, groups: groups),
                    const SizedBox(height: 4),
                    for (final d in devices)
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
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              icon: const Icon(Icons.add_link),
              label: const Text('添加设备'),
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
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('新建组'),
            onPressed: () => _createGroupDialog(context, state),
          ),
          const SizedBox(width: 8),
          // §23 远程更新:整墙/整组免逐台 adb 刷机。broker/P2P 均可用。
          // 从纯图标改为带可见文字的按钮(与「新建组」风格一致),提升可发现性。
          OutlinedButton.icon(
            icon: const Icon(Icons.system_update_alt),
            label: const Text('更新固件'),
            onPressed: () => _remoteUpdateDialog(context, state),
          ),
        ],
      ),
    );
  }
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

  final versionCtl = TextEditingController();
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
              TextField(
                controller: versionCtl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '目标 versionCode（整数，必须比被控端现版本大）',
                  helperText: '被控端会拒绝 ≤ 当前版本的更新（防降级/重放）',
                ),
              ),
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
                    final vc = int.tryParse(versionCtl.text.trim());
                    if (vc == null || vc <= 0) {
                      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                          content: Text('请填写有效的 versionCode（正整数）')));
                      return;
                    }
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
                      uploadedUrl = r.url;
                      uploadedSha = r.sha256;
                      state.updateApp(
                        url: r.url,
                        versionCode: vc,
                        sha256: r.sha256,
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
        content: Text('已下发更新指令;被控端校验通过后将下载→安装→重启')));
  }
}

/// 分组管理头:列出各组为 chip,点击可改名/删组;修「不能新建组」的核心入口。
class _GroupsHeader extends StatelessWidget {
  const _GroupsHeader({required this.state, required this.groups});
  final WallState state;
  final List<WallGroup> groups;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('暂无分组 · 点「新建组」创建第一个', style: TextStyle(fontSize: 12)),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('分组 (${groups.length})',
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final g in groups)
                  InputChip(
                    label: Text(
                        '${g.name.isEmpty ? g.groupId : g.name} · ${g.members.length}台'),
                    avatar: Icon(
                        g.sync ? Icons.sync : Icons.sync_disabled,
                        size: 16),
                    onPressed: () => _editGroupDialog(context, state, g),
                    onDeleted: g.groupId == 'default'
                        ? null
                        : () => _confirmDeleteGroup(context, state, g),
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
                          )
                        else if (device.ip.isNotEmpty)
                          Text(device.ip,
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
  state.createGroup(
    groupId: gid,
    name: nameCtl.text.trim().isEmpty ? null : nameCtl.text.trim(),
    sync: sync,
  );
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
  state.updateGroup(
    groupId: g.groupId,
    name: nameCtl.text.trim(),
    sync: sync,
  );
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
  if (ok == true) state.deleteGroup(groupId: g.groupId);
}

/// 配置盒子(§19 configure_device):改名 / 设组 / 音量。修「不能设置盒子配置」。
Future<void> _configureDeviceDialog(BuildContext context, WallState state,
    WallDevice device, List<WallGroup> groups) async {
  final nameCtl = TextEditingController(text: device.deviceName);
  final st = device.status;
  var groupId = st?.groupId ?? '';
  var volume = (st?.volume ?? 80).toDouble();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text('配置 ${device.deviceId}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
              const SizedBox(height: 8),
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
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          // §23 单台推送升级:走同一 _remoteUpdateDialog 流程,目标预锁定为该台。
          // 先关本配置弹窗(pop null → 不触发下方 configureDevice),再在父 context 打开更新弹窗。
          OutlinedButton.icon(
            icon: const Icon(Icons.system_update_alt),
            label: const Text('推送升级'),
            onPressed: () {
              Navigator.pop(ctx);
              _remoteUpdateDialog(context, state, lockDevice: device);
            },
          ),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('应用')),
        ],
      ),
    ),
  );
  if (ok != true) return;
  state.configureDevice(
    deviceId: device.deviceId,
    deviceName: nameCtl.text.trim().isEmpty ? null : nameCtl.text.trim(),
    groupId: groupId.isEmpty ? null : groupId,
    volume: volume.round(),
  );
}
