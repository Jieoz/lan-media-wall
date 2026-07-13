import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:remote_flutter/state/wall_state.dart';
import 'package:remote_flutter/ui/responsive_shell.dart';

void main() {
  testWidgets('settings dialog survives ordinary pause and resume', (tester) async {
    final state = WallState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<WallState>.value(
        value: state,
        child: const MaterialApp(home: ResponsiveShell()),
      ),
    );

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsWidgets);
    expect(find.byType(Dialog), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('设置'), findsWidgets);
  });
}
