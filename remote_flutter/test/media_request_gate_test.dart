import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/net/media_upload.dart';

void main() {
  test('MediaRequestGate admits only the configured number concurrently', () async {
    final gate = MediaRequestGate(2);
    final first = (await gate.acquire())!;
    final second = (await gate.acquire())!;
    var thirdEntered = false;
    final thirdFuture = gate.acquire().then((permit) {
      thirdEntered = true;
      return permit;
    });

    await Future<void>.delayed(Duration.zero);
    expect(gate.active, 2);
    expect(gate.queued, 1);
    expect(thirdEntered, isFalse);

    first.release();
    final third = (await thirdFuture.timeout(const Duration(seconds: 1)))!;
    expect(thirdEntered, isTrue);
    expect(gate.active, 2);
    expect(gate.queued, 0);

    second.release();
    third.release();
    expect(gate.active, 0);
  });

  test('MediaRequestGate rejects beyond its bounded wait queue', () async {
    final gate = MediaRequestGate(1, maxQueued: 1);
    final active = await gate.acquire();
    final waiting = gate.acquire();
    final rejected = await gate.acquire();
    expect(rejected, isNull);
    expect(gate.active, 1);
    expect(gate.queued, 1);
    active!.release();
    final admitted = await waiting;
    expect(admitted, isNotNull);
    admitted!.release();
  });

  test('MediaRequestPermit release is idempotent', () async {
    final gate = MediaRequestGate(1);
    final permit = (await gate.acquire())!;
    permit.release();
    permit.release();
    expect(gate.active, 0);
  });
}
