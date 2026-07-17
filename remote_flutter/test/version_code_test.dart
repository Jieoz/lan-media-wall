import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/util/version_code.dart';

void main() {
  group('encodeVersionName', () {
    test('v1.17.1 → 1171, v1.17.2 → 1172', () {
      expect(encodeVersionName('v1.17.1'), 1171);
      expect(encodeVersionName('1.17.1'), 1171);
      expect(encodeVersionName('1.17.2'), 1172);
      expect(encodeVersionName('1.17.3'), 1173);
    });
  });

  group('parseUpgradeVersionInput', () {
    test('accepts intuitive int', () {
      final p = parseUpgradeVersionInput('1172')!;
      expect(p.code, 1172);
      expect(p.displayName, '1.17.2');
      expect(p.source, 'int');
    });

    test('accepts version name', () {
      final p = parseUpgradeVersionInput('v1.17.3')!;
      expect(p.code, 1173);
      expect(p.displayName, '1.17.3');
      expect(p.source, 'name');
    });

    test('pubspec form prefers +code', () {
      final p = parseUpgradeVersionInput('1.17.3+1173')!;
      expect(p.code, 1173);
      expect(p.source, 'pubspec');
    });

    test('legacy small codes still accepted', () {
      final p = parseUpgradeVersionInput('72')!;
      expect(p.code, 72);
      expect(p.source, 'int');
    });

    test('rejects garbage', () {
      expect(parseUpgradeVersionInput(''), isNull);
      expect(parseUpgradeVersionInput('abc'), isNull);
      expect(parseUpgradeVersionInput('1.17'), isNull);
    });
  });

  group('decodeVersionCode', () {
    test('1172 → 1.17.2', () {
      expect(decodeVersionCode(1172), '1.17.2');
      expect(decodeVersionCode(72), isNull);
    });
  });
}
