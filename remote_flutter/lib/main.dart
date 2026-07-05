import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/wall_state.dart';
import 'ui/responsive_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MediaWallApp());
}

/// 遥控端 app 入口:注入 [WallState]。UI 以**横屏平板为主场景**,
/// 由 [ResponsiveShell] 按宽度自适应(宽屏双栏并置 / 窄屏底部导航)。
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
        home: const ResponsiveShell(),
      ),
    );
  }
}
