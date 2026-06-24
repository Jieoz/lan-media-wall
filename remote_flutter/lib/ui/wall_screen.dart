import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../net/broker_client.dart';
import '../protocol/auth_mode.dart';
import '../protocol/messages.dart';
import '../state/wall_state.dart';
import 'invite_screen.dart';

/// 设备墙：每台设备一格，展示在线灯、当前文件名、播放进度、音量、当前帧缩略图(§5.2/§6.4)。
class WallScreen extends StatelessWidget {
  const WallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WallState>();
    final devices = state.devices;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备墙'),
        actions: [
          _AuthBadge(mode: state.authMode),
          _TopoBadge(topology: state.topology, peers: state.p2pPeers),
          _ConnBadge(conn: state.conn, isP2p: state.isP2p, connected: state.connected),
          IconButton(
            tooltip: '邀请设备 / 二维码',
            icon: const Icon(Icons.qr_code_2),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const InviteScreen()),
            ),
          ),
          IconButton(
            tooltip: '刷新发现',
            icon: const Icon(Icons.wifi_find),
            onPressed: state.refreshDiscovery,
          ),
          IconButton(
            tooltip: '重连',
            icon: const Icon(Icons.refresh),
            onPressed: state.reconnect,
          ),
        ],
      ),
      body: devices.isEmpty
          ? const _EmptyHint()
          : LayoutBuilder(
              builder: (context, c) {
                final cross = (c.maxWidth / 260).floor().clamp(1, 6);
                return GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cross,
                    childAspectRatio: 0.82,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: devices.length,
                  itemBuilder: (context, i) =>
                      _DeviceCell(device: devices[i]),
                );
              },
            ),
    );
  }
}

class _ConnBadge extends StatelessWidget {
  const _ConnBadge({required this.conn, required this.isP2p, required this.connected});
  final ConnState conn;
  final bool isP2p;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final (color, text) = isP2p
        ? (connected ? Colors.green : Colors.red, connected ? '已连' : '搜寻中')
        : switch (conn) {
            ConnState.connected => (Colors.green, '已连接'),
            ConnState.connecting => (Colors.orange, '连接中'),
            ConnState.disconnected => (Colors.red, '未连接'),
          };
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 10, color: color),
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

/// 鉴权模式徽标（开放 / 可选 / 加密，§13）。
class _AuthBadge extends StatelessWidget {
  const _AuthBadge({required this.mode});
  final AuthMode mode;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (mode) {
      AuthMode.open => (Icons.lock_open, Colors.grey),
      AuthMode.optional => (Icons.lock_outline, Colors.amber),
      AuthMode.required => (Icons.lock, Colors.green),
    };
    return Center(
      child: Tooltip(
        message: '鉴权：${mode.label}',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 3),
              Text(mode.label, style: TextStyle(fontSize: 12, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 拓扑徽标（§14）：p2p 下顺带显示已连台数。
class _TopoBadge extends StatelessWidget {
  const _TopoBadge({required this.topology, required this.peers});
  final Topology topology;
  final int peers;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (topology) {
      Topology.dedicated => (Icons.hub, 'broker'),
      Topology.cohosted => (Icons.device_hub, '寄生'),
      Topology.p2p => (Icons.lan, 'p2p·$peers'),
    };
    return Center(
      child: Tooltip(
        message: topology.label,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14),
              const SizedBox(width: 3),
              Text(label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          '暂无设备。\n请在「设置」配置 broker 地址与 PSK，或点右上角刷新发现。',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _DeviceCell extends StatelessWidget {
  const _DeviceCell({required this.device});
  final DeviceStatus device;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WallState>();
    final thumb = state.thumbOf(device.deviceId);
    final cur = device.current;
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 缩略图区
          Expanded(
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: thumb != null
                  ? Image.memory(thumb, fit: BoxFit.contain, gaplessPlayback: true)
                  : const Icon(Icons.image_not_supported_outlined,
                      color: Colors.white24, size: 36),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.circle,
                        size: 10,
                        color: device.online ? Colors.green : Colors.grey),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        device.deviceName ?? device.deviceId,
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _StateChip(state: device.state),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  cur?.name.isNotEmpty == true ? cur!.name : '—',
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                _Progress(current: cur),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(device.muted ? Icons.volume_off : Icons.volume_up,
                        size: 14),
                    const SizedBox(width: 4),
                    Text('${device.volume}',
                        style: theme.textTheme.bodySmall),
                    if (device.audioMaster) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.campaign, size: 14),
                    ],
                    const Spacer(),
                    Text(device.groupId,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.hintColor)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.current});
  final CurrentItem? current;

  @override
  Widget build(BuildContext context) {
    final pos = current?.positionMs ?? 0;
    final dur = current?.durationMs ?? 0;
    final frac = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: frac, minHeight: 4),
        const SizedBox(height: 2),
        Text('${fmtMs(pos)} / ${fmtMs(dur)}',
            style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});
  final String state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      'playing' => Colors.green,
      'paused' => Colors.amber,
      'buffering' || 'downloading' => Colors.blue,
      _ => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(state, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}
