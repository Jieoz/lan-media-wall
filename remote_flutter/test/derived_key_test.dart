import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/auth_mode.dart';
import 'package:remote_flutter/protocol/envelope.dart';
import 'package:remote_flutter/protocol/pair_uri.dart';

/// 独立参考实现：device_key = HMAC_SHA256(PSK, identity).digest()（§17.2）。
/// 用它做交叉校验，确保 [deriveDeviceKey] 与"PSK 当 key、identity 当 message"逐字节一致。
List<int> refDeviceKey(String psk, String identity) =>
    Hmac(sha256, utf8.encode(psk)).convert(utf8.encode(identity)).bytes;

/// 独立参考：用任意二进制 key 对 signing_string 算 HMAC hex。
String refSigHex(List<int> key, String msg) =>
    Hmac(sha256, key).convert(utf8.encode(msg)).toString();

void main() {
  const psk = 'shared-secret';

  group('deriveDeviceKey (§17.2 派生函数)', () {
    test('= HMAC_SHA256(PSK, identity)，32 字节二进制', () {
      final id = 'player:win-lobby-01';
      final k = deriveDeviceKey(psk, id);
      expect(k.length, 32);
      expect(k, refDeviceKey(psk, id));
    });

    test('identity 逐字节参与：不归一化/不小写/不裁剪', () {
      // 大小写、空格、冒号差异都派生出不同的 key。
      expect(deriveDeviceKey(psk, 'player:A'),
          isNot(equals(deriveDeviceKey(psk, 'player:a'))));
      expect(deriveDeviceKey(psk, 'controller:c1'),
          isNot(equals(deriveDeviceKey(psk, 'controller:c1 '))));
      expect(deriveDeviceKey(psk, 'broker'),
          isNot(equals(deriveDeviceKey(psk, 'Broker'))));
    });

    test('不同 identity → 不同 key；同 identity → 稳定', () {
      expect(deriveDeviceKey(psk, 'player:a'),
          isNot(equals(deriveDeviceKey(psk, 'player:b'))));
      expect(deriveDeviceKey(psk, 'controller:c1'),
          equals(deriveDeviceKey(psk, 'controller:c1')));
    });

    test('hex 形式与二进制一致（仅用于 QR 携带 dk）', () {
      final id = 'controller:phone-jay';
      final hex = deriveDeviceKeyHex(psk, id);
      expect(hex, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(hexToBytes(hex), deriveDeviceKey(psk, id));
    });

    test('hexToBytes 拒绝非法/奇数长度', () {
      expect(hexToBytes('abc'), isNull); // 奇数
      expect(hexToBytes('zz'), isNull); // 非 hex
      expect(hexToBytes(''), isNull);
      expect(hexToBytes('00ff'), [0, 255]);
    });
  });

  group('KeyMode 协商解析 (§17.3 向后兼容)', () {
    test('derived 显式解析；其它一律 global（缺省/未知/空 → global）', () {
      expect(KeyMode.parse('derived'), KeyMode.derived);
      expect(KeyMode.parse('DERIVED'), KeyMode.derived);
      expect(KeyMode.parse('global'), KeyMode.global);
      expect(KeyMode.parse(null), KeyMode.global);
      expect(KeyMode.parse(''), KeyMode.global);
      expect(KeyMode.parse('weird'), KeyMode.global);
      expect(KeyMode.parse(123), KeyMode.global);
    });

    test('wire 往返', () {
      expect(KeyMode.global.wire, 'global');
      expect(KeyMode.derived.wire, 'derived');
    });
  });

  group('derived 签名/验签往返 (§17.2)', () {
    test('controller 出站用本端 device_key 签，broker 用 PSK 派生同 key 验通过', () {
      // controller 侧：持 PSK（操作者可信端），derived 模式，identity=controller:c1。
      final ctl = EnvelopeCodec(
        psk: psk,
        fromAddress: 'controller:c1',
        authMode: AuthMode.required,
        keyMode: KeyMode.derived,
      );
      final env = ctl.build(
        type: 'pause',
        to: 'group:lobby',
        payload: {'group_id': 'lobby'},
      );
      // sig 应当 = 用 controller:c1 派生的 key 对 signing_string 的 HMAC。
      final expectSig = refSigHex(
        refDeviceKey(psk, 'controller:c1'),
        ctl.signingString(
          v: env.v, type: env.type, msgId: env.msgId, ts: env.ts,
          from: env.from, to: env.to, payload: env.payload,
        ),
      );
      expect(env.sig, expectSig);

      // broker 侧：持 PSK、无状态，对任意 from 现场派生验签。
      final broker = EnvelopeCodec(
        psk: psk,
        fromAddress: 'broker',
        authMode: AuthMode.required,
        keyMode: KeyMode.derived,
      );
      expect(broker.checkSig(env), isTrue);
      expect(broker.verify(env, now: env.ts), VerifyError.ok);
    });

    test('controller 验 broker 帧：按 from="broker" 派生验签', () {
      final broker = EnvelopeCodec(
        psk: psk, fromAddress: 'broker',
        authMode: AuthMode.required, keyMode: KeyMode.derived,
      );
      final welcome = broker.build(
        type: 'welcome', to: 'controller:c1',
        payload: {'auth_mode': 'required', 'key_mode': 'derived'},
      );
      expect(welcome.sig,
          refSigHex(refDeviceKey(psk, 'broker'),
              broker.signingString(
                v: welcome.v, type: welcome.type, msgId: welcome.msgId,
                ts: welcome.ts, from: welcome.from, to: welcome.to,
                payload: welcome.payload,
              )));

      final ctl = EnvelopeCodec(
        psk: psk, fromAddress: 'controller:c1',
        authMode: AuthMode.required, keyMode: KeyMode.derived,
      );
      expect(ctl.checkSig(welcome), isTrue);
    });

    test('global 模式 = v1.2 行为：直接用 PSK 当 key', () {
      final a = EnvelopeCodec(
        psk: psk, fromAddress: 'controller:c1',
        authMode: AuthMode.required, keyMode: KeyMode.global,
      );
      final env = a.build(type: 'stop', to: 'broker', payload: {});
      expect(env.sig, refSigHex(utf8.encode(psk),
          a.signingString(
            v: env.v, type: env.type, msgId: env.msgId, ts: env.ts,
            from: env.from, to: env.to, payload: env.payload,
          )));
      // global 与 derived 对同一帧产出不同 sig（key 不同）。
      final d = EnvelopeCodec(
        psk: psk, fromAddress: 'controller:c1',
        authMode: AuthMode.required, keyMode: KeyMode.derived,
      );
      final envD = d.build(
        type: 'stop', to: 'broker', payload: {},
        msgId: env.msgId, ts: env.ts,
      );
      expect(envD.sig, isNot(equals(env.sig)));
    });
  });

  group('泄露隔离负向测试 (§17.5 契约符合性证据)', () {
    test('用 identity-A 派生的 key 去签 from=identity-B 的帧 → 验签必失败丢弃', () {
      // 攻击者攻破了墙机 A（player:hall-A），导出了 A 的 device_key。
      final keyA = deriveDeviceKey(psk, 'player:hall-A');

      // 受害方/验签方（如 broker 或 controller），derived 模式、持 PSK。
      final verifier = EnvelopeCodec(
        psk: psk, fromAddress: 'broker',
        authMode: AuthMode.required, keyMode: KeyMode.derived,
      );

      // 攻击者伪造一个声称来自 player:hall-B 的帧，但只能用 A 的 key 去签。
      const forgedFrom = 'player:hall-B';
      final ss = verifier.signingString(
        v: 1, type: 'stop', msgId: 'forged-1', ts: 1750000000000,
        from: forgedFrom, to: 'broker', payload: {},
      );
      final forged = Envelope(
        v: 1, type: 'stop', msgId: 'forged-1', ts: 1750000000000,
        from: forgedFrom, to: 'broker',
        sig: refSigHex(keyA, ss), // 用 A 的 key 签 B 的帧
        payload: {},
      );

      // 验签方按 from=hall-B 派生 key 重算 → 与 A 的 sig 不符 → 失败。
      expect(verifier.checkSig(forged), isFalse);
      expect(verifier.verify(forged, now: 1750000000000), VerifyError.badSig);
    });

    test('伪造 from=broker 的帧但用 player key 签 → 失败（防伪造下行指令）', () {
      final keyPlayer = deriveDeviceKey(psk, 'player:hall-A');
      final ctl = EnvelopeCodec(
        psk: psk, fromAddress: 'controller:c1',
        authMode: AuthMode.required, keyMode: KeyMode.derived,
      );
      final ss = ctl.signingString(
        v: 1, type: 'welcome', msgId: 'f2', ts: 1750000000000,
        from: 'broker', to: 'all', payload: {'auth_mode': 'required'},
      );
      final forged = Envelope(
        v: 1, type: 'welcome', msgId: 'f2', ts: 1750000000000,
        from: 'broker', to: 'all',
        sig: refSigHex(keyPlayer, ss),
        payload: {'auth_mode': 'required'},
      );
      expect(ctl.checkSig(forged), isFalse);
    });

    test('正确 key 签自己的 identity → 通过（隔离不误伤合法帧）', () {
      final keyA = deriveDeviceKey(psk, 'player:hall-A');
      final verifier = EnvelopeCodec(
        psk: psk, fromAddress: 'broker',
        authMode: AuthMode.required, keyMode: KeyMode.derived,
      );
      final ss = verifier.signingString(
        v: 1, type: 'status', msgId: 'ok-1', ts: 1750000000000,
        from: 'player:hall-A', to: 'broker', payload: {'device_id': 'hall-A'},
      );
      final ok = Envelope(
        v: 1, type: 'status', msgId: 'ok-1', ts: 1750000000000,
        from: 'player:hall-A', to: 'broker',
        sig: refSigHex(keyA, ss), payload: {'device_id': 'hall-A'},
      );
      expect(verifier.checkSig(ok), isTrue);
    });
  });

  group('零感知端：只持 device_key（无 PSK）(§17.4)', () {
    test('可用 device_key 签自己的出站帧，broker 用 PSK 派生验通过', () {
      const identity = 'controller:c1';
      // 端只通过配对 URI 拿到自己那把 dk + 自身 identity，永不接触 PSK。
      final leaf = EnvelopeCodec(
        psk: '', // 不持 PSK
        fromAddress: identity,
        authMode: AuthMode.required,
        keyMode: KeyMode.derived,
        deviceKeyHex: deriveDeviceKeyHex(psk, identity),
      );
      final env = leaf.build(type: 'pause', to: 'broker', payload: {});
      expect(env.sig, isNotEmpty);

      // broker 持 PSK，按 from 派生验签 → 通过。
      final broker = EnvelopeCodec(
        psk: psk, fromAddress: 'broker',
        authMode: AuthMode.required, keyMode: KeyMode.derived,
      );
      expect(broker.checkSig(env), isTrue);
    });

    test('无 PSK 端验非本端 from 的帧 → 无法派生 → 失败（fail-closed）', () {
      const identity = 'controller:c1';
      final leaf = EnvelopeCodec(
        psk: '', fromAddress: identity,
        authMode: AuthMode.required, keyMode: KeyMode.derived,
        deviceKeyHex: deriveDeviceKeyHex(psk, identity),
      );
      // 一个合法的 broker 帧（用真 PSK 派生 broker key 签）。
      final broker = EnvelopeCodec(
        psk: psk, fromAddress: 'broker',
        authMode: AuthMode.required, keyMode: KeyMode.derived,
      );
      final fromBroker = broker.build(type: 'welcome', to: identity, payload: {});
      // leaf 无 PSK，无法对 from=broker 派生 → checkSig 失败（fail-closed）。
      expect(leaf.checkSig(fromBroker), isFalse);
    });
  });

  group('PairUri §17.4 derived 携带 dk+id，不下发 psk', () {
    test('derived build：含 km=derived&dk&id，绝不含 psk', () {
      final p = PairUri(
        connHost: '192.168.1.10', port: 8770, group: 'lobby',
        mode: AuthMode.required, keyMode: KeyMode.derived,
        dk: 'a' * 64, id: 'player:win-lobby-01',
      );
      final s = p.build();
      expect(s.contains('km=derived'), isTrue);
      expect(s.contains('dk=${'a' * 64}'), isTrue);
      expect(s.contains('id=player%3Awin-lobby-01'), isTrue);
      expect(s.contains('psk='), isFalse);
    });

    test('derived 缺 dk/id → 回退 global 携带 psk（确保可用）', () {
      final p = PairUri(
        connHost: 'h', port: 8770, group: 'g',
        mode: AuthMode.required, keyMode: KeyMode.derived,
        psk: 'deadbeef',
      );
      final s = p.build();
      expect(s.contains('dk='), isFalse);
      expect(s.contains('psk=deadbeef'), isTrue);
    });

    test('derived build → tryParse 往返', () {
      final orig = PairUri(
        connHost: '10.0.0.5', port: 8771, group: 'hall',
        mode: AuthMode.required, keyMode: KeyMode.derived,
        dk: 'cafe1234' * 8, id: 'player:android-7', wss: true, name: '大厅',
      );
      final back = PairUri.tryParse(orig.build())!;
      expect(back.keyMode, KeyMode.derived);
      expect(back.dk, 'cafe1234' * 8);
      expect(back.id, 'player:android-7');
      expect(back.psk, isNull);
      expect(back.wss, isTrue);
      expect(back.name, '大厅');
    });

    test('km 缺失 → global（向后兼容老 broker 的 psk 码）', () {
      final back = PairUri.tryParse(
          'lmw://pair?host=h&port=8770&group=g&mode=required&psk=abc123')!;
      expect(back.keyMode, KeyMode.global);
      expect(back.psk, 'abc123');
      expect(back.dk, isNull);
    });

    test('open 模式忽略一切密钥字段（含 dk/id/km）', () {
      final back = PairUri.tryParse(
          'lmw://pair?host=h&mode=open&km=derived&dk=ff&id=player:x&psk=leak')!;
      expect(back.mode, AuthMode.open);
      expect(back.keyMode, KeyMode.global);
      expect(back.dk, isNull);
      expect(back.id, isNull);
      expect(back.psk, isNull);
    });
  });
}
