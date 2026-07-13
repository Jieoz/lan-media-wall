import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/net/media_upload.dart';

void main() {
  group('parseSingleByteRange', () {
    test('returns the full representation when Range is absent', () {
      expect(parseSingleByteRange(null, 10), const MediaByteRange(0, 9, false));
    });

    test('supports closed and open-ended ranges', () {
      expect(parseSingleByteRange('bytes=2-5', 10),
          const MediaByteRange(2, 5, true));
      expect(parseSingleByteRange('bytes=7-', 10),
          const MediaByteRange(7, 9, true));
      expect(parseSingleByteRange('bytes=7-99', 10),
          const MediaByteRange(7, 9, true));
    });

    test('supports suffix ranges', () {
      expect(parseSingleByteRange('bytes=-3', 10),
          const MediaByteRange(7, 9, true));
      expect(parseSingleByteRange('bytes=-99', 10),
          const MediaByteRange(0, 9, true));
    });

    test('rejects malformed and multiple ranges', () {
      for (final value in <String>[
        'bytes=',
        'bytes=-',
        'bytes=abc-def',
        'bytes=1-2,4-5',
        'bytes= 1-2',
        'Bytes=1-2',
        'items=1-2',
        'bytes=+1-2',
        'bytes=1--2',
      ]) {
        expect(() => parseSingleByteRange(value, 10),
            throwsA(isA<MediaRangeNotSatisfiable>()),
            reason: value);
      }
    });

    test('rejects unsatisfiable boundaries', () {
      for (final value in <String>[
        'bytes=10-',
        'bytes=9-8',
        'bytes=-0',
      ]) {
        expect(() => parseSingleByteRange(value, 10),
            throwsA(isA<MediaRangeNotSatisfiable>()),
            reason: value);
      }
    });

    test('empty representations reject every Range but allow full response', () {
      expect(parseSingleByteRange(null, 0), const MediaByteRange(0, -1, false));
      expect(() => parseSingleByteRange('bytes=0-', 0),
          throwsA(isA<MediaRangeNotSatisfiable>()));
      expect(() => parseSingleByteRange('bytes=-1', 0),
          throwsA(isA<MediaRangeNotSatisfiable>()));
    });

    test('rejects a negative total', () {
      expect(() => parseSingleByteRange(null, -1), throwsArgumentError);
    });
  });
}
