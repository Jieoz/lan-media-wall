import 'package:flutter/material.dart';

import '../protocol/messages.dart';
import '../state/wall_state.dart';

/// §6.3b 待机/恢复的**唯一**批量入口。
///
/// 设备墙(整墙范围)与播放编排(锁定到当前目标分组)共用这一个实现:待机是逐台
/// 下发 + 逐台等 Player 确认的动作,不能在两个页面各写一套判定与文案,否则
/// 一处修了另一处还在错。
///
/// [lockGroupId] 非空时锁定到该分组(编排页「当前分组」语义,不给范围下拉);
/// 为空时保持整墙行为:默认「全部设备」,可自由选全部或某组。
Future<void> showRuntimeModeBatchDialog(
  BuildContext context,
  WallState state, {
  String? lockGroupId,
}) async {
  var target = lockGroupId == null ? 'all' : 'group:$lockGroupId';
  var busy = false;
  var output = '';

  Iterable<String> targetDeviceIds() => target == 'all'
      ? state.devices.map((d) => d.deviceId)
      : state
          .membersOf(target.substring('group:'.length))
          .map((d) => d.deviceId);

  String render(Map<String, RuntimeModeResult> results, {required bool standby}) {
    if (results.isEmpty) return '目标范围内没有设备。';
    return results.entries.map((entry) {
      final r = entry.value;
      if (standby) {
        return '${entry.key}: '
            '${r.ok && r.mode == RuntimeMode.standby ? '已进入待机' : '失败 ${r.error}'}';
      }
      return '${entry.key}: ${r.ok ? '已恢复 ${r.mode?.name ?? ''}' : '失败 ${r.error}'}';
    }).join('\n');
  }

  final scopeLabel = lockGroupId == null
      ? '分组 / 全部待机与恢复'
      : '当前分组待机与恢复';

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(scopeLabel),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (lockGroupId == null)
                DropdownButtonFormField<String>(
                  value: target,
                  decoration: const InputDecoration(labelText: '目标范围'),
                  items: [
                    const DropdownMenuItem(value: 'all', child: Text('全部设备')),
                    for (final group in state.groups)
                      DropdownMenuItem(
                        value: 'group:${group.groupId}',
                        child: Text(
                            '分组：${group.name.isEmpty ? group.groupId : group.name}'),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (value) => setLocal(() => target = value ?? 'all'),
                )
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('目标范围：当前分组 '
                      '(${state.membersOf(lockGroupId).length} 台)'),
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
          TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('关闭')),
          OutlinedButton(
            onPressed: busy
                ? null
                : () async {
                    final ids = targetDeviceIds();
                    setLocal(() {
                      busy = true;
                      output = '等待逐台确认…';
                    });
                    final results = await state.restoreDevicesRuntimeMode(ids);
                    setLocal(() {
                      busy = false;
                      output = render(results, standby: false);
                    });
                  },
            child: const Text('恢复前态'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    final ids = targetDeviceIds();
                    setLocal(() {
                      busy = true;
                      output = '等待逐台确认…';
                    });
                    final results = await state.setDevicesRuntimeMode(
                        ids, RuntimeMode.standby);
                    setLocal(() {
                      busy = false;
                      output = render(results, standby: true);
                    });
                  },
            child: const Text('进入待机'),
          ),
        ],
      ),
    ),
  );
}
