import 'dart:typed_data';
import 'dart:convert';

const playerPackageName = 'com.jieoz.lanmediawall.player';

class ApkManifestInfo {
  const ApkManifestInfo({
    required this.packageName,
    required this.versionCode,
    this.versionName,
  });

  final String packageName;
  final int versionCode;
  final String? versionName;
}

ApkManifestInfo parseApkManifest(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 8 || _u16(data, 0) != 0x0003) {
    throw const FormatException('APK manifest is not Android binary XML');
  }
  final total = _u32(data, 4);
  if (total > bytes.length || total < 8) {
    throw const FormatException('truncated APK manifest');
  }

  List<String>? strings;
  var offset = _u16(data, 2);
  while (offset + 8 <= total) {
    final type = _u16(data, offset);
    final headerSize = _u16(data, offset + 2);
    final size = _u32(data, offset + 4);
    if (headerSize < 8 || size < headerSize || offset + size > total) {
      throw const FormatException('invalid APK manifest chunk');
    }
    if (type == 0x0001) {
      strings = _readStringPool(data, offset, size);
    } else if (type == 0x0102 && strings != null) {
      final name = _stringAt(strings, _u32(data, offset + 20));
      if (name == 'manifest') {
        return _readManifestElement(data, offset, size, strings);
      }
    }
    offset += size;
  }
  throw const FormatException('manifest element not found');
}

ApkManifestInfo validatePlayerApkManifest(ApkManifestInfo info) {
  if (info.packageName != playerPackageName) {
    throw FormatException('wrong APK package: ${info.packageName}');
  }
  if (info.versionCode <= 0) {
    throw const FormatException('APK versionCode must be positive');
  }
  return info;
}

ApkManifestInfo _readManifestElement(
    ByteData data, int chunk, int chunkSize, List<String> strings) {
  if (chunkSize < 36) throw const FormatException('short manifest element');
  final attributeStart = _u16(data, chunk + 24);
  final attributeSize = _u16(data, chunk + 26);
  final attributeCount = _u16(data, chunk + 28);
  if (attributeSize < 20) throw const FormatException('invalid attribute size');

  String? packageName;
  int? versionCode;
  String? versionName;
  for (var i = 0; i < attributeCount; i++) {
    final attr = chunk + 16 + attributeStart + i * attributeSize;
    if (attr + 20 > chunk + chunkSize) {
      throw const FormatException('truncated manifest attribute');
    }
    final name = _stringAt(strings, _u32(data, attr + 4));
    final raw = _u32(data, attr + 8);
    final type = data.getUint8(attr + 15);
    final value = _u32(data, attr + 16);
    String? stringValue;
    if (raw != 0xffffffff) stringValue = _stringAt(strings, raw);
    if (stringValue == null && type == 0x03) {
      stringValue = _stringAt(strings, value);
    }
    if (name == 'package') {
      packageName = stringValue;
    } else if (name == 'versionCode') {
      versionCode = type == 0x10 || type == 0x11
          ? value
          : int.tryParse(stringValue ?? '');
    } else if (name == 'versionName') {
      versionName = stringValue;
    }
  }
  if (packageName == null || packageName.isEmpty || versionCode == null) {
    throw const FormatException('APK package/versionCode missing');
  }
  return ApkManifestInfo(
    packageName: packageName,
    versionCode: versionCode,
    versionName: versionName,
  );
}

List<String> _readStringPool(ByteData data, int chunk, int chunkSize) {
  if (chunkSize < 28) throw const FormatException('short string pool');
  final count = _u32(data, chunk + 8);
  final flags = _u32(data, chunk + 16);
  final stringsStart = _u32(data, chunk + 20);
  final headerSize = _u16(data, chunk + 2);
  if (count > 100000 || headerSize + count * 4 > chunkSize) {
    throw const FormatException('invalid string pool');
  }
  final isUtf8 = flags & 0x100 != 0;
  return List<String>.generate(count, (i) {
    final relative = _u32(data, chunk + headerSize + i * 4);
    var cursor = chunk + stringsStart + relative;
    if (cursor >= chunk + chunkSize) {
      throw const FormatException('string outside pool');
    }
    if (isUtf8) {
      final chars = _length8(data, cursor);
      cursor += chars.$2;
      final byteLength = _length8(data, cursor);
      cursor += byteLength.$2;
      if (cursor + byteLength.$1 > chunk + chunkSize) {
        throw const FormatException('truncated UTF-8 string');
      }
      return utf8.decode(
          data.buffer.asUint8List(data.offsetInBytes + cursor, byteLength.$1));
    }
    final length = _length16(data, cursor);
    cursor += length.$2;
    if (cursor + length.$1 * 2 > chunk + chunkSize) {
      throw const FormatException('truncated UTF-16 string');
    }
    return String.fromCharCodes(
        List<int>.generate(length.$1, (i) => _u16(data, cursor + i * 2)));
  });
}

(int, int) _length8(ByteData data, int offset) {
  final first = data.getUint8(offset);
  return first & 0x80 == 0
      ? (first, 1)
      : (((first & 0x7f) << 8) | data.getUint8(offset + 1), 2);
}

(int, int) _length16(ByteData data, int offset) {
  final first = _u16(data, offset);
  return first & 0x8000 == 0
      ? (first, 2)
      : (((first & 0x7fff) << 16) | _u16(data, offset + 2), 4);
}

String? _stringAt(List<String> strings, int index) =>
    index == 0xffffffff || index >= strings.length ? null : strings[index];

int _u16(ByteData data, int offset) => data.getUint16(offset, Endian.little);
int _u32(ByteData data, int offset) => data.getUint32(offset, Endian.little);
