import 'auth_mode.dart';

/// `lmw://pair` 配对 URI 的纯构造/解析（protocol_spec.md §15）。
///
/// 格式：
/// ```
/// lmw://pair?host=<ip>&port=<8770>&group=<gid>&mode=<open|optional|required>
///           &psk=<hex?>&wss=<0|1>&name=<可选预设名>
/// ```
/// 规则：
///  - `open` 模式下**不含** `psk`（纯“扫一下进组”）。
///  - `required`/`optional` 下 `psk` 为 §3 的 hex（带密钥的入场券）。
///  - 字段做标准 URL 编码；未知 query 参数接收方**忽略**（向前兼容）。
///
/// 本类是纯逻辑（不依赖 Flutter / IO），便于单测；UI 仅负责把 [build] 的结果渲染成二维码。
class PairUri {
  static const String scheme = 'lmw';
  static const String host = 'pair';

  final String connHost;
  final int port;
  final String group;
  final AuthMode mode;

  /// 仅在 `optional`/`required` 且非空时写入 URI（§15.1）。
  final String? psk;
  final bool wss;
  final String? name;

  const PairUri({
    required this.connHost,
    required this.port,
    required this.group,
    required this.mode,
    this.psk,
    this.wss = false,
    this.name,
  });

  /// 构造 `lmw://pair?...` URI 字符串（query 全部标准 URL 编码）。
  ///
  /// `psk` 仅在 `mode != open` 且 psk 非空时写入；`open` 模式即使传了 psk 也丢弃，
  /// 以贯彻 §15.1“open 不含 psk”。`name` 仅在非空时写入。
  String build() {
    final params = <String, String>{
      'host': connHost,
      'port': port.toString(),
      'group': group,
      'mode': mode.wire,
      'wss': wss ? '1' : '0',
    };
    if (mode != AuthMode.open && (psk != null && psk!.isNotEmpty)) {
      params['psk'] = psk!;
    }
    if (name != null && name!.isNotEmpty) {
      params['name'] = name!;
    }
    // 固定 key 顺序，便于稳定测试与可读性（接收方按 key 取值，顺序无关）。
    const order = ['host', 'port', 'group', 'mode', 'psk', 'wss', 'name'];
    final query = [
      for (final k in order)
        if (params.containsKey(k))
          '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(params[k]!)}',
    ].join('&');
    return '$scheme://$host?$query';
  }

  /// 解析 `lmw://pair?...`。非 lmw/pair 或缺核心字段 → 返回 null。
  /// 未知 query 参数被忽略（向前兼容，§15.1）。
  static PairUri? tryParse(String input) {
    final s = input.trim();
    final uri = Uri.tryParse(s);
    if (uri == null) return null;
    if (uri.scheme.toLowerCase() != scheme) return null;
    // lmw://pair?... → host 段是 "pair"。
    if (uri.host.toLowerCase() != host) return null;
    final q = uri.queryParameters;
    final h = (q['host'] ?? '').trim();
    if (h.isEmpty) return null;
    final port = int.tryParse(q['port'] ?? '') ?? 8770;
    final group = (q['group'] ?? '').trim();
    final mode = AuthMode.parse(q['mode']);
    final wss = _truthy(q['wss']);
    final rawPsk = q['psk']?.trim();
    // open 模式忽略任何带入的 psk（§15.1）。
    final psk = (mode == AuthMode.open || rawPsk == null || rawPsk.isEmpty)
        ? null
        : rawPsk;
    final rawName = q['name']?.trim();
    final name = (rawName == null || rawName.isEmpty) ? null : rawName;
    return PairUri(
      connHost: h,
      port: port,
      group: group,
      mode: mode,
      psk: psk,
      wss: wss,
      name: name,
    );
  }

  static bool _truthy(String? v) {
    final s = (v ?? '').trim().toLowerCase();
    return s == '1' || s == 'true' || s == 'yes';
  }
}
