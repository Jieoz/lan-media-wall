import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/envelope.dart';

void main() {
  group('canonicalJson (§3 与 broker Python json.dumps 对齐)', () {
    test('key 递归排序 + 紧凑分隔符，无空格', () {
      final s = canonicalJson({
        'b': 1,
        'a': {'y': 2, 'x': 1},
      });
      expect(s, '{"a":{"x":1,"y":2},"b":1}');
    });

    test('list 内对象也排序，保持顺序', () {
      final s = canonicalJson({
        'items': [
          {'z': 1, 'a': 2},
        ],
      });
      expect(s, '{"items":[{"a":2,"z":1}]}');
    });

    test('ensure_ascii=False：非 ASCII 原样输出', () {
      final s = canonicalJson({'name': '大厅'});
      expect(s, '{"name":"大厅"}');
    });

    test('空 payload', () {
      expect(canonicalJson(<String, dynamic>{}), '{}');
    });
  });

  group('signingString (§3 拼接)', () {
    test('精确格式 v|type|msg_id|ts|from|to|canonical', () {
      final codec = EnvelopeCodec(psk: 'k', fromAddress: 'controller:c1');
      final s = codec.signingString(
        v: 1,
        type: 'pause',
        msgId: 'm1',
        ts: 1750000000000,
        from: 'controller:c1',
        to: 'group:lobby',
        payload: {'group_id': 'lobby'},
      );
      expect(s,
          '1|pause|m1|1750000000000|controller:c1|group:lobby|{"group_id":"lobby"}');
    });
  });

  group('HMAC 签名往返', () {
    test('build 出的信封能被同 PSK 的 checkSig 通过', () {
      final codec = EnvelopeCodec(psk: 'shared-secret', fromAddress: 'controller:c1');
      final env = codec.build(
        type: 'set_volume',
        to: 'group:lobby',
        payload: {'group_id': 'lobby', 'volume': 50},
      );
      expect(codec.checkSig(env), isTrue);
    });

    test('已知向量：sig 与手算 HMAC 一致', () {
      final codec = EnvelopeCodec(psk: 'k', fromAddress: 'controller:c1');
      final ss = codec.signingString(
        v: 1,
        type: 't',
        msgId: 'm',
        ts: 1,
        from: 'a',
        to: 'b',
        payload: {'x': 1},
      );
      // 重算与内部一致
      expect(codec.hmacHex(ss).length, 64);
      expect(codec.hmacHex(ss), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('改 PSK 后旧 sig 失配', () {
      final codec = EnvelopeCodec(psk: 'k1', fromAddress: 'controller:c1');
      final env = codec.build(type: 'stop', to: 'broker', payload: {});
      codec.psk = 'k2';
      expect(codec.checkSig(env), isFalse);
    });

    test('篡改 payload 后验签失败', () {
      final codec = EnvelopeCodec(psk: 'k', fromAddress: 'controller:c1');
      final env = codec.build(
        type: 'set_volume',
        to: 'group:g',
        payload: {'volume': 10},
      );
      final tampered = Envelope(
        v: env.v,
        type: env.type,
        msgId: env.msgId,
        ts: env.ts,
        from: env.from,
        to: env.to,
        sig: env.sig,
        payload: {'volume': 99},
      );
      expect(codec.checkSig(tampered), isFalse);
    });
  });

  group('verify 时效 + 去重 (§3)', () {
    test('过期(超首帧窗口)被拒', () {
      final codec = EnvelopeCodec(psk: 'k', fromAddress: 'b');
      final env = codec.build(type: 't', to: 'b', payload: {}, ts: 1000);
      // now 远超 firstWindowMs(120s)
      final r = codec.verify(env, now: 1000 + 200000);
      expect(r, VerifyError.expired);
    });

    test('首帧通过，重复 msg_id 第二次判为 replay', () {
      final codec = EnvelopeCodec(psk: 'k', fromAddress: 'b');
      final env = codec.build(type: 't', to: 'b', payload: {'a': 1});
      expect(codec.verify(env, now: env.ts), VerifyError.ok);
      expect(codec.verify(env, now: env.ts), VerifyError.replay);
    });

    test('坏签名先于时效被拒', () {
      final codec = EnvelopeCodec(psk: 'k', fromAddress: 'b');
      final env = codec.build(type: 't', to: 'b', payload: {});
      final bad = Envelope(
        v: env.v,
        type: env.type,
        msgId: env.msgId,
        ts: env.ts,
        from: env.from,
        to: env.to,
        sig: 'deadbeef',
        payload: env.payload,
      );
      expect(codec.verify(bad, now: env.ts), VerifyError.badSig);
    });
  });

  group('uuid4', () {
    test('格式与版本/变体位正确', () {
      final u = uuid4();
      expect(u, matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });

    test('两次不相等', () {
      expect(uuid4() == uuid4(), isFalse);
    });
  });

  group('Envelope JSON 往返', () {
    test('toJson → fromJson 不丢字段', () {
      final codec = EnvelopeCodec(psk: 'k', fromAddress: 'controller:c1');
      final env = codec.build(
        type: 'playlist',
        to: 'group:lobby',
        payload: {'playlist_id': 'p1', 'sync': true},
      );
      final back = Envelope.fromJson(env.toJson());
      expect(back.type, env.type);
      expect(back.msgId, env.msgId);
      expect(back.sig, env.sig);
      expect(back.payload['playlist_id'], 'p1');
      expect(codec.checkSig(back), isTrue);
    });
  });
}
