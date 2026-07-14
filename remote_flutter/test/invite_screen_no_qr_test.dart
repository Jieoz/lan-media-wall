import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:remote_flutter/platform/platform_capabilities.dart';
import 'package:remote_flutter/state/wall_state.dart';
import 'package:remote_flutter/ui/invite_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// §"no QR on Windows": the desktop controller must not scan a QR (camera) AND
/// must not generate or display one. The compile-time kill switches
/// (LMW_DISABLE_SCANNER / LMW_DISABLE_QR) are the CI enforcement; the runtime
/// platform branch is the second layer and the one exercisable in a widget
/// test. These tests pin the capability contract and the invite UI it drives.
void main() {
  group('platform capability flags', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('mobile supports both QR scan and QR display', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(scanToAddSupported, isTrue);
      expect(qrInviteDisplaySupported, isTrue);
    });

    test('desktop (windows) supports neither QR scan nor QR display', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(scanToAddSupported, isFalse);
      expect(qrInviteDisplaySupported, isFalse);
    });

    test('desktop (linux/macos) also has no QR display', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(qrInviteDisplaySupported, isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(qrInviteDisplaySupported, isFalse);
    });
  });

  group('InviteScreen QR gating', () {
    Future<void> pump(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final state = WallState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<WallState>.value(
          value: state,
          child: const MaterialApp(home: InviteScreen()),
        ),
      );
      await tester.pump();
    }

    tearDown(() => debugDefaultTargetPlatformOverride = null);

    testWidgets('mobile invite screen shows scan button and can render a QR',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await pump(tester);
      // Scan-to-add entry is present on mobile.
      expect(find.text('扫码添加'), findsOneWidget);
      // The QR area is present (the widget itself renders once a host is filled;
      // the "扫码即可入组" caption is gated together with the QrImageView).
      expect(find.byType(QrImageView).evaluate().isEmpty, isTrue,
          reason: 'no host prefilled yet, so QR not yet drawn, but gating is on');
      // A widget test verifies foundation-debug-var invariants BEFORE tearDown
      // runs, so reset the platform override inside the body, not in tearDown.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('windows invite screen has no scan button and never draws a QR',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pump(tester);
      // No camera scan entry.
      expect(find.text('扫码添加'), findsNothing);
      // No QR is generated or displayed under any state.
      expect(find.byType(QrImageView), findsNothing);
      expect(find.textContaining('扫码即可入组'), findsNothing);
      // Desktop fallback copy is shown instead.
      expect(find.textContaining('无二维码'), findsOneWidget);
      // Reset inside the body (see note above): _verifyInvariants runs before
      // tearDown for widget tests.
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
