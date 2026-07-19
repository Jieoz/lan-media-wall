import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/state/wall_state.dart';
import 'package:remote_flutter/ui/connection_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('connection-mode migration (§B)', () {
    test('a stored broker host migrates to broker mode', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'settings.broker_host': '192.168.1.10',
        'settings.broker_port': 8770,
      });
      final ws = WallState();
      addTearDown(ws.dispose);
      await ws.init();
      expect(ws.connectionMode, ConnectionMode.broker);
    });

    test('no stored broker host defaults to auto/P2P mode', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final ws = WallState();
      addTearDown(ws.dispose);
      await ws.init();
      expect(ws.connectionMode, ConnectionMode.autoP2p);
    });

    test('an explicitly-persisted mode wins over host inference', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'settings.broker_host': '192.168.1.10',
        'settings.connection_mode': 'autoP2p',
      });
      final ws = WallState();
      addTearDown(ws.dispose);
      await ws.init();
      expect(ws.connectionMode, ConnectionMode.autoP2p);
    });
  });

  group('connection label reflects live topology (§B)', () {
    test('fresh state (auto/P2P, no peers) is 正在发现设备, not connected', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final ws = WallState();
      addTearDown(ws.dispose);
      await ws.init();
      expect(ws.connectionMode, ConnectionMode.autoP2p);
      expect(ws.connectionStatusLabel, 'P2P · 正在发现设备');
    });
  });
}
