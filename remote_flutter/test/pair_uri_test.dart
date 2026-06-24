import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/auth_mode.dart';
import 'package:remote_flutter/protocol/pair_uri.dart';

void main() {
  group('PairUri.build (§15.1)', () {
    test('open 模式不含 psk（即便传了也丢弃）', () {
      const p = PairUri(
        connHost: '192.168.1.10',
        port: 8770,
        group: 'lobby',
        mode: AuthMode.open,
        psk: 'should-be-dropped',
      );
      final s = p.build();
      expect(s, startsWith('lmw://pair?'));
      expect(s.contains('mode=open'), isTrue);
      expect(s.contains('psk='), isFalse);
      expect(s.contains('host=192.168.1.10'), isTrue);
      expect(s.contains('port=8770'), isTrue);
      expect(s.contains('group=lobby'), isTrue);
      expect(s.contains('wss=0'), isTrue);
    });

    test('required 模式含 psk', () {
      const p = PairUri(
        connHost: '10.0.0.5',
        port: 8771,
        group: 'hall',
        mode: AuthMode.required,
        psk: 'deadbeefcafe',
        wss: true,
      );
      final s = p.build();
      expect(s.contains('mode=required'), isTrue);
      expect(s.contains('psk=deadbeefcafe'), isTrue);
      expect(s.contains('wss=1'), isTrue);
    });

    test('optional 有 psk 才写', () {
      const withPsk = PairUri(
          connHost: 'h', port: 8770, group: 'g', mode: AuthMode.optional, psk: 'k');
      expect(withPsk.build().contains('psk=k'), isTrue);

      const noPsk = PairUri(
          connHost: 'h', port: 8770, group: 'g', mode: AuthMode.optional);
      expect(noPsk.build().contains('psk='), isFalse);
    });

    test('name 仅非空时写入，且 URL 编码', () {
      const p = PairUri(
        connHost: 'h',
        port: 8770,
        group: 'g',
        mode: AuthMode.open,
        name: '大厅 左屏',
      );
      final s = p.build();
      expect(s.contains('name='), isTrue);
      // 空格被编码（+ 或 %20，取决于 encodeQueryComponent → +）
      expect(s.contains('大厅 左屏'), isFalse);
    });

    test('特殊字符在 host/group 被编码', () {
      const p = PairUri(
        connHost: 'a b',
        port: 8770,
        group: 'g&x=1',
        mode: AuthMode.open,
      );
      final s = p.build();
      // 原始的 & 和 = 不应原样出现在 group 值里
      expect(s.contains('group=g&x=1'), isFalse);
    });
  });

  group('PairUri.tryParse (§15.1)', () {
    test('build → tryParse 往返（required 带 psk）', () {
      const orig = PairUri(
        connHost: '192.168.1.10',
        port: 8771,
        group: 'lobby',
        mode: AuthMode.required,
        psk: 'abc123def',
        wss: true,
        name: '大厅',
      );
      final back = PairUri.tryParse(orig.build())!;
      expect(back.connHost, '192.168.1.10');
      expect(back.port, 8771);
      expect(back.group, 'lobby');
      expect(back.mode, AuthMode.required);
      expect(back.psk, 'abc123def');
      expect(back.wss, isTrue);
      expect(back.name, '大厅');
    });

    test('open URI 解析后 psk 为 null', () {
      final back = PairUri.tryParse('lmw://pair?host=h&port=8770&group=g&mode=open')!;
      expect(back.mode, AuthMode.open);
      expect(back.psk, isNull);
      expect(back.wss, isFalse);
    });

    test('未知 query 参数被忽略（向前兼容）', () {
      final back = PairUri.tryParse(
          'lmw://pair?host=h&port=8770&group=g&mode=open&future=xyz&v=9')!;
      expect(back.connHost, 'h');
      expect(back.group, 'g');
    });

    test('open 模式即便带 psk 也忽略（§15.1）', () {
      final back = PairUri.tryParse(
          'lmw://pair?host=h&port=8770&group=g&mode=open&psk=leak')!;
      expect(back.psk, isNull);
    });

    test('缺 host → null', () {
      expect(PairUri.tryParse('lmw://pair?port=8770&group=g&mode=open'), isNull);
    });

    test('错 scheme / host → null', () {
      expect(PairUri.tryParse('http://pair?host=h'), isNull);
      expect(PairUri.tryParse('lmw://other?host=h'), isNull);
      expect(PairUri.tryParse('not a uri at all %%%'), isNull);
    });

    test('缺 port → 默认 8770；缺 mode → open', () {
      final back = PairUri.tryParse('lmw://pair?host=h&group=g')!;
      expect(back.port, 8770);
      expect(back.mode, AuthMode.open);
    });

    test('wss 真值识别 1/true/yes', () {
      for (final v in ['1', 'true', 'yes']) {
        final back = PairUri.tryParse('lmw://pair?host=h&wss=$v')!;
        expect(back.wss, isTrue, reason: 'wss=$v');
      }
      final back0 = PairUri.tryParse('lmw://pair?host=h&wss=0')!;
      expect(back0.wss, isFalse);
    });
  });
}
