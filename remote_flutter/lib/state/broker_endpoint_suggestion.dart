/// Where a suggested Broker endpoint came from, so the UI can label the prefilled
/// value instead of showing a mystery address the operator cannot vet.
enum BrokerSuggestionSource {
  /// The Broker this controller is currently connected to (most authoritative).
  controllerLink,

  /// The endpoint the target Player already has persisted (good for small edits).
  deviceSnapshot,

  /// The `broker_hint` from the device's UDP announce (weakest signal).
  announceHint,
}

extension BrokerSuggestionSourceLabel on BrokerSuggestionSource {
  String get label => switch (this) {
        BrokerSuggestionSource.controllerLink => '来自当前 Broker 连接',
        BrokerSuggestionSource.deviceSnapshot => '来自该播放端已保存的配置',
        BrokerSuggestionSource.announceHint => '来自设备广播的 broker_hint',
      };
}

/// A prefill candidate for the single-device Broker form.
class BrokerEndpointSuggestion {
  const BrokerEndpointSuggestion({
    required this.host,
    required this.port,
    required this.secure,
    required this.source,
  });

  final String host;
  final int port;
  final bool secure;
  final BrokerSuggestionSource source;
}

/// Resolves what to prefill into the per-device Broker host/port fields.
///
/// Deliberately NOT "the controller's own host address": the controller and the
/// Broker are frequently different machines (field example: Broker 10.10.8.108,
/// Controller 10.10.8.45), and in P2P mode the controller has no Broker address
/// at all. Prefilling the controller's own IP would hand the operator an endpoint
/// no Broker is listening on, and a wrong Broker address costs a lost device.
///
/// Equally forbidden: the *target device's own* address. A Player in P2P mode
/// runs its own local WS server and therefore announces `broker_hint=<its own
/// ip>:8770` (field evidence: `TX announce topology=p2p
/// broker_hint=10.10.8.60:8770` on 10.10.8.60). Prefilling that makes the device
/// its own Broker, which can never connect — the Player rolls the config back
/// (`transport_configure_rollback ... restored=p2p`) and the operator sees "切换
/// Broker 失败" with no idea why. [deviceHost] is therefore excluded from every
/// tier, not just the announce tier.
///
/// Priority, strongest evidence first:
///   1. [controllerHost] — the Broker this controller is actually connected to
///   2. [snapshotHost] — what the Player itself has persisted
///   3. [announceHint] — `host:port` from the device's announce
/// Returns null when nothing trustworthy is known; the caller must then leave the
/// field empty and let the operator type it.
BrokerEndpointSuggestion? suggestBrokerEndpoint({
  String? controllerHost,
  int? controllerPort,
  bool controllerSecure = false,
  bool controllerOnBroker = false,
  String? snapshotHost,
  int? snapshotPort,
  bool? snapshotSecure,
  String? announceHint,
  String? deviceHost,
  int defaultPort = 8770,
}) {
  final selfHost = deviceHost?.trim().toLowerCase();
  bool isSelf(String? host) =>
      selfHost != null &&
      selfHost.isNotEmpty &&
      host != null &&
      host.trim().toLowerCase() == selfHost;
  bool usable(String? host) =>
      host != null && host.trim().isNotEmpty && !isSelf(host);

  if (controllerOnBroker && usable(controllerHost)) {
    return BrokerEndpointSuggestion(
      host: controllerHost!.trim(),
      port: controllerPort ?? defaultPort,
      secure: controllerSecure,
      source: BrokerSuggestionSource.controllerLink,
    );
  }
  if (usable(snapshotHost)) {
    return BrokerEndpointSuggestion(
      host: snapshotHost!.trim(),
      port: snapshotPort ?? defaultPort,
      secure: snapshotSecure ?? false,
      source: BrokerSuggestionSource.deviceSnapshot,
    );
  }
  final hint = announceHint?.trim();
  if (hint != null && hint.isNotEmpty) {
    final parsed = _parseHostPort(hint, defaultPort);
    // A P2P Player announces itself as the broker_hint; that endpoint is the
    // device, not a Broker. Checked here too because the host comes out of the
    // parser rather than through usable() above.
    if (parsed != null && !isSelf(parsed.$1)) {
      return BrokerEndpointSuggestion(
        host: parsed.$1,
        port: parsed.$2,
        secure: false,
        source: BrokerSuggestionSource.announceHint,
      );
    }
  }
  return null;
}

/// Splits `host:port`, tolerating a bare host and bracketed IPv6. Returns null
/// for blank hosts or out-of-range ports rather than guessing.
(String, int)? _parseHostPort(String value, int defaultPort) {
  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    if (close <= 1) return null;
    final host = value.substring(1, close);
    final rest = value.substring(close + 1);
    if (rest.startsWith(':')) {
      final port = int.tryParse(rest.substring(1));
      if (port == null || port < 1 || port > 65535) return null;
      return (host, port);
    }
    return (host, defaultPort);
  }
  final idx = value.lastIndexOf(':');
  if (idx < 0) return (value, defaultPort);
  final host = value.substring(0, idx);
  if (host.trim().isEmpty) return null;
  final port = int.tryParse(value.substring(idx + 1));
  if (port == null || port < 1 || port > 65535) return null;
  return (host, port);
}
