/// Tracks which Players are mid-transport-rebuild, so the device wall can stop
/// trusting a stale Broker-side `online` flag during that window.
///
/// Why this exists (field bug): the wall computed `phase: status.online ? connected
/// : ...` straight from the Broker's state-wall snapshot. When an operator pushes
/// a `transport_configure`, the Player answers on the OLD link, then tears that
/// link down and rebuilds. The Broker's registry keeps reporting `online=true`
/// for its own expiry window, so the Controller painted a green "已连接" card for a
/// box it could not actually reach — an optimistic claim contradicted by the live
/// link. Worse, the unconditional `status.online` override also erased the locally
/// observed [LinkPhase] from the direct-link callbacks.
///
/// Fail-closed rule implemented here: while a device is inside its migration
/// window, Broker-reported `online` is NOT sufficient evidence of reachability.
/// Only a real local link observation (or the window closing) may restore the
/// connected phase.
///
/// The window opens when a transport change is dispatched and closes when either
/// the live link reports a terminal state for that device, or [maxWindow] elapses
/// so a lost reply can never pin a device to "reconnecting" forever.
class TransportMigrationWindow {
  TransportMigrationWindow({this.maxWindow = const Duration(seconds: 45), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Duration maxWindow;
  final DateTime Function() _clock;
  final Map<String, DateTime> _openedAt = {};

  /// Marks [deviceId] as rebuilding its transport. Called when the controller
  /// dispatches a transport change, before the Player tears the old link down.
  void open(String deviceId) {
    _openedAt[deviceId] = _clock();
  }

  /// Clears the window for [deviceId] — a live link observation arrived, so the
  /// local phase is authoritative again.
  void close(String deviceId) {
    _openedAt.remove(deviceId);
  }

  /// True while Broker-reported `online` must not be treated as reachability for
  /// [deviceId]. Expired windows are pruned so this stays self-healing.
  bool isMigrating(String deviceId) {
    final opened = _openedAt[deviceId];
    if (opened == null) return false;
    if (_clock().difference(opened) >= maxWindow) {
      _openedAt.remove(deviceId);
      return false;
    }
    return true;
  }

  /// Device ids currently inside the migration window (test/diagnostic use).
  ///
  /// Iterates a snapshot of the keys because [isMigrating] prunes expired entries
  /// as a side effect; walking the live key view would throw
  /// ConcurrentModificationError the moment anything expired.
  Set<String> get migratingIds =>
      _openedAt.keys.toList(growable: false).where(isMigrating).toSet();
}
