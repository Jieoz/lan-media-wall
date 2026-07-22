import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../protocol/messages.dart';
import '../state/wall_state.dart';

Future<void> showMusicTerminalDialog(
    BuildContext context, WallState state, WallDevice device) async {
  final items = List<MediaItem>.of(state.musicPlaylistFor(device.deviceId));
  final authoritative = state.hasAuthoritativeMusicPlaylist(device.deviceId);
  final reportedSize = device.status?.musicPlaylistSize ?? 0;
  var busy = false;
  var status = !authoritative && reportedSize > 0
      ? '该播放端报告 $reportedSize 首，但未提供完整清单；已禁止空列表覆盖，请先升级播放端'
      : '';

  Future<void> showResult(BuildContext ctx, StateSetter setLocal,
      {required bool playAfterSave}) async {
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
      if (!playAfterSave) {
        setLocal(() => status = '设备已确认音乐列表 revision=${result.revision}');
        return;
      }
      setLocal(() => status = '列表已确认，等待设备进入音乐模式…');
      final mode = await state.setDeviceRuntimeMode(
          device.deviceId, RuntimeMode.music);
      setLocal(() => status = mode.ok && mode.mode == RuntimeMode.music
          ? '设备已进入音乐模式'
          : '模式切换失败：${mode.error.isEmpty ? '状态未确认' : mode.error}');
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
        title: Text('音乐终端 · ${device.deviceName.isEmpty ? device.deviceId : device.deviceName}'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('当前模式：${device.status?.runtimeMode.name ?? '未知'} · '
                    '设备列表 ${device.status?.musicPlaylistSize ?? 0} 首'),
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
                    OutlinedButton.icon(
                      onPressed: busy || (!authoritative && reportedSize > 0)
                          ? null
                          : () => showResult(
                              ctx, setLocal, playAfterSave: false),
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('保存列表'),
                    ),
                    FilledButton.icon(
                      onPressed: busy || (!authoritative && reportedSize > 0)
                          ? null
                          : () => showResult(
                              ctx, setLocal, playAfterSave: true),
                      icon: const Icon(Icons.music_note),
                      label: const Text('保存并播放'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy ? null : () async {
                        setLocal(() {
                          busy = true;
                          status = '等待设备恢复图片/视频模式…';
                        });
                        try {
                          final result = await state.setDeviceRuntimeMode(
                              device.deviceId, RuntimeMode.visual);
                          setLocal(() => status = result.ok &&
                                  result.mode == RuntimeMode.visual
                              ? '设备已恢复图片/视频模式'
                              : '恢复图片/视频失败：${result.error.isEmpty ? '状态未确认' : result.error}');
                        } catch (e) {
                          setLocal(() => status = '恢复图片/视频失败：$e');
                        } finally {
                          setLocal(() => busy = false);
                        }
                      },
                      icon: const Icon(Icons.ondemand_video),
                      label: const Text('恢复图片/视频'),
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
