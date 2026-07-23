import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../protocol/messages.dart';
import '../state/wall_state.dart';

/// 音乐列表编辑器。模式切换属于设备播放控制区，这里只负责上传、排序和提交列表。
Future<void> showMusicTerminalDialog(
    BuildContext context, WallState state, WallDevice device) async {
  final items = List<MediaItem>.of(state.musicPlaylistFor(device.deviceId));
  final authoritative = state.hasAuthoritativeMusicPlaylist(device.deviceId);
  final reportedSize = device.status?.musicPlaylistSize ?? 0;
  var busy = false;
  var status = !authoritative && reportedSize > 0
      ? '该播放端报告 $reportedSize 首，但未提供完整清单；已禁止空列表覆盖，请先升级播放端'
      : '';

  Future<void> saveList(BuildContext ctx, StateSetter setLocal) async {
    setLocal(() {
      busy = true;
      status = '等待设备确认音乐列表…';
    });
    try {
      final result = await state.sendDeviceMusicPlaylist(
          deviceId: device.deviceId, items: items);
      if (!result.ok) {
        setLocal(() => status = result.error == 'timeout'
            ? '设备确认超时，不能视为保存成功'
            : '设备拒绝列表：${result.error}');
        return;
      }
      setLocal(() => status = '设备已确认音乐列表 revision=${result.revision}');
    } catch (e) {
      setLocal(() => status = '操作失败：$e');
    } finally {
      setLocal(() => busy = false);
    }
  }

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text('编辑音乐列表 · ${device.deviceName.isEmpty ? device.deviceId : device.deviceName}'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('设备列表 ${device.status?.musicPlaylistSize ?? 0} 首 · '
                    '保存后可在播放控制区切换到“音乐终端”模式'),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : () async {
                    final picked = await FilePicker.platform.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: const [
                        'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus'
                      ],
                      allowMultiple: true,
                      withData: false,
                    );
                    if (picked == null) return;
                    setLocal(() {
                      busy = true;
                      status = '准备上传…';
                    });
                    try {
                      for (final file in picked.files) {
                        if (file.path == null) continue;
                        setLocal(() => status = '上传 ${file.name}…');
                        final item = await state.uploadLocalMedia(
                          file: File(file.path!),
                          type: 'audio',
                          name: file.name,
                          onProgress: (sent, total) {
                            if (total > 0) {
                              setLocal(() => status =
                                  '上传 ${file.name} ${(sent / total * 100).toStringAsFixed(0)}%');
                            }
                          },
                        );
                        items.add(item);
                        setLocal(() {});
                      }
                      setLocal(() => status = '上传完成；保存后才会下发到设备');
                    } catch (e) {
                      setLocal(() => status = '上传失败：$e');
                    } finally {
                      setLocal(() => busy = false);
                    }
                  },
                  icon: const Icon(Icons.audio_file),
                  label: const Text('添加音乐文件'),
                ),
                const SizedBox(height: 8),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('音乐列表为空；音乐与图片/视频播放列表相互独立。'),
                  )
                else
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: items.length,
                    onReorder: busy ? (_, __) {} : (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex--;
                      final item = items.removeAt(oldIndex);
                      items.insert(newIndex, item);
                      setLocal(() {});
                    },
                    itemBuilder: (_, index) {
                      final item = items[index];
                      return ListTile(
                        key: ValueKey('${item.itemId}-$index'),
                        leading: const Icon(Icons.drag_handle),
                        title: Text(item.name.isEmpty ? item.itemId : item.name),
                        trailing: IconButton(
                          tooltip: '从列表移除',
                          onPressed: busy ? null : () => setLocal(() => items.removeAt(index)),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      );
                    },
                  ),
                if (status.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(status, style: Theme.of(ctx).textTheme.bodySmall),
                ],
                const Divider(height: 24),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: busy || (!authoritative && reportedSize > 0)
                          ? null
                          : () => saveList(ctx, setLocal),
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('保存列表'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('关闭')),
        ],
      ),
    ),
  );
}
