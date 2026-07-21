import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/util/apk_manifest.dart';

void main() {
  test('reads package, versionCode and literal versionName from binary AXML',
      () {
    final manifest = _manifest(
      packageName: 'com.jieoz.lanmediawall.player',
      versionCode: 1183,
      versionName: '1.18.3',
    );

    final info = parseApkManifest(manifest);
    expect(info.packageName, 'com.jieoz.lanmediawall.player');
    expect(info.versionCode, 1183);
    expect(info.versionName, '1.18.3');
  });

  test('rejects a non-player APK before upload', () {
    final manifest = _manifest(
      packageName: 'example.invalid',
      versionCode: 1183,
      versionName: '1.18.3',
    );

    expect(
      () => validatePlayerApkManifest(parseApkManifest(manifest)),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects malformed binary XML', () {
    expect(() => parseApkManifest(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FormatException>()));
  });
}

Uint8List _manifest({
  required String packageName,
  required int versionCode,
  required String versionName,
}) {
  final strings = <String>[
    'manifest',
    'package',
    packageName,
    'versionCode',
    'versionName',
    versionName,
  ];
  final stringPool = _stringPool(strings);
  final element = BytesBuilder();
  _u16(element, 0x0102);
  _u16(element, 16);
  _u32(element, 36 + 3 * 20);
  _u32(element, 1);
  _u32(element, 0xffffffff);
  _u32(element, 0xffffffff);
  _u32(element, 0); // manifest
  _u16(element, 20);
  _u16(element, 20);
  _u16(element, 3);
  _u16(element, 0);
  _u16(element, 0);
  _u16(element, 0);
  _attribute(element, name: 1, raw: 2, type: 0x03, data: 2);
  _attribute(element, name: 3, raw: 0xffffffff, type: 0x10, data: versionCode);
  _attribute(element, name: 4, raw: 5, type: 0x03, data: 5);

  final body = BytesBuilder()
    ..add(stringPool)
    ..add(element.toBytes());
  final out = BytesBuilder();
  _u16(out, 0x0003);
  _u16(out, 8);
  _u32(out, 8 + body.length);
  out.add(body.toBytes());
  return out.toBytes();
}

Uint8List _stringPool(List<String> strings) {
  final data = BytesBuilder();
  final offsets = <int>[];
  for (final value in strings) {
    offsets.add(data.length);
    final units = value.codeUnits;
    _u16(data, units.length);
    for (final unit in units) {
      _u16(data, unit);
    }
    _u16(data, 0);
  }
  while (data.length % 4 != 0) {
    data.addByte(0);
  }
  const headerSize = 28;
  final stringsStart = headerSize + offsets.length * 4;
  final out = BytesBuilder();
  _u16(out, 0x0001);
  _u16(out, headerSize);
  _u32(out, stringsStart + data.length);
  _u32(out, strings.length);
  _u32(out, 0);
  _u32(out, 0); // UTF-16
  _u32(out, stringsStart);
  _u32(out, 0);
  for (final offset in offsets) {
    _u32(out, offset);
  }
  out.add(data.toBytes());
  return out.toBytes();
}

void _attribute(BytesBuilder out,
    {required int name,
    required int raw,
    required int type,
    required int data}) {
  _u32(out, 0xffffffff);
  _u32(out, name);
  _u32(out, raw);
  _u16(out, 8);
  out.addByte(0);
  out.addByte(type);
  _u32(out, data);
}

void _u16(BytesBuilder out, int value) => out.add([
      value & 0xff,
      (value >> 8) & 0xff,
    ]);

void _u32(BytesBuilder out, int value) => out.add([
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ]);
