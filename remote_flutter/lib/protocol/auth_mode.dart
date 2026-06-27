/// 鉴权模式（protocol_spec.md §13）。
///
/// §3 的 HMAC 仍是唯一鉴权机制，但是否强制由协调端（broker / cohost / p2p controller）
/// 在 `welcome.payload.auth_mode` 与 UDP `announce.payload.auth_mode` 中声明的 `auth_mode`
/// 决定。三档：
///
/// | auth_mode | 发送方 sig          | 接收方校验            |
/// |-----------|---------------------|-----------------------|
/// | open      | 允许为 ""（空串）   | 不验签                |
/// | optional  | 有 PSK 就签，否则 "" | sig 非空才验，空则放行 |
/// | required  | 必填合法 sig        | 强制验签，失败丢弃     |
///
/// `open` 模式下 `sig` 字段仍存在（填 ""），信封结构 §2 不变。
/// `ts` 时效 + `msg_id` 去重在三档下都仍执行（防重放卫生，不依赖密钥）。
enum AuthMode {
  open,
  optional,
  required;

  /// 线格式（与协议字符串一致）。`required` 是 Dart 内建标识符，
  /// 不能直接用 `.name`，因此显式映射。
  String get wire => switch (this) {
        AuthMode.open => 'open',
        AuthMode.optional => 'optional',
        AuthMode.required => 'required',
      };

  /// 解析协议字符串；未知/缺失 → 默认 `open`（§13：open 为默认）。
  static AuthMode parse(Object? raw) {
    final s = (raw is String ? raw : '').trim().toLowerCase();
    return switch (s) {
      'open' => AuthMode.open,
      'optional' => AuthMode.optional,
      'required' => AuthMode.required,
      _ => AuthMode.open,
    };
  }

  /// UI 徽标文案（开放 / 可选 / 加密）。
  String get label => switch (this) {
        AuthMode.open => '开放',
        AuthMode.optional => '可选',
        AuthMode.required => '加密',
      };

  /// 出站时本端是否应当填入真实签名。
  ///
  /// - `open`   → 永不签（填 ""）。
  /// - `optional` → 有 PSK 才签。
  /// - `required` → 总是签（无 PSK 是上层的软错误，仍尝试签出空 PSK 的 sig）。
  bool shouldSign({required bool hasPsk}) => switch (this) {
        AuthMode.open => false,
        AuthMode.optional => hasPsk,
        AuthMode.required => true,
      };

  /// 入站时对“缺失/空 sig”的处置：是否需要验签。
  ///
  /// - `open`   → 从不验签（直接放行）。
  /// - `optional` → 仅当 sig 非空时验签；空 sig 放行。
  /// - `required` → 强制验签（空 sig 即失败）。
  bool shouldVerify({required bool sigPresent}) => switch (this) {
        AuthMode.open => false,
        AuthMode.optional => sigPresent,
        AuthMode.required => true,
      };

  /// 鉴权失败计数/冷却（§3 末）仅在 required 生效。
  bool get enforcesLockout => this == AuthMode.required;
}

/// 密钥模式（protocol_spec.md §17 派生密钥）。
///
/// §3 的签名**字符串布局 / canonical JSON / ts 时效 / msg_id 去重全部不变**，
/// 唯一变化是 HMAC 使用的**密钥**：
///
/// | key_mode | 签名 key                                   | 适用            |
/// |----------|--------------------------------------------|-----------------|
/// | global   | 直接用 PSK（= v1.2 旧行为）                 | 与未升级老端互通 |
/// | derived  | `HMAC_SHA256(PSK, identity).digest()`(§17.2)| 新部署；泄露隔离 |
///
/// **协调端（broker / cohost / p2p controller）的 `key_mode` 是该拓扑的权威**，
/// 在 `welcome.payload.key_mode`（string）与 UDP `announce.payload.key_mode` 中声明。
/// **字段缺失/缺省 → 接收端按 `global` 处理**（= v1.2 行为，向后兼容）。
/// `open` 鉴权模式下不签不验，`key_mode` 无意义。
enum KeyMode {
  global,
  derived;

  /// 线格式（与协议字符串一致）。
  String get wire => switch (this) {
        KeyMode.global => 'global',
        KeyMode.derived => 'derived',
      };

  /// 解析协议字符串。**未知/缺失/空 → `global`**（§17.3 向后兼容默认）。
  static KeyMode parse(Object? raw) {
    final s = (raw is String ? raw : '').trim().toLowerCase();
    return s == 'derived' ? KeyMode.derived : KeyMode.global;
  }

  /// UI 文案（全局密钥 / 派生密钥）。
  String get label => switch (this) {
        KeyMode.global => '全局密钥',
        KeyMode.derived => '派生密钥',
      };
}
