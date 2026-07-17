/// 直观 versionCode 编解码（现场推送升级用）。
///
/// 约定（与 pubspec `version: X.Y.Z+N` 的 **N** 对齐）：
///   versionCode = major * 1000 + minor * 10 + patch
/// 例：
///   v1.17.1 → 1171
///   v1.17.2 → 1172
///   v1.17.3 → 1173
///
/// 升级对话框同时接受：
///   - 纯整数：`1173` / 历史小号 `72`
///   - 版本名：`v1.17.3` / `1.17.3`
///   - pubspec 全写：`1.17.3+1173`（优先取 `+` 后整数）
library;

class ParsedVersionCode {
  final int code;
  final String? displayName; // e.g. 1.17.3 when derived from dotted form
  final String source; // 'int' | 'name' | 'pubspec'
  const ParsedVersionCode(this.code, {this.displayName, required this.source});
}

/// Encode dotted name → intuitive code. Returns null if unparsable / out of range.
int? encodeVersionName(String raw) {
  final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$', caseSensitive: false)
      .firstMatch(raw.trim());
  if (m == null) return null;
  final major = int.tryParse(m.group(1)!);
  final minor = int.tryParse(m.group(2)!);
  final patch = int.tryParse(m.group(3)!);
  if (major == null || minor == null || patch == null) return null;
  if (major < 0 || major > 99 || minor < 0 || minor > 99 || patch < 0 || patch > 9) {
    return null;
  }
  return major * 1000 + minor * 10 + patch;
}

/// Best-effort reverse for hints (1172 → 1.17.2). Null if not in scheme range.
String? decodeVersionCode(int code) {
  if (code < 1000 || code > 99999) return null;
  final major = code ~/ 1000;
  final rest = code % 1000;
  final minor = rest ~/ 10;
  final patch = rest % 10;
  if (major <= 0 || major > 99) return null;
  return '$major.$minor.$patch';
}

/// Parse operator input from the remote-update dialog.
/// Returns null when empty / not a positive code.
ParsedVersionCode? parseUpgradeVersionInput(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;

  // pubspec form: 1.17.3+1173
  final plus = s.indexOf('+');
  if (plus > 0) {
    final namePart = s.substring(0, plus).trim();
    final codePart = s.substring(plus + 1).trim();
    final code = int.tryParse(codePart);
    if (code != null && code > 0) {
      final name = namePart.replaceFirst(RegExp(r'^[vV]'), '');
      return ParsedVersionCode(code, displayName: name, source: 'pubspec');
    }
  }

  // dotted version name → encode
  final encoded = encodeVersionName(s);
  if (encoded != null && encoded > 0) {
    final name = s.trim().replaceFirst(RegExp(r'^[vV]'), '');
    return ParsedVersionCode(encoded, displayName: name, source: 'name');
  }

  // bare integer
  if (RegExp(r'^\d+$').hasMatch(s)) {
    final code = int.tryParse(s);
    if (code != null && code > 0) {
      return ParsedVersionCode(
        code,
        displayName: decodeVersionCode(code),
        source: 'int',
      );
    }
  }
  return null;
}
