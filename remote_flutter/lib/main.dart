import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/wall_state.dart';
import 'ui/control_panel.dart';
import 'ui/settings_screen.dart';
import 'ui/wall_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MediaWallApp());
}

/// 遥控端 app 入口：注入 [WallState]，底部导航在设备墙 / 控制 / 设置间切换。
class MediaWallApp extends StatelessWidget {
  const MediaWallApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<WallState>(
      create: (_) => WallState()..init(),
      child: MaterialApp(
        title: 'LAN Media Wall',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const HomeShell(),
      ),
    );
  }
}

/// 三页骨架：设备墙 / 控制 / 设置。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _pages = <Widget>[
    WallScreen(),
    ControlPanel(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
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
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: '控制',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
