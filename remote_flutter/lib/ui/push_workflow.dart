import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../protocol/envelope.dart';
import '../protocol/loop_mode.dart';
import '../protocol/messages.dart';
import '../state/playlist_draft.dart';
import '../state/wall_state.dart';
import 'dwell_picker.dart';

/// §C 单台推送的一体化工作流 —— 编排栏「下发到此设备」与设备卡「推送内容」共用同一
/// 实现，消除两处重复/冲突的单台 UX。目标始终锁定这一台 device_id（playlist /
/// cache_prefetch / prepare 全走单播 `to: player:<id>`），保留精确设备路由与既有
/// 上传/缓存栅栏行为。

/// 整列替换 vs 追加合并（§6.3）。
enum PushMode { replace, append }

extension PushModeLabel on PushMode {
  String get wire => this == PushMode.replace ? 'replace' : 'append';
}

/// 最终两个显式选择（§C）：仅下发并缓存 / 缓存完成后播放。
enum PushPlayback { cacheOnly, playAfterCache }

extension PushPlaybackLabel on PushPlayback {
  String get actionLabel => switch (this) {
        PushPlayback.cacheOnly => '仅下发并缓存',
        PushPlayback.playAfterCache => '缓存完成后播放',
      };
}

/// 推送确认摘要（§C）：概述目标、条目数、替换/追加行为、缓存行为、是否起播。
/// 纯函数，便于单测。
String pushConfirmSummary({
  required String targetName,
  required int itemCount,
  required PushMode mode,
  required PushPlayback playback,
}) {
  final modeText = mode == PushMode.replace
      ? '整列替换该设备当前播放列表'
      : '追加合并到该设备当前播放列表（按 item_id 去重）';
  final playText = playback == PushPlayback.playAfterCache
      ? '缓存完成后自动从头播放'
      : '仅下发并缓存，不自动播放';
  return '将向「$targetName」$modeText，共 $itemCount 项。\n'
      '内容先缓存到该盒子本地：$playText。\n'
      '不会删除该设备已缓存的其他文件。';
}

/// §D 措辞真相：把某动作包成「已发送、等待设备确认」的措辞，绝不在收到设备 ACK 前
/// 声称效果已发生（如 已清空 / 已重启 / 已播放 / 已更新）。纯函数，供各处复用。
String sentAwaitingAck(String action) => '$action命令已发送，等待设备确认';

/// 打开单台推送对话框（§C）。目标锁定 [device]。上传/编辑完成后由操作员在两个显式
/// 选择间二选一：`仅下发并缓存` 或 `缓存完成后播放`。
///
/// group_id 沿用该台当前组（仅用于 payload 携带，broker/p2p 靠 device_id 收敛目标）。
/// [seedItems] 非空时（编排栏「下发到此设备」入口）以这些条目作为初始草稿，而非回读
/// 设备当前列表；为空时（设备卡「推送内容」入口）载入该设备的 active_playlist 供编辑。
Future<void> showPushToDeviceDialog(
  BuildContext context,
  WallState state,
  WallDevice device, {
  List<MediaItem>? seedItems,
  LoopMode? seedLoopMode,
  bool seedSync = false,
}) async {
  final draft = PlaylistDraft();
  final active = device.status?.activePlaylist;
  if (seedItems != null) {
    draft.addAll(seedItems);
    if (seedLoopMode != null) draft.setLoopMode(seedLoopMode);
    draft.sync = seedSync;
  } else if (active != null) {
    draft.load(active, currentIndex: device.status?.currentIndex);
  }
  var uploading = false;
  var uploadHint = '';
  var mode = PushMode.replace;
  final name = device.deviceName.isEmpty ? device.deviceId : device.deviceName;
  final groupId = active?.groupId.isNotEmpty == true
      ? active!.groupId
      : device.status?.groupId ?? '';

  void submit(PushPlayback playback, StateSetter setLocal) async {
    // 二次确认：概述目标/条目/替换或追加/缓存/是否起播。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('确认推送到「$name」？'),
        content: Text(pushConfirmSummary(
          targetName: name,
          itemCount: draft.length,
          mode: mode,
          playback: playback,
        )),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(playback.actionLabel)),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final pid = draft.playlistId ??
          'pl-${device.deviceId}-${uuid4().substring(0, 6)}';
      // 单播：playlist（+ cache_prefetch）全锁这一台，保留精确 device_id 路由。
      state.sendPlaylist(
        playlistId: pid,
        groupId: groupId,
        sync: false,
        loopMode: draft.loopMode,
        items: draft.items,
        mode: mode.wire,
        deviceId: device.deviceId,
      );
      state.cachePrefetch(draft.items, deviceId: device.deviceId);
      // 仅「缓存完成后播放」才走栅栏 prepare（等缓存就绪统一起播）。
      if (playback == PushPlayback.playAfterCache) {
        state.prepareWithBarrier(
          playlistId: pid,
          groupId: groupId,
          deviceId: device.deviceId,
        );
      }
      if (context.mounted) Navigator.of(context).pop();
      _toast(
          context,
          sentAwaitingAck(
              '向「$name」${playback.actionLabel}（${draft.length} 项）'));
    } catch (e) {
      _toast(context, '推送失败: $e');
    }
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        Future<void> pick(String type) async {
          final result = await FilePicker.platform.pickFiles(
            type: type == 'image' ? FileType.image : FileType.video,
            allowMultiple: true,
            withData: false,
          );
          if (result == null || result.files.isEmpty) return;
          // §5 图片必须有停留时长：上传前用秒 UI 确认（默认 8 秒），不再硬编码 8000ms。
          int? durationMs;
          if (type == 'image') {
            durationMs = await showDwellPicker(ctx);
            if (durationMs == null) return; // 取消即放弃
          }
          setLocal(() {
            uploading = true;
            uploadHint = '准备上传…';
          });
          try {
            for (final f in result.files) {
              final path = f.path;
              if (path == null) continue;
              setLocal(() => uploadHint = '上传 ${f.name} …');
              final item = await state.uploadLocalMedia(
                file: File(path),
                type: type,
                name: f.name,
                durationMs: durationMs,
                onProgress: (sent, total) {
                  if (total > 0) {
                    setLocal(() => uploadHint =
                        '上传 ${f.name}  ${(sent / total * 100).toStringAsFixed(0)}%');
                  }
                },
              );
              draft.add(item);
              setLocal(() {});
            }
          } catch (e) {
            setLocal(() => uploadHint = '上传失败: $e');
          } finally {
            setLocal(() => uploading = false);
          }
        }

        final canSend = !uploading && draft.isNotEmpty;
        return PopScope(
          canPop: !uploading,
          child: AlertDialog(
            title: Text('推送内容 → $name'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: _PushBody(
                  draft: draft,
                  active: active,
                  uploading: uploading,
                  uploadHint: uploadHint,
                  mode: mode,
                  onModeChanged: (m) => setLocal(() => mode = m),
                  onPick: pick,
                  onChanged: () => setLocal(() {}),
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: uploading ? null : () => Navigator.pop(ctx),
                  child: const Text('取消')),
              OutlinedButton.icon(
                icon: const Icon(Icons.download),
                label: Text(PushPlayback.cacheOnly.actionLabel),
                onPressed:
                    canSend ? () => submit(PushPlayback.cacheOnly, setLocal) : null,
              ),
              FilledButton.icon(
                icon: const Icon(Icons.play_circle),
                label: Text(PushPlayback.playAfterCache.actionLabel),
                onPressed: canSend
                    ? () => submit(PushPlayback.playAfterCache, setLocal)
                    : null,
              ),
            ],
          ),
        );
      },
    ),
  );
  draft.dispose();
}

void _toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// 推送对话框主体：来源提示 + 加图片/视频 + 上传进度 + 列表编辑 + 替换/追加 + 循环模式。
class _PushBody extends StatelessWidget {
  const _PushBody({
    required this.draft,
    required this.active,
    required this.uploading,
    required this.uploadHint,
    required this.mode,
    required this.onModeChanged,
    required this.onPick,
    required this.onChanged,
  });
  final PlaylistDraft draft;
  final ActivePlaylist? active;
  final bool uploading;
  final String uploadHint;
  final PushMode mode;
  final ValueChanged<PushMode> onModeChanged;
  final Future<void> Function(String type) onPick;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (active != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '已载入设备当前列表 ${draft.length} 项，可调整顺序、删除或追加后应用。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else
          Text('只推给这一台(单播)。内容先缓存到该盒子本地，缓存就绪后可从头播放。',
              style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.add_photo_alternate),
              label: const Text('加图片'),
              onPressed: uploading ? null : () => onPick('image'),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.video_call),
              label: const Text('加视频'),
              onPressed: uploading ? null : () => onPick('video'),
            ),
          ],
        ),
        if (uploading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(child: Text(uploadHint,
                    style: Theme.of(context).textTheme.bodySmall)),
              ],
            ),
          ),
        if (draft.isEmpty && !uploading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('尚未添加内容', style: TextStyle(fontSize: 12)),
          )
        else
          ...List.generate(draft.length, (i) {
            final it = draft.items[i];
            return ListTile(
              dense: true,
              leading: Icon(it.isImage ? Icons.image : Icons.movie),
              title: Text(
                '${i + 1}. ${it.name}${draft.currentIndex == i ? " · 当前播放" : ""}',
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: it.isImage
                  ? Text('图片 · ${dwellSecondsLabel(it.durationMs)}')
                  : null,
              trailing: Wrap(
                children: [
                  if (it.isImage)
                    IconButton(
                      tooltip: '改停留时长',
                      icon: const Icon(Icons.timer_outlined),
                      onPressed: () async {
                        final ms = await showDwellPicker(context,
                            initialMs: it.durationMs,
                            title: '「${it.name}」停留时长');
                        if (ms == null) return;
                        draft.setDurationMs(i, ms);
                        onChanged();
                      },
                    ),
                  IconButton(
                    tooltip: '上移',
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: i == 0
                        ? null
                        : () {
                            draft.move(i, i - 1);
                            onChanged();
                          },
                  ),
                  IconButton(
                    tooltip: '下移',
                    icon: const Icon(Icons.arrow_downward),
                    onPressed: i == draft.length - 1
                        ? null
                        : () {
                            draft.move(i, i + 1);
                            onChanged();
                          },
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      draft.removeAt(i);
                      onChanged();
                    },
                  ),
                ],
              ),
            );
          }),
        const SizedBox(height: 4),
        // §6.3 替换 vs 追加，与编排栏术语一致。
        SegmentedButton<PushMode>(
          segments: const [
            ButtonSegment(value: PushMode.replace, label: Text('整列替换')),
            ButtonSegment(value: PushMode.append, label: Text('追加合并')),
          ],
          selected: {mode},
          onSelectionChanged: (s) => onModeChanged(s.first),
        ),
        DropdownButtonFormField<LoopMode>(
          isDense: true,
          decoration: const InputDecoration(
              labelText: '循环模式',
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero),
          value: draft.loopMode,
          items: const [
            DropdownMenuItem(value: LoopMode.none, child: Text('不循环')),
            DropdownMenuItem(value: LoopMode.all, child: Text('整列循环')),
            DropdownMenuItem(value: LoopMode.one, child: Text('单项循环')),
          ],
          onChanged: (v) {
            draft.setLoopMode(v ?? LoopMode.all);
            onChanged();
          },
        ),
      ],
    );
  }
}
