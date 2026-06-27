import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'auth_mode.dart';

/// 信封 + HMAC 签名/校验 + msg_id，严格对齐 protocol_spec.md §2/§3。
///
/// 签名串 = "{v}|{type}|{msg_id}|{ts}|{from}|{to}|{canonical_json(payload)}"
/// canonical_json = json.dumps(payload, sort_keys=True,
///                             separators=(",",":"), ensure_ascii=False)
/// sig = HMAC_SHA256(PSK, 签名串).hexdigest()  (小写十六进制)
///
/// 这里的 [canonicalJson] 必须与 broker 的 Python 实现逐字节一致，否则签名校验必失败：
///  - 递归按 key 排序 (sort_keys=True)；payload 的 key 均为 ASCII 标识符，
///    Dart 的 UTF-16 码元排序与 Python 的码点排序在 BMP/ASCII 范围内等价。
///  - 紧凑分隔符 ","/":"，无空格 —— Dart 的 jsonEncode 默认即如此。
///  - ensure_ascii=False —— Dart 的 jsonEncode 默认不转义非 ASCII，输出原字符，
///    与 Python ensure_ascii=False 一致。
///  - 控制字符与 " \ 的短转义 (\n \r \t \b \f) 与 \u00XX 形式两端一致。
///  - 不使用浮点数 payload（全用 int），规避 1.0 / 1 之类的格式差异。

/// 递归地把 Map 的 key 排序，得到可被 jsonEncode 直接编码的规范结构。
Object? _sortKeysDeep(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {
      for (final k in keys) k: _sortKeysDeep(value[k]),
    };
  }
  if (value is List) {
    return value.map(_sortKeysDeep).toList();
  }
  return value;
}

/// 规范 JSON 序列化（对齐 Python json.dumps 的 canonical 形式）。
String canonicalJson(Object? payload) => jsonEncode(_sortKeysDeep(payload));

/// 派生 per-device 密钥（protocol_spec.md §17.2，四端必须逐字节一致）。
///
/// ```
/// device_key = HMAC_SHA256(PSK, identity).digest()   # 32 bytes 二进制
/// ```
/// - [identity] = 该端 envelope 的 `from` 字段**完整字符串**，逐字节参与，
///   **不做任何归一化/小写化/裁剪**（player:`player:<id>` / controller:`controller:<id>` /
///   broker:`broker`）。
/// - 返回 **32 字节二进制**，作为下一层 HMAC 的 key **直接使用**（§17.5：不要 hex 后再当 key）。
List<int> deriveDeviceKey(String psk, String identity) {
  final mac = Hmac(sha256, utf8.encode(psk));
  return mac.convert(utf8.encode(identity)).bytes;
}

/// [deriveDeviceKey] 的小写十六进制形式（仅用于配对 URI/QR 携带 `dk`，见 §17.4）。
String deriveDeviceKeyHex(String psk, String identity) {
  final sb = StringBuffer();
  for (final b in deriveDeviceKey(psk, identity)) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// 把小写/大写十六进制字符串解码为字节（用于消费配对 URI 里的 `dk`）。
/// 非法/奇数长度 → null。
List<int>? hexToBytes(String hex) {
  final s = hex.trim();
  if (s.isEmpty || s.length.isOdd) return null;
  final out = <int>[];
  for (var i = 0; i < s.length; i += 2) {
    final b = int.tryParse(s.substring(i, i + 2), radix: 16);
    if (b == null) return null;
    out.add(b);
  }
  return out;
}

/// 生成 RFC4122 v4 UUID（不引入额外依赖，用密码学安全随机源）。
String uuid4() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
  String hex(int start, int end) {
    final sb = StringBuffer();
    for (var i = start; i < end; i++) {
      sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// 当前 epoch 毫秒。
int nowMs() => DateTime.now().millisecondsSinceEpoch;

/// 协议信封。
class Envelope {
  final int v;
  final String type;
  final String msgId;
  final int ts;
  final String from;
  final String to;
  final String sig;
  final Map<String, dynamic> payload;

  const Envelope({
    required this.v,
    required this.type,
    required this.msgId,
    required this.ts,
    required this.from,
    required this.to,
    required this.sig,
    required this.payload,
  });

  Map<String, dynamic> toMap() => {
        'v': v,
        'type': type,
        'msg_id': msgId,
        'ts': ts,
        'from': from,
        'to': to,
        'sig': sig,
        'payload': payload,
      };

  String toJson() => jsonEncode(toMap());

  static Envelope fromMap(Map<String, dynamic> m) => Envelope(
        v: (m['v'] as num).toInt(),
        type: m['type'] as String,
        msgId: m['msg_id'] as String,
        ts: (m['ts'] as num).toInt(),
        from: m['from'] as String,
        to: m['to'] as String,
        sig: (m['sig'] as String?) ?? '',
        payload: (m['payload'] as Map?)?.cast<String, dynamic>() ?? {},
      );

  static Envelope fromJson(String s) =>
      fromMap((jsonDecode(s) as Map).cast<String, dynamic>());
}

/// 校验结果。
enum VerifyError { ok, badSig, expired, replay }

/// 信封编解码器：按 PSK 签名出站、校验入站（§3 + §13 auth_mode 自适应）。
///
/// [authMode] 决定出站是否填真实 `sig`、入站是否验签：
///  - `open`：出站 `sig=""`，入站不验签（仍做时效 + 去重）。
///  - `optional`：有 PSK 才签；入站 `sig` 非空才验。
///  - `required`：强制签 + 强制验（原 §3 行为）。
///
/// 时效（ts 窗口）+ 去重（msg_id LRU）在三档下都仍执行（§13 防重放卫生）。
class EnvelopeCodec {
  EnvelopeCodec({
    required this.psk,
    required this.fromAddress,
    this.authMode = AuthMode.required,
    this.keyMode = KeyMode.global,
    this.deviceKeyHex,
    this.tsWindowMs = 30000,
    this.firstWindowMs = 120000,
    this.dedupTtlMs = 300000,
  });

  /// 预置共享密钥（PSK），与 broker / player 全系统一致。
  ///
  /// §17.4 零感知约束下，被控端/遥控端**可不持有 PSK**（仅通过配对 URI 拿到自己那把
  /// [deviceKeyHex] + 自身 [fromAddress]）。本端持 PSK 时，可对任意 `from` 现场派生验签
  /// （broker 同款无状态模型）；不持 PSK 时只能用 [deviceKeyHex] 签自己的出站帧。
  String psk;

  /// 本端地址，如 "controller:phone-jay"。**即派生用 identity（§17.2，不归一化）**。
  String fromAddress;

  /// 当前鉴权模式（§13）。默认 [AuthMode.required] 以保持与历史 §3 行为兼容；
  /// 连上协调端读到 `welcome.auth_mode` 后由上层调整（见 [BrokerClient] / [WallState]）。
  AuthMode authMode;

  /// 当前密钥模式（§17.3）。默认 [KeyMode.global]（= v1.2 行为，向后兼容）。
  /// 连上协调端读到 `welcome.key_mode` / `announce.key_mode` 后由上层调整。
  KeyMode keyMode;

  /// 本端自己那把 device_key 的十六进制（§17.4 通过配对 URI/QR 下发，端永不接触 PSK）。
  /// 仅在 [KeyMode.derived] 且本端无 PSK 时用于**签自己的出站帧**；为空则回落到派生/PSK。
  String? deviceKeyHex;

  bool get _hasPsk => psk.isNotEmpty;

  /// 时效窗口（毫秒），首帧放宽到 [firstWindowMs]。
  final int tsWindowMs;
  final int firstWindowMs;

  /// msg_id 去重 TTL（毫秒）。
  final int dedupTtlMs;

  /// 是否已完成首帧（用于放宽首次时效窗口）。
  bool _hadFirstFrame = false;

  /// 最近见过的 msg_id → 见到时刻，用于 LRU 去重。
  final Map<String, int> _seen = {};

  /// 计算签名串（§3 拼接方式）。
  String signingString({
    required int v,
    required String type,
    required String msgId,
    required int ts,
    required String from,
    required String to,
    required Object? payload,
  }) =>
      '$v|$type|$msgId|$ts|$from|$to|${canonicalJson(payload)}';

  /// HMAC-SHA256 小写十六进制，用**全局 PSK** 作 key（= [KeyMode.global] 行为）。
  /// 保留以兼容历史调用；派生模式请用 [hmacHexWithKey] / [signWith]。
  String hmacHex(String message) => _hmacHexBytes(utf8.encode(psk), message);

  /// 用指定**二进制 key** 计算 HMAC-SHA256 小写十六进制（§17.2：device_key 直接作 key）。
  String hmacHexWithKey(List<int> key, String message) =>
      _hmacHexBytes(key, message);

  static String _hmacHexBytes(List<int> key, String message) {
    final mac = Hmac(sha256, key);
    return mac.convert(utf8.encode(message)).toString();
  }

  /// 解析本端用于**签自己出站帧**的 key 字节（§17.2/§17.4）：
  ///  - [KeyMode.global]：直接用 PSK 字节。
  ///  - [KeyMode.derived]：持 PSK → 用本端 [fromAddress] identity 现场派生；
  ///    不持 PSK → 用配对 URI 下发的 [deviceKeyHex]（端永不接触 PSK）。
  /// 返回 null 表示无可用密钥（上层据 authMode 决定是否仍签空 sig）。
  List<int>? _signingKey() {
    if (keyMode == KeyMode.global) return utf8.encode(psk);
    if (_hasPsk) return deriveDeviceKey(psk, fromAddress);
    final dk = deviceKeyHex;
    if (dk != null && dk.isNotEmpty) return hexToBytes(dk);
    return null;
  }

  /// 解析用于**验某帧**的 key 字节（§17.2 验签）：从被验帧 `from` 取 identity，
  /// 用 PSK 现场派生（broker 无状态模型）。
  ///  - [KeyMode.global]：直接用 PSK 字节。
  ///  - [KeyMode.derived] 且持 PSK：派生 `from` 的 device_key。
  ///  - [KeyMode.derived] 且本端只持自己的 [deviceKeyHex]：仅当被验帧 `from` 恰为本端
  ///    [fromAddress] 时可用该 key（回环自检）；其它 `from` 无法派生 → 返回 null（验签失败）。
  List<int>? _verifyKey(String from) {
    if (keyMode == KeyMode.global) return utf8.encode(psk);
    if (_hasPsk) return deriveDeviceKey(psk, from);
    final dk = deviceKeyHex;
    if (from == fromAddress && dk != null && dk.isNotEmpty) {
      return hexToBytes(dk);
    }
    return null;
  }

  /// 构造并签名一个出站信封。
  Envelope build({
    required String type,
    required String to,
    Map<String, dynamic> payload = const {},
    int v = 1,
    String? from,
    String? msgId,
    int? ts,
  }) {
    final actualFrom = from ?? fromAddress;
    final actualMsgId = msgId ?? uuid4();
    final actualTs = ts ?? nowMs();
    // §13：open → sig=""；optional → 有非空密钥才签；required → 总是签（即便空 key，
    // HMAC(空 key) 仍是合法 64-hex，保留 v1.2 行为）。
    // §17：签名 key 由 keyMode 决定（global=PSK；derived=本端 device_key）。
    final signKey = _signingKey();
    // 非空密钥（对应 v1.2 的 hasPsk 语义：optional 据此决定签不签）。
    final hasUsableKey = signKey != null && signKey.isNotEmpty;
    // signKey==null 表示**无任何密钥材料**（derived 且既无 PSK 又无 device_key）→ 不签。
    final sig = (authMode.shouldSign(hasPsk: hasUsableKey) && signKey != null)
        ? hmacHexWithKey(
            signKey,
            signingString(
              v: v,
              type: type,
              msgId: actualMsgId,
              ts: actualTs,
              from: actualFrom,
              to: to,
              payload: payload,
            ))
        : '';
    return Envelope(
      v: v,
      type: type,
      msgId: actualMsgId,
      ts: actualTs,
      from: actualFrom,
      to: to,
      sig: sig,
      payload: payload,
    );
  }

  /// 重算签名并与 [e.sig] 比对。
  ///
  /// §17.2 验签：从被验帧的 `from` 取 identity，用 PSK 现场派生该 identity 的 device_key
  /// （[KeyMode.derived]）或直接用 PSK（[KeyMode.global]），重算 `sig` 比对。
  ///
  /// **泄露隔离（§17.5）**：用 identity-A 的 key 去签一个 `from=identity-B` 的帧时，本方法
  /// 按 `from=B` 派生 key 重算 → 与攻击者用 A 算出的 sig 必不相等 → 返回 false（丢弃）。
  bool checkSig(Envelope e) {
    final key = _verifyKey(e.from);
    if (key == null || key.isEmpty) return false; // 无法派生该 from 的 key → 验签失败
    final expected = hmacHexWithKey(
        key,
        signingString(
          v: e.v,
          type: e.type,
          msgId: e.msgId,
          ts: e.ts,
          from: e.from,
          to: e.to,
          payload: e.payload,
        ));
    return _constantTimeEquals(expected, e.sig);
  }

  /// 按当前 [authMode] 判断一帧的签名是否可接受（不含时效/去重）。
  ///
  /// - `open`：永远接受（不验签）。
  /// - `optional`：sig 为空 → 接受（放行）；非空 → 必须校验通过。
  /// - `required`：必须有合法 sig（空 sig 视为失败）。
  ///
  /// 用于 UDP `announce`（§7/§13）等只需签名维度、无连接级时效去重的场景。
  bool acceptSig(Envelope e) {
    final present = e.sig.isNotEmpty;
    if (!authMode.shouldVerify(sigPresent: present)) return true;
    return checkSig(e);
  }

  /// 完整校验入站信封：签名（按 authMode） → 时效 → 去重。
  VerifyError verify(Envelope e, {int? now}) {
    if (!acceptSig(e)) return VerifyError.badSig;
    final t = now ?? nowMs();
    final window = _hadFirstFrame ? tsWindowMs : firstWindowMs;
    if ((t - e.ts).abs() > window) return VerifyError.expired;
    _gc(t);
    if (_seen.containsKey(e.msgId)) return VerifyError.replay;
    _seen[e.msgId] = t;
    _hadFirstFrame = true;
    return VerifyError.ok;
  }

  void _gc(int now) {
    _seen.removeWhere((_, seenAt) => now - seenAt > dedupTtlMs);
  }

  /// 常量时间字符串比较，避免时序侧信道。
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
