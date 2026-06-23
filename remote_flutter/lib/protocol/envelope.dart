import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

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

/// 信封编解码器：按 PSK 签名出站、校验入站（§3）。
class EnvelopeCodec {
  EnvelopeCodec({
    required this.psk,
    required this.fromAddress,
    this.tsWindowMs = 30000,
    this.firstWindowMs = 120000,
    this.dedupTtlMs = 300000,
  });

  /// 预置共享密钥（PSK），与 broker / player 全系统一致。
  String psk;

  /// 本端地址，如 "controller:phone-jay"。
  String fromAddress;

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

  /// HMAC-SHA256 小写十六进制。
  String hmacHex(String message) {
    final mac = Hmac(sha256, utf8.encode(psk));
    return mac.convert(utf8.encode(message)).toString();
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
    final sig = hmacHex(signingString(
      v: v,
      type: type,
      msgId: actualMsgId,
      ts: actualTs,
      from: actualFrom,
      to: to,
      payload: payload,
    ));
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
  bool checkSig(Envelope e) {
    final expected = hmacHex(signingString(
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

  /// 完整校验入站信封：签名 → 时效 → 去重。
  VerifyError verify(Envelope e, {int? now}) {
    if (!checkSig(e)) return VerifyError.badSig;
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
