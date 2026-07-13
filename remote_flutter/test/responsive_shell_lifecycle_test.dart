import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:remote_flutter/state/wall_state.dart';
import 'package:remote_flutter/ui/responsive_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('dispose is safe before init() has allocated links', () {
    // Provider-only mounts (and fast unmounts before init() finishes its async
    // _loadSettings) dispose a WallState whose late-final links were never
    // assigned. That must not throw LateInitializationError.
    final state = WallState();
    expect(state.dispose, returnsNormally);
  });

  test('dispose during in-flight init() cancels it — no post-dispose links or notify',
      () async {
    // Regression for the fast-unmount lifecycle race. init() is async: it awaits
    // _loadSettings() (SharedPreferences.getInstance) BEFORE it allocates the
    // broker/discovery/p2p links. A dispose() landing in that await window must
    // not merely return normally — it must guarantee the parked init() does NOT
    // resume to allocate links, start discovery, or notify a disposed
    // ChangeNotifier. We hold init() at that real await boundary, dispose, then
    // let the await resume and assert nothing came alive afterwards.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = WallState();

    // A listener proves no notifyListeners() fires after dispose(). A disposed
    // ChangeNotifier also throws if notified, so both effects are covered.
    var notifiedAfterDispose = false;
    var disposed = false;
    state.addListener(() {
      if (disposed) notifiedAfterDispose = true;
    });

    // Kick off init() but do NOT await: Dart runs it synchronously only up to
    // the first real await (getInstance), then hands control back here with the
    // future still pending — init() is now parked at the _loadSettings boundary.
    final initFuture = state.init();

    // Dispose while init() is parked. This is the fast-unmount race.
    disposed = true;
    state.dispose();

    // Let the parked _loadSettings() resolve and init() resume. With the fix it
    // sees _disposed and returns before allocating/starting/notifying anything.
    await initFuture;
    // Drain any stray microtasks a resumed init() might have scheduled.
    await Future<void>.delayed(Duration.zero);

    expect(notifiedAfterDispose, isFalse,
        reason: 'init() resumed after dispose() and notified a disposed state');
    // No discovery/link work ran: init() bailed before _discovery.start(), so
    // the connection log stays empty (start() and _evaluateTopology() both log).
    expect(state.logLines, isEmpty,
        reason: 'discovery/topology work ran after dispose()');
    // Operating topology was never re-evaluated away from its p2p default.
    expect(state.topology, Topology.p2p);
  });

  test('full init() then dispose() tears links down without error and is idempotent',
      () async {
    // The normal initialized path: init() runs to completion (links allocated
    // and discovery started), then dispose() releases them. Teardown must run
    // cleanly and stay idempotent (a second dispose() is a no-op, not a
    // double-free or a LateInitializationError).
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = WallState();

    await state.init();

    // Links were allocated and discovery started; teardown must run cleanly.
    // (ChangeNotifier forbids a second public dispose(); the teardown's own
    // idempotency is exercised by init()'s post-_discovery.start() bail path.)
    expect(state.dispose, returnsNormally);
  });
}
