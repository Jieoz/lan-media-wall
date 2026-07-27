import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/state/transport_migration_window.dart';

void main() {
  group('TransportMigrationWindow', () {
    test('untracked device is not migrating', () {
      final w = TransportMigrationWindow();
      expect(w.isMigrating('and-1'), isFalse);
    });

    test('open marks the device as migrating', () {
      final w = TransportMigrationWindow();
      w.open('and-1');
      expect(w.isMigrating('and-1'), isTrue);
      // Only the targeted device: a transport push must not blank other cards.
      expect(w.isMigrating('and-2'), isFalse);
    });

    test('close clears the window (live link observation wins)', () {
      final w = TransportMigrationWindow();
      w.open('and-1');
      w.close('and-1');
      expect(w.isMigrating('and-1'), isFalse);
    });

    test('window expires so a lost reply cannot pin a device forever', () {
      var now = DateTime(2026, 7, 27, 12, 0, 0);
      final w = TransportMigrationWindow(
          maxWindow: const Duration(seconds: 45), clock: () => now);
      w.open('and-1');
      now = now.add(const Duration(seconds: 44));
      expect(w.isMigrating('and-1'), isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(w.isMigrating('and-1'), isFalse);
    });

    test('expired entries are pruned from migratingIds', () {
      var now = DateTime(2026, 7, 27, 12, 0, 0);
      final w = TransportMigrationWindow(
          maxWindow: const Duration(seconds: 10), clock: () => now);
      w.open('and-1');
      w.open('and-2');
      expect(w.migratingIds, {'and-1', 'and-2'});
      now = now.add(const Duration(seconds: 11));
      expect(w.migratingIds, isEmpty);
    });

    test('reopening after expiry restarts the window', () {
      var now = DateTime(2026, 7, 27, 12, 0, 0);
      final w = TransportMigrationWindow(
          maxWindow: const Duration(seconds: 10), clock: () => now);
      w.open('and-1');
      now = now.add(const Duration(seconds: 11));
      expect(w.isMigrating('and-1'), isFalse);
      w.open('and-1');
      expect(w.isMigrating('and-1'), isTrue);
    });
  });
}
