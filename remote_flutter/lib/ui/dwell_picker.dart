import 'package:flutter/material.dart';

/// 图片停留时长(dwell)选择 —— 用**秒**面向操作者,内部仍换算为 `duration_ms`(毫秒)。
///
/// 线协议字段 `duration_ms` 语义不变(§5),这里只是控制端表现层:预设 5/8/10/15/30 秒
/// + 自定义秒数,默认 8 秒。图片必须有正的停留时长;视频不走此路径。
const List<int> kDwellPresetSeconds = [5, 8, 10, 15, 30];

/// 默认图片停留秒数(原先硬编码 8000ms)。
const int kDefaultDwellSeconds = 8;
const int kDefaultDwellMs = kDefaultDwellSeconds * 1000;

/// 把毫秒渲染成人类可读的秒(用于列表副标题 `图片 · N秒`)。
String dwellSecondsLabel(int? durationMs) {
  final ms = durationMs ?? kDefaultDwellMs;
  final secs = ms / 1000.0;
  // 整秒不带小数;非整秒保留一位,避免 8.0秒 这种噪声。
  final text = secs == secs.roundToDouble()
      ? secs.round().toString()
      : secs.toStringAsFixed(1);
  return '$text秒';
}

/// 弹出「停留时长(秒)」选择框。返回选定的**毫秒**值;取消返回 null。
///
/// [initialMs] 用于「编辑已有图片项」时回填当前时长。[title] 允许调用方区分
/// 「新增图片」与「修改停留」的语境。
Future<int?> showDwellPicker(
  BuildContext context, {
  int? initialMs,
  String title = '图片停留时长',
}) async {
  final initialSeconds =
      ((initialMs ?? kDefaultDwellMs) / 1000).round().clamp(1, 86400);
  // 若初值命中预设用预设,否则落到自定义。
  var selected =
      kDwellPresetSeconds.contains(initialSeconds) ? initialSeconds : -1;
  final customCtl = TextEditingController(
      text: selected == -1 ? initialSeconds.toString() : '');

  final result = await showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('每张图片在屏幕上停留多久(秒)。',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final s in kDwellPresetSeconds)
                    ChoiceChip(
                      label: Text('$s秒'),
                      selected: selected == s,
                      onSelected: (_) => setLocal(() => selected = s),
                    ),
                  ChoiceChip(
                    label: const Text('自定义'),
                    selected: selected == -1,
                    onSelected: (_) => setLocal(() => selected = -1),
                  ),
                ],
              ),
              if (selected == -1)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    controller: customCtl,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    decoration: const InputDecoration(
                        labelText: '自定义秒数', suffixText: '秒'),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final secs = selected == -1
                    ? int.tryParse(customCtl.text.trim())
                    : selected;
                if (secs == null || secs <= 0) {
                  ScaffoldMessenger.of(ctx)
                    ..clearSnackBars()
                    ..showSnackBar(const SnackBar(
                        content: Text('请填有效的停留秒数(>0)')));
                  return;
                }
                Navigator.pop(ctx, secs * 1000);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    ),
  );
  customCtl.dispose();
  return result;
}
