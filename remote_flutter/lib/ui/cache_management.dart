library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/messages.dart';
import '../state/cache_ops.dart';
import '../state/wall_state.dart';

/// §27/§28 单台设备缓存管理面板 —— 安全清理流:清单 → dry-run → 显式确认 → 提交。
///
/// 硬安全约束(设计合同 §27/§28,产品真相 2/8):
///  - 无乐观成功:UI 只反映归约器的终态(success/partial/failed/timeout/unsupported/
///    offline/generationConflict),路由 ACK 绝不显示为成功。
///  - 删除权威在播放端:UI 只按 item_id/范围下发,绝不显示可编辑的路径作为删除输入。
///  - 显式确认:提交(真实删除)必须先过一道确认对话框;dry-run 零变更。
///  - 能力真值:目标未广告 cache_cleanup_v1/cache_inventory_v1 → 直接 unsupported,
///    从不下发假装支持。
///  - 与播放列表解耦:此面板是独立的设备缓存流,播放列表行删除仍只是「移出列表」。
///
/// 本文件把「展示」与「链路」拆开:[CacheManagementView] 是有状态容器(持 dry-run 候选、
/// 监听 [WallState] 通知),[CacheOpResultTile] 是纯展示,便于 widget 测试无需网络。

/// 一个缓存操作终态的视觉呈现(图标 + 颜色 + 标签)。终态互不混淆(设计合同 §27)。
class CacheOpVisual {
  final IconData icon;
  final Color color;
  final String label;
  const CacheOpVisual(this.icon, this.color, this.label);
}

/// 把 [CacheOpStatus] 映射到互不混淆的视觉。pending 用进度色;每个终态独立。
CacheOpVisual cacheOpVisual(CacheOpStatus status) {
  switch (status) {
    case CacheOpStatus.pending:
      return const CacheOpVisual(Icons.hourglass_top, Colors.blueGrey, '进行中');
    case CacheOpStatus.success:
      return const CacheOpVisual(Icons.check_circle, Colors.green, '成功');
    case CacheOpStatus.partial:
      return const CacheOpVisual(
          Icons.error_outline, Colors.orange, '部分成功');
    case CacheOpStatus.failed:
      return const CacheOpVisual(Icons.cancel, Colors.red, '失败');
    case CacheOpStatus.timeout:
      return const CacheOpVisual(Icons.timer_off, Colors.red, '超时无响应');
    case CacheOpStatus.unsupported:
      return const CacheOpVisual(
          Icons.block, Colors.grey, '该设备不支持缓存清理');
    case CacheOpStatus.offline:
      return const CacheOpVisual(Icons.cloud_off, Colors.grey, '设备离线');
    case CacheOpStatus.generationConflict:
      return const CacheOpVisual(
          Icons.sync_problem, Colors.deepPurple, '代次冲突(未删除任何内容)');
  }
}

/// 人类可读的每项跳过/失败原因(§27 skipped[].reason / failed[].reason /
/// §28 protection_reasons[])。
///
/// 权威线协议是「无前缀原词」:播放端(CacheReferenceSnapshot.kt /
/// cache_refs.py)发的保护原因是 playing / active / prepared / inflight /
/// last_task / pinned / shared_content;跳过/失败是 not_found / delete_failed;
/// 代次类是 generation_mismatch / generation_changed。这里对齐这套真实 token,
/// 覆盖全部保护原因(含 prepared 与 pinned),未知 token 原样透出。
String cacheReasonLabel(String reason) {
  switch (reason) {
    case 'not_found':
      return '未找到';
    case 'delete_failed':
      return '删除失败';
    case 'playing':
      return '正在播放';
    case 'active':
      return '当前列表引用';
    case 'prepared':
      return '正在缓冲/预备';
    case 'inflight':
      return '正在下载';
    case 'last_task':
      return '断电续播引用';
    case 'pinned':
      return '已固定';
    case 'shared_content':
      return '被其它项共享';
    case 'generation_mismatch':
      return '采纳代次不符';
    case 'generation_changed':
      return '清理期间代次变化';
    default:
      return reason.isEmpty ? '—' : reason;
  }
}

int _kib(int bytes) => (bytes / 1024).ceil();

/// 字节的人类可读呈现(KiB/MiB)。
String humanBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${_kib(bytes)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

/// 一台设备一个清理/清单操作的终态卡(纯展示)。终态互不混淆并按需给出重试入口。
/// [onRetry] 为 null 时不显示重试(如 pending/inventory/unsupported 场景由调用方决定)。
class CacheOpResultTile extends StatelessWidget {
  const CacheOpResultTile({super.key, required this.op, this.onRetry});

  final CacheOperation op;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final v = cacheOpVisual(op.status);
    final r = op.result;
    final subtitleLines = <String>[];
    if (op.kind == 'cleanup' && r != null) {
      if (op.dryRun && op.status == CacheOpStatus.success) {
        subtitleLines.add(
            '演练:可回收 ${r.deleted.length} 项 / ${humanBytes(r.freedBytes)}(未删除)');
      } else if (op.status == CacheOpStatus.success ||
          op.status == CacheOpStatus.partial) {
        subtitleLines.add(
            '已删除 ${r.deleted.length} 项,释放 ${humanBytes(r.freedBytes)}');
      }
      if (r.skipped.isNotEmpty) {
        subtitleLines.add('跳过 ${r.skipped.length} 项(受保护/未找到)');
      }
      if (r.failed.isNotEmpty) {
        subtitleLines.add('删除失败 ${r.failed.length} 项');
      }
      if (op.status == CacheOpStatus.generationConflict) {
        subtitleLines.add('期望代次 ${r.expectedPushId ?? '?'} '
            '≠ 实际 ${r.observedPushId ?? '?'}');
      }
    }
    if (op.detail.isNotEmpty && op.status != CacheOpStatus.success) {
      subtitleLines.add(op.detail);
    }
    // 可重试的终态:失败/超时/部分/代次冲突/离线(不支持不可重试)。
    final retryable = onRetry != null &&
        op.isTerminal &&
        op.status != CacheOpStatus.success &&
        op.status != CacheOpStatus.unsupported;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: op.status == CacheOpStatus.pending
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(v.icon, color: v.color),
        title: Text(
          '${op.kind == 'cleanup' ? '清理' : '清单'} · ${v.label}',
          style: TextStyle(color: v.color, fontWeight: FontWeight.w600),
        ),
        subtitle: subtitleLines.isEmpty
            ? null
            : Text(subtitleLines.join('\n')),
        isThreeLine: subtitleLines.length > 1,
        trailing: retryable
            ? TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              )
            : null,
      ),
    );
  }
}

/// 打开单台设备缓存管理对话框(从设备配置面板进入)。
Future<void> showCacheManagementDialog(
  BuildContext context,
  WallState state,
  WallDevice device,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: CacheManagementView(
          state: state,
          deviceId: device.deviceId,
          deviceName:
              device.deviceName.isEmpty ? device.deviceId : device.deviceName,
        ),
      ),
    ),
  );
}

/// 缓存管理容器:持 dry-run 候选、监听 [WallState],把清单/演练/提交/重试接到
/// [WallState] 的一体化归约器。展示由 [CacheOpResultTile] 负责,便于窄屏与单测。
class CacheManagementView extends StatefulWidget {
  const CacheManagementView({
    super.key,
    required this.state,
    required this.deviceId,
    required this.deviceName,
  });

  final WallState state;
  final String deviceId;
  final String deviceName;

  @override
  State<CacheManagementView> createState() => _CacheManagementViewState();
}

class _CacheManagementViewState extends State<CacheManagementView> {
  Timer? _timeoutTimer;
  /// 当前清单请求 id(用于查回其操作/结果)。
  String? _inventoryReq;

  /// 当前清理(dry-run 或提交)请求 id。
  String? _cleanupReq;

  /// dry-run 演练回来的可回收候选 item_id —— 提交时按这批精确下发(§27 只发 id)。
  List<String> _dryRunCandidates = const [];
  String? _reviewedPushId;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer.periodic(
        const Duration(seconds: 1), (_) => _s.reapCacheTimeouts());
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  WallState get _s => widget.state;

  DeviceStatus? get _status => _s.statusFor(widget.deviceId);
  bool get _supportsInventory => _status?.supportsCacheInventory ?? false;
  bool get _supportsCleanup => _status?.supportsCacheCleanup ?? false;
  bool get _online => _status?.online ?? false;

  CacheOperation? get _inventoryOp => _inventoryReq == null
      ? null
      : _s.cacheOperationFor(_inventoryReq!, widget.deviceId);
  CacheOperation? get _cleanupOp => _cleanupReq == null
      ? null
      : _s.cacheOperationFor(_cleanupReq!, widget.deviceId);

  void _refreshInventory() {
    _s.reapCacheTimeouts();
    final op = _s.cacheInventory(deviceId: widget.deviceId);
    setState(() => _inventoryReq = op.requestId);
  }

  void _dryRun() {
    _s.reapCacheTimeouts();
    final op = _s.cacheCleanup(deviceId: widget.deviceId, dryRun: true);
    setState(() {
      _cleanupReq = op.requestId;
      _dryRunCandidates = const [];
      _reviewedPushId = null;
    });
  }

  /// 提交真实清理。必须先过显式确认(§27:无乐观成功、删除权威在播放端)。
  /// 只允许提交当前成功 dry-run 审核出的精确候选。
  Future<void> _commitCleanup() async {
    final candidates = _dryRunCandidates;
    final n = candidates.length;
    final reviewedPushId = _reviewedPushId;
    if (reviewedPushId == null || reviewedPushId.isEmpty) return;
    if (n == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清理缓存?'),
        content: Text('将从「${widget.deviceName}」删除演练确认的 $n 项可回收缓存。受保护内容'
            '(正在播放/当前列表/断电续播/下载中)不会被删除。此操作不可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认清理')),
        ],
      ),
    );
    if (confirmed != true) return;
    _s.reapCacheTimeouts();
    final op = _s.cacheCleanup(
      deviceId: widget.deviceId,
      mode: 'selected',
      dryRun: false,
      itemIds: candidates,
      expectedPushId: reviewedPushId,
    );
    if (mounted) setState(() => _cleanupReq = op.requestId);
  }

  void _retryCleanup() {
    _s.reapCacheTimeouts();
    final candidates = _dryRunCandidates;
    final op = _s.cacheCleanupRetry(
      deviceId: widget.deviceId,
      mode: candidates.isEmpty ? 'unreferenced' : 'selected',
      dryRun: _cleanupOp?.dryRun ?? false,
      itemIds: candidates.isEmpty ? null : candidates,
      expectedPushId: (_cleanupOp?.dryRun ?? false) ? null : _reviewedPushId,
    );
    setState(() => _cleanupReq = op.requestId);
  }

  /// dry-run 成功后,把可回收候选记下来供提交按批下发。
  void _adoptDryRunCandidates(CacheOperation? op) {
    if (op != null &&
        op.kind == 'cleanup' &&
        op.dryRun &&
        op.status == CacheOpStatus.success &&
        op.result != null) {
      final ids = op.result!.deleted.map((d) => d.itemId).toList();
      _dryRunCandidates = ids;
      _reviewedPushId = op.result!.observedPushId;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 监听 WallState:结果到达/超时收割都会 notifyListeners → 重建反映终态。
    return AnimatedBuilder(
      animation: _s,
      builder: (context, _) {
        _adoptDryRunCandidates(_cleanupOp);
        final theme = Theme.of(context);
        final children = <Widget>[
          Row(
            children: [
              const Icon(Icons.sd_storage, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('缓存管理 · ${widget.deviceName}',
                    style: theme.textTheme.titleMedium),
              ),
              IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          const Divider(height: 16),
        ];

        // 能力真值前置:不支持则明确不可操作,绝不假装。
        if (!_supportsCleanup && !_supportsInventory) {
          children.add(const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Row(children: [
              Icon(Icons.block, color: Colors.grey),
              SizedBox(width: 8),
              Expanded(child: Text('该设备未广告缓存管理能力(可能是旧版本播放端),'
                  '无法执行清单/清理。')),
            ]),
          ));
          return _frame(children);
        }
        if (!_online) {
          children.add(const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Row(children: [
              Icon(Icons.cloud_off, color: Colors.grey),
              SizedBox(width: 8),
              Expanded(child: Text('设备当前离线,无法执行缓存清单/清理。')),
            ]),
          ));
          return _frame(children);
        }
        children.add(_summaryCard(theme));
        children.add(const SizedBox(height: 8));
        children.add(_actionBar());
        children.add(const SizedBox(height: 8));
        children.addAll(_resultsAndInventory());
        return _frame(children);
      },
    );
  }

  Widget _frame(List<Widget> children) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            children.first,
            children[1],
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children.sublist(2),
                ),
              ),
            ),
          ],
        ),
      );

  /// §26 轻量摘要卡(周期性 status 已带,无需请求)。老端为 null 时给出提示。
  Widget _summaryCard(ThemeData theme) {
    final s = _status?.cacheSummary;
    if (s == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('暂无缓存摘要(设备尚未上报或为旧版本)。'),
        ),
      );
    }
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(k, style: theme.textTheme.bodySmall),
              Text(v, style: theme.textTheme.bodyMedium),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row('缓存总量', '${s.readyItems} 项 · ${humanBytes(s.totalBytes)}'),
            row('可回收',
                '${s.reclaimableItems} 项 · ${humanBytes(s.reclaimableBytes)}'),
            row('受保护', '${s.protectedItems} 项'),
            row('下载中', '${s.inflightItems} 项'),
            if (s.lastCleanupError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('上次清理错误: ${s.lastCleanupError}',
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
          ],
        ),
      ),
    );
  }

  /// 动作条:刷新清单 / 演练(dry-run) / 提交清理。窄屏用 Wrap 不溢出。
  Widget _actionBar() {
    final busy = _s.cacheHasPending(widget.deviceId);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: (_supportsInventory && !busy) ? _refreshInventory : null,
          icon: const Icon(Icons.list_alt, size: 18),
          label: const Text('刷新清单'),
        ),
        OutlinedButton.icon(
          onPressed: (_supportsCleanup && !busy) ? _dryRun : null,
          icon: const Icon(Icons.science_outlined, size: 18),
          label: const Text('演练(不删除)'),
        ),
        FilledButton.icon(
          onPressed: (_supportsCleanup && !busy && _dryRunCandidates.isNotEmpty)
              ? _commitCleanup
              : null,
          icon: const Icon(Icons.cleaning_services, size: 18),
          label: Text(_dryRunCandidates.isNotEmpty
              ? '清理 ${_dryRunCandidates.length} 项'
              : '请先演练'),
        ),
      ],
    );
  }

  /// 结果区:清理操作终态(带重试)+ 清单结果(逐项 + 保护原因)。
  List<Widget> _resultsAndInventory() {
    final out = <Widget>[];
    final cleanup = _cleanupOp;
    if (cleanup != null) {
      out.add(CacheOpResultTile(op: cleanup, onRetry: _retryCleanup));
    }
    final inv = _inventoryOp;
    if (inv != null && inv.isPending) {
      out.add(const CacheOpResultTile(
          op: CacheOperation(
              requestId: '_', deviceId: '_', kind: 'inventory',
              status: CacheOpStatus.pending, startedAtMs: 0)));
    } else if (inv != null && inv.isTerminal && inv.inventory != null) {
      out.add(CacheInventoryList(items: inv.inventory!.items));
    } else if (inv != null && inv.isTerminal) {
      // 清单请求终态但无 items(超时/失败/离线等)→ 复用结果卡区分。
      out.add(CacheOpResultTile(op: inv, onRetry: _refreshInventory));
    }
    return out;
  }
}

/// §28 缓存清单逐项列表(纯展示):每项标可回收/受保护并给出保护原因。
/// 抽成公开件便于 widget 测试直接渲染,无需网络。
class CacheInventoryList extends StatelessWidget {
  const CacheInventoryList({super.key, required this.items});

  final List<InventoryItem> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text('缓存清单(${items.length} 项)',
              style: Theme.of(context).textTheme.labelLarge),
        ),
        for (final it in items) _CacheInventoryTile(item: it),
      ],
    );
  }
}

class _CacheInventoryTile extends StatelessWidget {
  const _CacheInventoryTile({required this.item});
  final InventoryItem item;

  @override
  Widget build(BuildContext context) {
    final it = item;
    final protectedReasons = it.protectionReasons.map(cacheReasonLabel).join('、');
    return ListTile(
      dense: true,
      leading: Icon(
        it.isProtected ? Icons.lock_outline : Icons.delete_sweep_outlined,
        size: 18,
        color: it.isProtected ? Colors.orange : Colors.blueGrey,
      ),
      title: Text(it.itemId, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        if (it.bytes != null) humanBytes(it.bytes!),
        if (it.isProtected) '受保护: $protectedReasons' else '可回收',
      ].join(' · ')),
    );
  }
}
