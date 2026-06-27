import 'auth_mode.dart';

/// `lmw://pair` 配对 URI 的纯构造/解析（protocol_spec.md §15 + §17.4）。
///
/// 格式：
/// ```
/// lmw://pair?host=<ip>&port=<8770>&group=<gid>&mode=<open|optional|required>
///           &km=<global|derived>&psk=<hex?>&dk=<hex?>&id=<identity?>
///           &wss=<0|1>&name=<可选预设名>
/// ```
/// 规则：
///  - `open` 模式下**不含**任何密钥字段（纯“扫一下进组”）。
///  - `optional`/`required` 下，按 §17.4 密钥模式二选一：
///    - `km=global`（或缺省）：携带 `psk`（= v1.2 行为，老 broker/兼容回退）。
///    - `km=derived`：携带 `dk`（该端 device_key 的 hex）+ `id`（该端 identity），
///      **不再下发 PSK**。device_key 由协调端用 PSK 现场派生嵌入，端永不接触 PSK。
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

  /// 密钥模式（§17.3）。决定携带 [psk]（global）还是 [dk]+[id]（derived）。
  /// 缺省/缺失 → [KeyMode.global]（向后兼容）。
  final KeyMode keyMode;

  /// 仅在 `optional`/`required` + `global` 且非空时写入 URI（§15.1 / §17.4）。
  final String? psk;

  /// device_key 的 hex，仅在 `optional`/`required` + `derived` 且非空时写入（§17.4）。
  final String? dk;

  /// 该端 identity（如 `player:win-lobby-01`），与 [dk] 配对下发（§17.4）。
  final String? id;

  final bool wss;
  final String? name;

  const PairUri({
    required this.connHost,
    required this.port,
    required this.group,
    required this.mode,
    this.keyMode = KeyMode.global,
    this.psk,
    this.dk,
    this.id,
    this.wss = false,
    this.name,
  });

  /// 构造 `lmw://pair?...` URI 字符串（query 全部标准 URL 编码）。
  ///
  /// 密钥字段仅在 `mode != open` 时按 [keyMode] 写入：
  ///  - global：psk 非空才写 `psk`（`open` 即使带 psk 也丢弃，贯彻 §15.1）。
  ///  - derived：dk+id 均非空才写 `km=derived`&`dk`&`id`，**绝不写 psk**（§17.4）。
  /// `name` 仅在非空时写入。
  String build() {
    final params = <String, String>{
      'host': connHost,
      'port': port.toString(),
      'group': group,
      'mode': mode.wire,
      'wss': wss ? '1' : '0',
    };
    if (mode != AuthMode.open) {
      if (keyMode == KeyMode.derived &&
          (dk != null && dk!.isNotEmpty) &&
          (id != null && id!.isNotEmpty)) {
        params['km'] = KeyMode.derived.wire;
        params['dk'] = dk!;
        params['id'] = id!;
      } else if (psk != null && psk!.isNotEmpty) {
        // global（默认）：维持 v1.2 线格式，不写 km 以保持向后兼容字节布局。
        params['psk'] = psk!;
      }
    }
    if (name != null && name!.isNotEmpty) {
      params['name'] = name!;
    }
    // 固定 key 顺序，便于稳定测试与可读性（接收方按 key 取值，顺序无关）。
    const order = ['host', 'port', 'group', 'mode', 'km', 'psk', 'dk', 'id', 'wss', 'name'];
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
    // §17.4：open 模式忽略一切密钥字段；km 缺省 → global（向后兼容）。
    final isOpen = mode == AuthMode.open;
    final keyMode = isOpen ? KeyMode.global : KeyMode.parse(q['km']);
    final rawPsk = q['psk']?.trim();
    final rawDk = q['dk']?.trim();
    final rawId = q['id']?.trim();
    final psk = (isOpen || rawPsk == null || rawPsk.isEmpty) ? null : rawPsk;
    final dk = (isOpen || rawDk == null || rawDk.isEmpty) ? null : rawDk;
    final id = (isOpen || rawId == null || rawId.isEmpty) ? null : rawId;
    final rawName = q['name']?.trim();
    final name = (rawName == null || rawName.isEmpty) ? null : rawName;
    return PairUri(
      connHost: h,
      port: port,
      group: group,
      mode: mode,
      keyMode: keyMode,
      psk: psk,
      dk: dk,
      id: id,
      wss: wss,
      name: name,
    );
  }

  static bool _truthy(String? v) {
    final s = (v ?? '').trim().toLowerCase();
    return s == '1' || s == 'true' || s == 'yes';
  }
}
