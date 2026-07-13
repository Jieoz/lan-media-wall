import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/net/media_upload.dart';

void main() {
  test('MediaRequestGate validates runtime limits', () {
    expect(() => MediaRequestGate(0), throwsArgumentError);
    expect(() => MediaRequestGate(-1), throwsArgumentError);
    expect(() => MediaRequestGate(1, maxQueued: -1), throwsArgumentError);
  });

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

  test('close immediately releases every waiter and rejects new work', () async {
    final gate = MediaRequestGate(1, maxQueued: 3);
    final active = (await gate.acquire())!;
    final waiters = [gate.acquire(), gate.acquire(), gate.acquire()];

    gate.close();

    expect(gate.closed, isTrue);
    expect(gate.queued, 0);
    expect(await Future.wait(waiters), everyElement(isNull));
    expect(await gate.acquire(), isNull);
    active.release();
    expect(gate.active, 0);
  });

  test('a closed generation cannot admit waiters into a replacement gate', () async {
    final oldGate = MediaRequestGate(1);
    final oldPermit = (await oldGate.acquire())!;
    final oldWaiter = oldGate.acquire();
    oldGate.close();

    final newGate = MediaRequestGate(1);
    final newPermit = await newGate.acquire();
    oldPermit.release();

    expect(await oldWaiter, isNull);
    expect(newPermit, isNotNull);
    expect(oldGate.active, 0);
    expect(newGate.active, 1);
    newPermit!.release();
  });
}
