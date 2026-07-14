/// §6.3 LoopMode — single-source three-mode loop + one legacy fold point.
///
/// Wire contract: a `playlist` payload carries the canonical string field
/// `loop_mode` in {"none","all","one"}. Legacy peers (≤v1.14.13) only send the
/// boolean `loop`. [LoopModeCodec.resolve] is the ONE fold point: `loop_mode`
/// wins when present & valid; otherwise it derives from legacy `loop`
/// (true→all, false/absent→none).
///
/// Senders emit BOTH fields during the compatibility window: `loop_mode`
/// (canonical) plus `loop = (mode != none)` so an un-upgraded player still
/// wraps a looping list (`one` degrades to `all` on old players — harmless).
///
/// Behaviour keyed off the resolved mode (identical Windows/Android/Flutter):
///  - none: playback stops/holds at completion; explicit prev/next clamps.
///  - all : completion and prev/next wrap the whole list.
///  - one : the current item repeats seamlessly on completion; explicit
///          prev/next still navigates (with wrap).
library;

enum LoopMode {
  none('none'),
  all('all'),
  one('one');

  const LoopMode(this.wire);

  /// Canonical wire string for the `loop_mode` field.
  final String wire;

  /// Compat projection emitted alongside `loop_mode` so old players still wrap.
  bool get legacyLoopBool => this != LoopMode.none;
}

class LoopModeCodec {
  const LoopModeCodec._();

  /// The single legacy fold point. Prefer canonical `loop_mode`; else derive
  /// from the legacy boolean `loop`. Unknown strings fall back to the legacy
  /// fold rather than throwing (forward-compat).
  static LoopMode resolve(Map<String, dynamic>? payload) {
    final raw = payload == null ? null : payload['loop_mode'];
    if (raw is String) {
      final v = raw.trim().toLowerCase();
      for (final m in LoopMode.values) {
        if (m.wire == v) return m;
      }
    }
    final legacy = payload != null && payload['loop'] == true;
    return legacy ? LoopMode.all : LoopMode.none;
  }

  static LoopMode fromWire(String? s) {
    if (s != null) {
      final v = s.trim().toLowerCase();
      for (final m in LoopMode.values) {
        if (m.wire == v) return m;
      }
    }
    return LoopMode.none;
  }
}
