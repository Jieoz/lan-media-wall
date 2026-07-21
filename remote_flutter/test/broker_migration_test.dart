import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/state/broker_migration.dart';

void main() {
  const target = BrokerTarget(host: '10.0.0.8', port: 8770, secure: false);

  test('preflight failure touches no Player and never switches controller', () async {
    var applies = 0;
    var switches = 0;
    final runner = BrokerMigrationRunner(
      probe: (_) async => throw StateError('unreachable'),
      apply: (_, __) async {
        applies++;
      },
      switchController: (_) async {
        switches++;
      },
      isConnected: (_, __) => false,
    );
    final batch = BrokerMigrationBatch(target: target, deviceIds: ['a', 'b']);
    await runner.run(batch: batch);
    expect(batch.fatalError, contains('预检失败'));
    expect(applies, 0);
    expect(switches, 0);
  });

  test('partial failure stays on P2P and retry sends only failed devices', () async {
    final calls = <String>[];
    var failB = true;
    var switches = 0;
    final runner = BrokerMigrationRunner(
      probe: (_) async {},
      apply: (id, _) async {
        calls.add(id);
        if (id == 'b' && failB) throw StateError('timeout');
      },
      switchController: (_) async {
        switches++;
      },
      isConnected: (_, __) => true,
      delay: (_) async {},
    );
    final batch = BrokerMigrationBatch(target: target, deviceIds: ['a', 'b']);
    await runner.run(batch: batch);
    expect(batch.devices['a']!.phase, BrokerMigrationPhase.applied);
    expect(batch.devices['b']!.phase, BrokerMigrationPhase.failed);
    expect(switches, 0);

    failB = false;
    await runner.run(batch: batch);
    expect(calls.where((id) => id == 'a').length, 1);
    expect(calls.where((id) => id == 'b').length, 2);
    expect(switches, 1);
    expect(batch.allConnected, isTrue);
  });

  test('controller switches only after every config result is applied', () async {
    final events = <String>[];
    final runner = BrokerMigrationRunner(
      probe: (_) async => events.add('probe'),
      apply: (id, _) async => events.add('apply:$id'),
      switchController: (_) async => events.add('switch'),
      isConnected: (_, __) => true,
      delay: (_) async {},
    );
    final batch = BrokerMigrationBatch(target: target, deviceIds: ['a', 'b']);
    await runner.run(batch: batch, concurrency: 1);
    expect(events, ['probe', 'apply:a', 'apply:b', 'switch']);
    expect(batch.allConnected, isTrue);
  });
}
