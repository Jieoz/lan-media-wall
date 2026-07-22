import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../protocol/messages.dart';
import '../state/broker_migration.dart';
import '../state/wall_state.dart';
import 'connection_status.dart';

/// 设置：连接方式（P2P 推荐 / Broker 高级）、可选 broker 地址、PSK、controller_id ——
/// 输入并持久化(§1/§3/§B)。连接标签由实际拓扑派生，绝不因保存成功乐观显示已连接。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _psk = TextEditingController();
  final _mediaUploadToken = TextEditingController();
  final _ctlId = TextEditingController();
  bool _secure = false;
  bool _pskVisible = false;
  bool _mediaUploadTokenVisible = false;
  bool _loaded = false;
  ConnectionMode _mode = ConnectionMode.autoP2p;
  String? _portError;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _psk.dispose();
    _mediaUploadToken.dispose();
    _ctlId.dispose();
    super.dispose();
  }

  void _loadFrom(WallState s) {
    if (_loaded) return;
    _loaded = true;
    _host.text = s.brokerHost;
    _port.text = s.brokerPort.toString();
    _psk.text = s.psk;
    _mediaUploadToken.text = s.mediaUploadToken;
    _ctlId.text = s.controllerId;
    _secure = s.brokerSecure;
    _mode = s.connectionMode;
  }

  Future<void> _save(WallState s) async {
    // §B 严格端口校验 1–65535：仅 broker 模式需要有效端口；绝不静默回落 8770。
    int port = s.brokerPort;
    if (_mode == ConnectionMode.broker) {
      final r = validateBrokerPort(_port.text);
      if (!r.ok) {
        setState(() => _portError = r.error);
        return;
      }
      port = r.port!;
    }
    setState(() => _portError = null);
    await s.updateSettings(
      connectionMode: _mode,
      host: _host.text,
      port: port,
      secure: _secure,
      newPsk: _psk.text,
      newMediaUploadToken: _mediaUploadToken.text,
      newControllerId: _ctlId.text,
    );
    if (!mounted) return;
    // 措辞真相(§B)：保存只保证已保存并触发重连，真正的已连接由状态机推进。
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存，正在重新连接')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WallState>();
    _loadFrom(state);
    final isBroker = _mode == ConnectionMode.broker;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(state.connectionStatusLabel,
                  style: TextStyle(
                      color: state.connected
                          ? Colors.green
                          : Colors.orange)),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('连接方式', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<ConnectionMode>(
            segments: const [
              ButtonSegment(
                value: ConnectionMode.autoP2p,
                icon: Icon(Icons.wifi_tethering),
                label: Text('自动发现 / P2P（推荐）'),
              ),
              ButtonSegment(
                value: ConnectionMode.broker,
                icon: Icon(Icons.dns),
                label: Text('连接 Broker（高级）'),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 8),
          Text(
            isBroker
                ? '高级：连到独立部署的 Broker（填地址/端口/WSS）。'
                : '推荐：控制端自动发现被控端并建立 P2P 直连，无需任何服务器。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          // §B P2P 模式隐藏 broker host/port/WSS/上传 token 等高级字段。
          if (isBroker) ...[
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'Broker 地址 (IP / 主机名)',
                hintText: '如 192.168.1.10',
                helperText: '0.0.0.0 / :: 是服务端监听地址，不能作为 broker 地址',
                prefixIcon: Icon(Icons.dns),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              onChanged: (_) {
                if (_portError != null) setState(() => _portError = null);
              },
              decoration: InputDecoration(
                labelText: '端口 (WS 8770 / WSS 8771)',
                errorText: _portError,
                prefixIcon: const Icon(Icons.numbers),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('使用 WSS (TLS)'),
              subtitle: const Text('broker 配置了证书时启用'),
              value: _secure,
              onChanged: (v) => setState(() => _secure = v),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _mediaUploadToken,
              obscureText: !_mediaUploadTokenVisible,
              decoration: InputDecoration(
                labelText: '媒体上传 token（可选）',
                helperText: 'broker 配置 media_upload_token 时填写；留空保持开放上传兼容',
                prefixIcon: const Icon(Icons.upload_file),
                suffixIcon: IconButton(
                  icon: Icon(_mediaUploadTokenVisible
                      ? Icons.visibility_off
                      : Icons.visibility),
                  onPressed: () => setState(() =>
                      _mediaUploadTokenVisible = !_mediaUploadTokenVisible),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          // PSK 两种模式都可用（P2P 下控制端兼任协调端，PSK 决定 auth_mode）。
          TextField(
            controller: _psk,
            obscureText: !_pskVisible,
            decoration: InputDecoration(
              labelText: 'PSK (预置共享密钥, 32+ 字节)',
              helperText: isBroker
                  ? 'broker 鉴权用'
                  : 'P2P 下留空为开放模式；填写则本端兼任协调端启用鉴权',
              prefixIcon: const Icon(Icons.key),
              suffixIcon: IconButton(
                icon: Icon(
                    _pskVisible ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _pskVisible = !_pskVisible),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // controller_id 属高级身份，保留可用但非首要。
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: const Text('高级 · 控制端身份'),
            children: [
              TextField(
                controller: _ctlId,
                decoration: const InputDecoration(
                  labelText: 'controller_id',
                  prefixIcon: Icon(Icons.badge),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.save),
            label: const Text('保存并重连'),
            onPressed: () => _save(state),
          ),
          if (isBroker) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.hub),
              label: const Text('批量迁移播放端到此 Broker'),
              onPressed: () => _startBulkBrokerMigration(state),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('清除播放端 Broker 并还原 P2P'),
              onPressed: () => _startP2pRestore(state),
            ),
            const SizedBox(height: 6),
            Text(
              '迁移：先验证 Broker 可达，再逐台写入。还原：必须先通过当前 Broker '
              '清除播放端配置，收到持久化确认后控制端才切回 P2P。直接只切控制端会连接失败。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Text('诊断日志', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('复制全部'),
                onPressed: () async {
                  final text = state.logLines.join('\n');
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('已复制 ${state.logLines.length} 行日志到剪贴板')),
                    );
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          _LogView(lines: state.logLines),
        ],
      ),
    );
  }

  Future<void> _startP2pRestore(WallState state) async {
    if (state.connectionMode != ConnectionMode.broker || state.isP2p) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('请先保持 Controller 与播放端连接在当前 Broker 模式')));
      return;
    }
    final eligible = state.devices
        .where((d) => d.online &&
            (d.configCapabilities?.supportsTransportConfigure ?? false))
        .toList(growable: false);
    if (eligible.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('当前 Broker 上没有在线且支持还原 P2P 的播放端')));
      return;
    }
    final selected = await _selectBrokerMigrationDevices(
      context,
      eligible,
      title: '选择一台要还原到 P2P 的播放端',
      confirmLabel: '清除并还原',
      singleSelection: true,
    );
    if (!mounted || selected == null || selected.isEmpty) return;
    if (selected.length != 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('请每次只还原一台播放端，确认 P2P 连接后再处理下一台')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('还原到 P2P'),
        content: const Text('将先通过当前 Broker 清除所选播放端的 Broker 配置，'
            '收到持久化回读后，再把控制端切换到自动发现/P2P。请勿中途关闭应用。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始还原')),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final future = state.restoreDevicesToP2p(selected);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('还原 P2P'),
        content: FutureBuilder<Map<String, String>>(
          future: future,
          builder: (ctx, snapshot) {
            if (!snapshot.hasData && snapshot.error == null) {
              return const Row(children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Expanded(child: Text('正在清除 Broker 配置并验证 P2P…')),
              ]);
            }
            if (snapshot.error != null) return Text('还原失败：${snapshot.error}');
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: snapshot.data!.entries
                  .map((e) => Text('${e.key}：${e.value}'))
                  .toList(growable: false),
            );
          },
        ),
        actions: [
          FutureBuilder<Map<String, String>>(
            future: future,
            builder: (ctx, snapshot) => TextButton(
              onPressed: snapshot.connectionState == ConnectionState.done
                  ? () => Navigator.pop(ctx)
                  : null,
              child: const Text('完成'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startBulkBrokerMigration(WallState state) async {
    final portResult = validateBrokerPort(_port.text);
    if (!portResult.ok) {
      setState(() => _portError = portResult.error);
      return;
    }
    final host = _host.text.trim();
    if (host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写 Broker 地址')),
      );
      return;
    }
    if (_psk.text != state.psk) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('PSK 输入框有未生效改动。批量迁移要求 Broker 使用设备当前已有的 PSK。')),
      );
      return;
    }
    final eligible = state.devices
        .where((d) => d.online &&
            (d.configCapabilities?.supportsTransportConfigure ?? false))
        .toList(growable: false);
    if (eligible.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('没有在线且支持批量 Broker 配置的播放端；请先升级到 1.18.7')),
      );
      return;
    }
    final selected = await _selectBrokerMigrationDevices(context, eligible);
    if (!mounted || selected == null || selected.isEmpty) return;
    final future = state.migrateDevicesToBroker(
      deviceIds: selected,
      host: host,
      port: portResult.port!,
      secure: _secure,
    );
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BrokerMigrationProgressDialog(
        state: state,
        initialFuture: future,
        deviceIds: selected,
        host: host,
        port: portResult.port!,
        secure: _secure,
      ),
    );
  }
}

Future<Set<String>?> _selectBrokerMigrationDevices(
  BuildContext context,
  List<DeviceStatus> devices, {
  String title = '选择要迁移的播放端',
  String confirmLabel = '开始迁移',
  bool singleSelection = false,
}) async {
  final selected = singleSelection
      ? <String>{}
      : devices.map((d) => d.deviceId).toSet();
  return showDialog<Set<String>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!singleSelection) Row(children: [
                TextButton(
                  onPressed: () => setLocal(() {
                    selected
                      ..clear()
                      ..addAll(devices.map((d) => d.deviceId));
                  }),
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: () => setLocal(selected.clear),
                  child: const Text('清空'),
                ),
                const Spacer(),
                Text('已选 ${selected.length}/${devices.length}'),
              ]),
              if (!singleSelection) Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final group in ({
                      for (final d in devices) d.groupId,
                    }.toList()..sort()))
                      FilterChip(
                        label: Text(group.isEmpty ? '未分组' : group),
                        selected: devices
                            .where((d) => d.groupId == group)
                            .every((d) => selected.contains(d.deviceId)),
                        onSelected: (enabled) => setLocal(() {
                          final ids = devices
                              .where((d) => d.groupId == group)
                              .map((d) => d.deviceId);
                          if (enabled) {
                            selected.addAll(ids);
                          } else {
                            selected.removeAll(ids);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              const Divider(),
              SizedBox(
                height: 360,
                child: ListView(
                  children: [
                    for (final d in devices)
                      CheckboxListTile(
                        dense: true,
                        value: selected.contains(d.deviceId),
                        title: Text(d.deviceName?.isNotEmpty == true
                            ? d.deviceName!
                            : d.deviceId),
                        subtitle: Text(
                            '${d.deviceId} · ${d.groupId} · ${d.appVersion ?? "未知版本"}'),
                        onChanged: (v) => setLocal(() {
                          if (v == true) {
                            if (singleSelection) selected.clear();
                            selected.add(d.deviceId);
                          } else {
                            selected.remove(d.deviceId);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.pop(ctx, Set<String>.from(selected)),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  );
}

class _BrokerMigrationProgressDialog extends StatefulWidget {
  const _BrokerMigrationProgressDialog({
    required this.state,
    required this.initialFuture,
    required this.deviceIds,
    required this.host,
    required this.port,
    required this.secure,
  });

  final WallState state;
  final Future<BrokerMigrationBatch> initialFuture;
  final Set<String> deviceIds;
  final String host;
  final int port;
  final bool secure;

  @override
  State<_BrokerMigrationProgressDialog> createState() =>
      _BrokerMigrationProgressDialogState();
}

class _BrokerMigrationProgressDialogState
    extends State<_BrokerMigrationProgressDialog> {
  late Future<BrokerMigrationBatch> _future;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _track(widget.initialFuture);
  }

  void _track(Future<BrokerMigrationBatch> future) {
    _future = future;
    _done = false;
    future.whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final batch = widget.state.bulkBrokerMigration;
        return AlertDialog(
          title: Text(
              '批量迁移 · ${widget.secure ? "WSS" : "WS"}://${widget.host}:${widget.port}'),
          content: SizedBox(
            width: 620,
            height: 380,
            child: FutureBuilder<BrokerMigrationBatch>(
              future: _future,
              builder: (context, snap) {
                if (batch == null) return const LinearProgressIndicator();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!_done) const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(
                      '预检: ${batch.preflightPassed ? "通过" : batch.fatalError ?? "进行中"} · '
                      '已写入 ${batch.count(BrokerMigrationPhase.applied)} · '
                      '已上线 ${batch.count(BrokerMigrationPhase.connected)} · '
                      '失败 ${batch.count(BrokerMigrationPhase.failed)}',
                    ),
                    const Divider(),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final d in batch.devices.values)
                            ListTile(
                              dense: true,
                              leading: Icon(
                                d.phase == BrokerMigrationPhase.connected
                                    ? Icons.check_circle
                                    : d.phase == BrokerMigrationPhase.failed
                                        ? Icons.error
                                        : d.phase == BrokerMigrationPhase.applied
                                            ? Icons.cloud_done
                                            : Icons.sync,
                                color: d.phase == BrokerMigrationPhase.connected
                                    ? Colors.green
                                    : d.phase == BrokerMigrationPhase.failed
                                        ? Colors.red
                                        : null,
                              ),
                              title: Text(d.deviceId),
                              subtitle: Text(d.detail.isEmpty
                                  ? d.phase.name
                                  : d.detail),
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            if (_done &&
                batch != null &&
                (batch.failedDeviceIds.isNotEmpty || batch.fatalError != null))
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: Text(batch.controllerSwitched
                    ? '回到 P2P 并重试失败项'
                    : '只重试失败项'),
                onPressed: () => setState(() {
                  batch.fatalError = null;
                  if (batch.controllerSwitched) {
                    _track(widget.state.recoverP2pAndRetryBrokerMigration());
                  } else {
                    _track(widget.state.migrateDevicesToBroker(
                      deviceIds: widget.deviceIds,
                      host: widget.host,
                      port: widget.port,
                      secure: widget.secure,
                      retryCurrent: true,
                    ));
                  }
                }),
              ),
            if (_done)
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(batch?.allConnected == true ? '完成' : '稍后处理'),
              ),
          ],
        );
      },
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.lines});
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
      ),
      child: lines.isEmpty
          ? const Center(child: Text('暂无日志'))
          : ListView.builder(
              reverse: true,
              itemCount: lines.length,
              itemBuilder: (context, i) {
                final line = lines[lines.length - 1 - i];
                return SelectableText(line,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12));
              },
            ),
    );
  }
}
