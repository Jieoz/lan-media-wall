enum BrokerMigrationPhase { pending, applying, applied, connected, failed }

class BrokerTarget {
  const BrokerTarget({
    required this.host,
    required this.port,
    required this.secure,
  });

  final String host;
  final int port;
  final bool secure;

  String get endpoint => Uri(
        scheme: secure ? 'wss' : 'ws',
        host: host,
        port: port,
      ).toString();
}

class BrokerMigrationDevice {
  const BrokerMigrationDevice({
    required this.deviceId,
    this.phase = BrokerMigrationPhase.pending,
    this.detail = '',
  });

  final String deviceId;
  final BrokerMigrationPhase phase;
  final String detail;

  BrokerMigrationDevice withPhase(BrokerMigrationPhase next, [String detail = '']) =>
      BrokerMigrationDevice(deviceId: deviceId, phase: next, detail: detail);
}

class BrokerMigrationBatch {
  BrokerMigrationBatch({
    required this.target,
    required Iterable<String> deviceIds,
  }) : devices = {
          for (final id in deviceIds) id: BrokerMigrationDevice(deviceId: id),
        };

  final BrokerTarget target;
  final Map<String, BrokerMigrationDevice> devices;
  bool preflightPassed = false;
  bool controllerSwitched = false;
  String? fatalError;

  int count(BrokerMigrationPhase phase) =>
      devices.values.where((d) => d.phase == phase).length;

  Iterable<String> get failedDeviceIds => devices.values
      .where((d) => d.phase == BrokerMigrationPhase.failed)
      .map((d) => d.deviceId);

  bool get allApplied => devices.isNotEmpty && devices.values.every((d) =>
      d.phase == BrokerMigrationPhase.applied ||
      d.phase == BrokerMigrationPhase.connected);

  bool get allConnected => devices.isNotEmpty && devices.values.every(
      (d) => d.phase == BrokerMigrationPhase.connected);
}

typedef BrokerProbe = Future<void> Function(BrokerTarget target);
typedef ApplyBrokerTarget = Future<void> Function(
    String deviceId, BrokerTarget target);
typedef SwitchControllerToBroker = Future<void> Function(BrokerTarget target);
typedef BrokerDeviceConnected = bool Function(
    String deviceId, BrokerTarget target);
typedef MigrationChanged = void Function(BrokerMigrationBatch batch);
typedef MigrationDelay = Future<void> Function(Duration duration);

/// Transactional fleet migration:
///
/// 1. Prove that the target broker socket is reachable before touching a box.
/// 2. Apply in bounded chunks, waiting for each Player's config_patch_result.
/// 3. If any box rejects/times out, stay on P2P so only failures can be retried.
/// 4. Switch the controller only after every selected box acknowledged persistence.
/// 5. Mark success only after each box is online through the target broker and its
///    config snapshot echoes the exact endpoint.
class BrokerMigrationRunner {
  BrokerMigrationRunner({
    required this.probe,
    required this.apply,
    required this.switchController,
    required this.isConnected,
    MigrationDelay? delay,
  }) : delay = delay ?? Future<void>.delayed;

  final BrokerProbe probe;
  final ApplyBrokerTarget apply;
  final SwitchControllerToBroker switchController;
  final BrokerDeviceConnected isConnected;
  final MigrationDelay delay;

  Future<BrokerMigrationBatch> run({
    required BrokerMigrationBatch batch,
    MigrationChanged? onChanged,
    int concurrency = 4,
    Duration reconnectTimeout = const Duration(seconds: 45),
    Duration pollInterval = const Duration(milliseconds: 500),
  }) async {
    if (batch.devices.isEmpty) {
      batch.fatalError = '未选择设备';
      onChanged?.call(batch);
      return batch;
    }
    if (!batch.preflightPassed) {
      try {
        await probe(batch.target);
        batch.preflightPassed = true;
      } catch (e) {
        batch.fatalError = 'Broker 预检失败: $e';
        onChanged?.call(batch);
        return batch;
      }
    }

    // Keep successful boxes committed across retry runs; only pending/failed boxes
    // are sent again. This prevents a second transport rebuild on boxes that have
    // already left P2P.
    final remaining = batch.devices.values
        .where((d) => d.phase == BrokerMigrationPhase.pending ||
            d.phase == BrokerMigrationPhase.failed)
        .map((d) => d.deviceId)
        .toList(growable: false);
    final width = concurrency.clamp(1, 16).toInt();
    for (var i = 0; i < remaining.length; i += width) {
      final chunk = remaining.skip(i).take(width).toList(growable: false);
      for (final id in chunk) {
        batch.devices[id] = batch.devices[id]!
            .withPhase(BrokerMigrationPhase.applying, '等待播放端确认');
      }
      onChanged?.call(batch);
      await Future.wait(chunk.map((id) async {
        try {
          await apply(id, batch.target);
          batch.devices[id] = batch.devices[id]!
              .withPhase(BrokerMigrationPhase.applied, '已写入，等待转接 Broker');
        } catch (e) {
          batch.devices[id] = batch.devices[id]!
              .withPhase(BrokerMigrationPhase.failed, e.toString());
        }
        onChanged?.call(batch);
      }));
    }

    if (!batch.allApplied) {
      // Deliberately do not switch the controller: failed boxes are still reachable
      // on P2P and can be retried without stranding the operator.
      return batch;
    }

    if (!batch.controllerSwitched) {
      try {
        await switchController(batch.target);
        batch.controllerSwitched = true;
        onChanged?.call(batch);
      } catch (e) {
        batch.fatalError = '控制端切换 Broker 失败: $e';
        onChanged?.call(batch);
        return batch;
      }
    }

    final deadline = DateTime.now().add(reconnectTimeout);
    while (DateTime.now().isBefore(deadline)) {
      for (final id in batch.devices.keys) {
        if (isConnected(id, batch.target)) {
          batch.devices[id] = batch.devices[id]!
              .withPhase(BrokerMigrationPhase.connected, '已通过目标 Broker 上线');
        }
      }
      onChanged?.call(batch);
      if (batch.allConnected) return batch;
      await delay(pollInterval);
    }
    for (final id in batch.devices.keys) {
      if (batch.devices[id]!.phase != BrokerMigrationPhase.connected) {
        batch.devices[id] = batch.devices[id]!
            .withPhase(BrokerMigrationPhase.failed, 'Broker 重连/配置回读超时');
      }
    }
    onChanged?.call(batch);
    return batch;
  }
}
