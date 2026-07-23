import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/messages.dart';
import 'package:remote_flutter/state/runtime_mode_request_tracker.dart';
import 'package:remote_flutter/state/wall_state.dart';

WallState stateWithVisualDevice() {
  final state = WallState();
  state.debugIngestWall(const WallSnapshot(devices: [
    DeviceStatus(
      deviceId: 'd1',
      groupId: 'default',
      state: 'playing',
      online: true,
      runtimeMode: RuntimeMode.visual,
      capabilities: ['runtime_modes_v1'],
    ),
  ]));
  return state;
}

void main() {
  test('only newest request for one device is admitted in either reply order', () {
    final tracker = RuntimeModeRequestTracker()
      ..register(requestId: 'old', deviceId: 'd1')
      ..register(requestId: 'new', deviceId: 'd1');

    expect(
      tracker.settle(requestId: 'old', actualDeviceId: 'd1'),
      RuntimeModeReplyAdmission.superseded,
    );
    expect(
      tracker.settle(requestId: 'new', actualDeviceId: 'd1'),
      RuntimeModeReplyAdmission.accept,
    );

    final reverse = RuntimeModeRequestTracker()
      ..register(requestId: 'old', deviceId: 'd1')
      ..register(requestId: 'new', deviceId: 'd1');
    expect(
      reverse.settle(requestId: 'new', actualDeviceId: 'd1'),
      RuntimeModeReplyAdmission.accept,
    );
    expect(
      reverse.settle(requestId: 'old', actualDeviceId: 'd1'),
      RuntimeModeReplyAdmission.superseded,
    );
  });

  test('wrong-device, unknown and replayed replies fail closed', () {
    final tracker = RuntimeModeRequestTracker()
      ..register(requestId: 'r1', deviceId: 'd1');

    expect(
      tracker.settle(requestId: 'r1', actualDeviceId: 'd2'),
      RuntimeModeReplyAdmission.staleOrDeviceMismatch,
    );
    expect(tracker.latestForDevice('d1'), isNull);
    expect(
      tracker.settle(requestId: 'r1', actualDeviceId: 'd1'),
      RuntimeModeReplyAdmission.staleOrDeviceMismatch,
    );
    expect(
      tracker.settle(requestId: 'unknown', actualDeviceId: 'd1'),
      RuntimeModeReplyAdmission.staleOrDeviceMismatch,
    );
  });

  test('cancel rejects timeout-late reply without cancelling newer request', () {
    final tracker = RuntimeModeRequestTracker()
      ..register(requestId: 'old', deviceId: 'd1')
      ..register(requestId: 'new', deviceId: 'd1');

    tracker.cancel('old');
    expect(tracker.contains('old'), isFalse);
    expect(tracker.latestForDevice('d1'), 'new');
    expect(
      tracker.settle(requestId: 'old', actualDeviceId: 'd1'),
      RuntimeModeReplyAdmission.staleOrDeviceMismatch,
    );
    expect(
      tracker.settle(requestId: 'new', actualDeviceId: 'd1'),
      RuntimeModeReplyAdmission.accept,
    );
  });

  test('cancelling latest request clears its authority', () {
    final tracker = RuntimeModeRequestTracker()
      ..register(requestId: 'r1', deviceId: 'd1');

    tracker.cancel('r1');
    expect(tracker.latestForDevice('d1'), isNull);
    expect(
      tracker.settle(requestId: 'r1', actualDeviceId: 'd1'),
      RuntimeModeReplyAdmission.staleOrDeviceMismatch,
    );
  });

  testWidgets('latest failure completes but does not mutate wall mode',
      (tester) async {
    final state = stateWithVisualDevice()..debugHoldOutboundRuntimeMode = true;
    addTearDown(state.dispose);
    final future = state.setDeviceRuntimeMode('d1', RuntimeMode.music);
    final requestId = state.debugLatestRuntimeModeRequestFor('d1')!;

    state.debugIngestRuntimeModeResult({
      'request_id': requestId,
      'device_id': 'd1',
      'ok': false,
      'error': 'player-rejected',
    });
    final result = await future;
    expect(result.ok, isFalse);
    expect(state.deviceById('d1')!.runtimeMode, RuntimeMode.visual);
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('out-of-order result cannot roll back newer confirmed wall mode',
      (tester) async {
    final state = stateWithVisualDevice()..debugHoldOutboundRuntimeMode = true;
    addTearDown(state.dispose);
    final oldFuture = state.setDeviceRuntimeMode('d1', RuntimeMode.standby);
    final oldId = state.debugLatestRuntimeModeRequestFor('d1')!;
    final newFuture = state.setDeviceRuntimeMode('d1', RuntimeMode.music);
    final newId = state.debugLatestRuntimeModeRequestFor('d1')!;

    state.debugIngestRuntimeModeResult({
      'request_id': newId,
      'device_id': 'd1',
      'ok': true,
      'runtime_mode': 'music',
    });
    state.debugIngestRuntimeModeResult({
      'request_id': oldId,
      'device_id': 'd1',
      'ok': true,
      'runtime_mode': 'standby',
    });
    expect((await newFuture).ok, isTrue);
    final oldResult = await oldFuture;
    expect(oldResult.ok, isFalse);
    expect(oldResult.error, 'superseded');
    expect(state.deviceById('d1')!.runtimeMode, RuntimeMode.music);
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('timeout cancels authority and late success is ignored',
      (tester) async {
    final state = stateWithVisualDevice()..debugHoldOutboundRuntimeMode = true;
    addTearDown(state.dispose);
    final future = state.setDeviceRuntimeMode('d1', RuntimeMode.music);
    final requestId = state.debugLatestRuntimeModeRequestFor('d1')!;

    await tester.pump(const Duration(seconds: 11));
    final timeout = await future;
    expect(timeout.ok, isFalse);
    expect(timeout.error, 'timeout');
    state.debugIngestRuntimeModeResult({
      'request_id': requestId,
      'device_id': 'd1',
      'ok': true,
      'runtime_mode': 'music',
    });
    expect(state.deviceById('d1')!.runtimeMode, RuntimeMode.visual);
  });

  test('send failure clears pending authority immediately', () async {
    final state = stateWithVisualDevice();
    addTearDown(state.dispose);

    await expectLater(
      state.setDeviceRuntimeMode('d1', RuntimeMode.music),
      throwsA(isA<StateError>()),
    );
    expect(state.debugLatestRuntimeModeRequestFor('d1'), isNull);
    expect(state.deviceById('d1')!.runtimeMode, RuntimeMode.visual);
  });
}
