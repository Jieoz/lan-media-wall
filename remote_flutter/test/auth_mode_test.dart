import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/auth_mode.dart';
import 'package:remote_flutter/protocol/envelope.dart';

void main() {
  group('AuthMode 解析与线格式 (§13)', () {
    test('parse 识别三档，未知/空 → open', () {
      expect(AuthMode.parse('open'), AuthMode.open);
      expect(AuthMode.parse('optional'), AuthMode.optional);
      expect(AuthMode.parse('required'), AuthMode.required);
      expect(AuthMode.parse('REQUIRED'), AuthMode.required);
      expect(AuthMode.parse(''), AuthMode.open);
      expect(AuthMode.parse(null), AuthMode.open);
      expect(AuthMode.parse('garbage'), AuthMode.open);
    });

    test('wire 往返', () {
      for (final m in AuthMode.values) {
        expect(AuthMode.parse(m.wire), m);
      }
    });

    test('shouldSign 矩阵', () {
      expect(AuthMode.open.shouldSign(hasPsk: true), isFalse);
      expect(AuthMode.open.shouldSign(hasPsk: false), isFalse);
      expect(AuthMode.optional.shouldSign(hasPsk: true), isTrue);
      expect(AuthMode.optional.shouldSign(hasPsk: false), isFalse);
      expect(AuthMode.required.shouldSign(hasPsk: true), isTrue);
      expect(AuthMode.required.shouldSign(hasPsk: false), isTrue);
    });

    test('shouldVerify 矩阵', () {
      expect(AuthMode.open.shouldVerify(sigPresent: true), isFalse);
      expect(AuthMode.open.shouldVerify(sigPresent: false), isFalse);
      expect(AuthMode.optional.shouldVerify(sigPresent: true), isTrue);
      expect(AuthMode.optional.shouldVerify(sigPresent: false), isFalse);
      expect(AuthMode.required.shouldVerify(sigPresent: true), isTrue);
      expect(AuthMode.required.shouldVerify(sigPresent: false), isTrue);
    });

    test('仅 required 触发冷却 (§3 末)', () {
      expect(AuthMode.open.enforcesLockout, isFalse);
      expect(AuthMode.optional.enforcesLockout, isFalse);
      expect(AuthMode.required.enforcesLockout, isTrue);
    });
  });

  group('EnvelopeCodec 按 authMode 出站签名 (§13)', () {
    test('open → sig 为空串，结构不变', () {
      final codec = EnvelopeCodec(
          psk: 'k', fromAddress: 'controller:c1', authMode: AuthMode.open);
      final env = codec.build(type: 'pause', to: 'group:g', payload: {'x': 1});
      expect(env.sig, '');
      // toJson/fromJson 仍可往返
      final back = Envelope.fromJson(env.toJson());
      expect(back.sig, '');
      expect(back.type, 'pause');
    });

    test('optional 有 PSK → 签；无 PSK → 空', () {
      final signed = EnvelopeCodec(
          psk: 'secret', fromAddress: 'c', authMode: AuthMode.optional);
      final e1 = signed.build(type: 't', to: 'b', payload: {});
      expect(e1.sig, isNotEmpty);

      final unsigned =
          EnvelopeCodec(psk: '', fromAddress: 'c', authMode: AuthMode.optional);
      final e2 = unsigned.build(type: 't', to: 'b', payload: {});
      expect(e2.sig, '');
    });

    test('required → 总是签（即便空 PSK 也产出 64 hex）', () {
      final codec = EnvelopeCodec(
          psk: '', fromAddress: 'c', authMode: AuthMode.required);
      final env = codec.build(type: 't', to: 'b', payload: {});
      expect(env.sig, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  group('EnvelopeCodec.acceptSig 按 authMode 入站 (§13)', () {
    test('open：任意 sig（含错的）都接受', () {
      final codec = EnvelopeCodec(
          psk: 'k', fromAddress: 'c', authMode: AuthMode.open);
      final env = Envelope(
        v: 1,
        type: 't',
        msgId: 'm',
        ts: 1,
        from: 'a',
        to: 'b',
        sig: 'deadbeef',
        payload: const {},
      );
      expect(codec.acceptSig(env), isTrue);
    });

    test('optional：空 sig 放行；非空必须正确', () {
      final codec = EnvelopeCodec(
          psk: 'k', fromAddress: 'c', authMode: AuthMode.optional);
      final empty = Envelope(
          v: 1, type: 't', msgId: 'm', ts: 1, from: 'a', to: 'b', sig: '', payload: const {});
      expect(codec.acceptSig(empty), isTrue);

      // 用 required codec 造一个正确签名的帧
      final signer = EnvelopeCodec(
          psk: 'k', fromAddress: 'a', authMode: AuthMode.required);
      final good = signer.build(type: 't', to: 'b', payload: {'n': 1});
      expect(codec.acceptSig(good), isTrue);

      final bad = Envelope(
          v: 1, type: 't', msgId: 'm2', ts: 1, from: 'a', to: 'b',
          sig: 'abc123', payload: const {});
      expect(codec.acceptSig(bad), isFalse);
    });

    test('required：空 sig 失败，正确 sig 通过', () {
      final codec = EnvelopeCodec(
          psk: 'k', fromAddress: 'c', authMode: AuthMode.required);
      final empty = Envelope(
          v: 1, type: 't', msgId: 'm', ts: 1, from: 'a', to: 'b', sig: '', payload: const {});
      expect(codec.acceptSig(empty), isFalse);

      final good = codec.build(type: 't', to: 'b', payload: {'n': 1});
      expect(codec.acceptSig(good), isTrue);
    });

    test('verify 在 open 下跳过签名但仍做时效+去重', () {
      final codec = EnvelopeCodec(
          psk: 'k', fromAddress: 'c', authMode: AuthMode.open);
      final env = Envelope(
          v: 1, type: 't', msgId: 'mm', ts: 1000, from: 'a', to: 'b',
          sig: 'wrong', payload: const {});
      expect(codec.verify(env, now: 1000), VerifyError.ok);
      // 重复 msg_id → replay
      expect(codec.verify(env, now: 1000), VerifyError.replay);
      // 过期
      final old = Envelope(
          v: 1, type: 't', msgId: 'old', ts: 1, from: 'a', to: 'b',
          sig: '', payload: const {});
      expect(codec.verify(old, now: 1 + 300000), VerifyError.expired);
    });
  });
}
