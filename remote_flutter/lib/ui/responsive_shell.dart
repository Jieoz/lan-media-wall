import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/wall_state.dart';
import 'device_wall_pane.dart';
import 'orchestration_pane.dart';
import 'settings_screen.dart';

/// 控制端外壳 —— 横屏平板为主场景(设计合同 §4)。
///
/// 断点(docs/controller-ux-redesign.md §4.0):
///  - **≥ 900dp(平板横屏,主场景)**:左「设备墙栏」固定 + 右「播放编排栏」并置,
///    顶部通栏状态条。分组管理/盒子配置以对话框呈现,不跳页。
///  - **< 900dp(手机竖屏,降级)**:底部导航 + 单列,把两栏拆成两个 Tab。
///
/// 这样同一套 pane 组件在宽窄屏下复用,宽屏并置、窄屏分 Tab。
class ResponsiveShell extends StatelessWidget {
  const ResponsiveShell({super.key});

  /// 宽屏并置的阈值(dp)。≥ 此值走双栏 master-detail。
  static const double wideBreakpoint = 900;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= wideBreakpoint;
        return Scaffold(
          appBar: _StatusBar(wide: wide),
          body: wide ? const _WidePane() : const _NarrowPane(),
        );
      },
    );
  }
}

/// 顶部通栏状态条:连接态 / 拓扑 / 发现计数 + 全局动作(刷新发现、添加设备、设置)。
class _StatusBar extends StatelessWidget implements PreferredSizeWidget {
  const _StatusBar({required this.wide});
  final bool wide;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<WallState>();
    final topo = state.topology.label;
    final online =
        state.wallDevices.where((d) => d.phase == LinkPhase.connected).length;
    final total = state.wallDevices.length;

    final (dotColor, connText) = state.connected
        ? (Colors.greenAccent, '已连接')
        : (state.conn == ConnState.connecting
            ? (Colors.orangeAccent, '连接中')
            : (Colors.redAccent, '未连接'));

    return AppBar(
      title: Row(
        children: [
          Icon(Icons.circle, size: 12, color: dotColor),
          const SizedBox(width: 8),
          const Text('媒体墙遥控'),
          const SizedBox(width: 12),
          if (wide)
            Text(
              '$connText · $topo · 在线 $online/$total',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: '刷新发现',
          icon: const Icon(Icons.refresh),
          onPressed: () {
            state.refreshDiscovery();
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(const SnackBar(content: Text('已重新广播发现')));
          },
        ),
        IconButton(
          tooltip: '设置',
          icon: const Icon(Icons.settings),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => Dialog(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
                child: const SettingsScreen(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 宽屏(平板横屏):左设备墙栏(约 360dp)+ 右编排栏并置。
class _WidePane extends StatelessWidget {
  const _WidePane();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: const [
        SizedBox(
          width: 360,
          child: DeviceWallPane(),
        ),
        VerticalDivider(width: 1),
        Expanded(child: OrchestrationPane()),
      ],
    );
  }
}

/// 窄屏(手机竖屏,降级):底部导航把两栏拆成两 Tab。
class _NarrowPane extends StatefulWidget {
  const _NarrowPane();

  @override
  State<_NarrowPane> createState() => _NarrowPaneState();
}

class _NarrowPaneState extends State<_NarrowPane> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [DeviceWallPane(), OrchestrationPane()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view),
            label: '设备墙',
          ),
          NavigationDestination(
            icon: Icon(Icons.playlist_play_outlined),
            selectedIcon: Icon(Icons.playlist_play),
            label: '播放编排',
          ),
        ],
      ),
    );
  }
}
