import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/net/media_upload.dart';

void main() {
  late Directory temp;
  late File file;
  late File emptyFile;
  late LocalMediaServer server;
  final clients = <HttpClient>[];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('local-media-server-test-');
    file = File('${temp.path}/sample.bin');
    await file.writeAsBytes(List<int>.generate(10, (i) => i));
    emptyFile = File('${temp.path}/empty.bin');
    await emptyFile.writeAsBytes(const []);
    server = LocalMediaServer(maxConcurrentStreams: 2, maxQueuedRequests: 2);
    await server.start(bindHost: InternetAddress.loopbackIPv4.address);
    server.register(itemId: 'sample', file: file, ext: 'bin');
    server.register(itemId: 'empty', file: emptyFile, ext: 'bin');
  });

  tearDown(() async {
    for (final client in clients) {
      client.close(force: true);
    }
    await server.stop();
    await temp.delete(recursive: true);
  });

  HttpClient client() {
    final result = HttpClient();
    clients.add(result);
    return result;
  }

  Uri uri(String item) => Uri.parse('http://127.0.0.1:${server.port}/m/$item.bin');

  Future<({HttpClientResponse response, List<int> body})> request(
    String method,
    String item, {
    String? range,
  }) async {
    final req = await client().openUrl(method, uri(item));
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final response = await req.close();
    final body = await response.fold<List<int>>(<int>[], (out, bytes) => out..addAll(bytes));
    return (response: response, body: body);
  }

  test('GET supports strict closed, open, and suffix byte ranges', () async {
    for (final entry in <(String, List<int>, String)>[
      ('bytes=2-5', [2, 3, 4, 5], 'bytes 2-5/10'),
      ('bytes=7-', [7, 8, 9], 'bytes 7-9/10'),
      ('bytes=-3', [7, 8, 9], 'bytes 7-9/10'),
      ('bytes=-99', List<int>.generate(10, (i) => i), 'bytes 0-9/10'),
    ]) {
      final result = await request('GET', 'sample', range: entry.$1);
      expect(result.response.statusCode, HttpStatus.partialContent, reason: entry.$1);
      expect(result.response.headers.value(HttpHeaders.contentRangeHeader), entry.$3);
      expect(result.response.headers.contentLength, entry.$2.length);
      expect(result.body, entry.$2);
    }
  });

  test('malformed, multiple, empty-file, and out-of-bounds ranges are 416', () async {
    for (final entry in <(String, String)>[
      ('sample', 'bytes=abc-def'),
      ('sample', 'bytes=0-1,3-4'),
      ('sample', 'bytes=10-'),
      ('sample', 'bytes=9-8'),
      ('sample', 'bytes=-0'),
      ('empty', 'bytes=0-'),
      ('empty', 'bytes=-1'),
    ]) {
      final result = await request('GET', entry.$1, range: entry.$2);
      final total = entry.$1 == 'empty' ? 0 : 10;
      expect(result.response.statusCode, HttpStatus.requestedRangeNotSatisfiable,
          reason: entry.$2);
      expect(result.response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes */$total');
      expect(result.body, isEmpty);
    }
  });

  test('duplicate physical Range headers are one empty 416 response', () async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    socket.write('GET /m/sample.bin HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Range: bytes=0-1\r\n'
        'Range: bytes=2-3\r\n'
        'Connection: close\r\n\r\n');
    await socket.flush();
    final raw = await socket.fold<List<int>>(<int>[], (out, bytes) => out..addAll(bytes));
    final response = String.fromCharCodes(raw);
    final split = response.indexOf('\r\n\r\n');
    expect(split, greaterThanOrEqualTo(0));
    expect(response.substring(0, split), contains(' 416 '));
    expect(response.substring(0, split).toLowerCase(), contains('content-length: 0'));
    expect(response.substring(0, split).toLowerCase(), contains('content-range: bytes */10'));
    expect(raw.sublist(split + 4), isEmpty);
  });

  test('empty file without Range is a valid empty 200', () async {
    final result = await request('GET', 'empty');
    expect(result.response.statusCode, HttpStatus.ok);
    expect(result.response.headers.contentLength, 0);
    expect(result.body, isEmpty);
  });

  test('HEAD mirrors GET metadata and never has a body or consumes permit', () async {
    for (final range in <String?>[null, 'bytes=2-5']) {
      final result = await request('HEAD', 'sample', range: range);
      expect(result.response.statusCode,
          range == null ? HttpStatus.ok : HttpStatus.partialContent);
      expect(result.response.headers.contentLength, range == null ? 10 : 4);
      expect(result.response.headers.value(HttpHeaders.contentRangeHeader),
          range == null ? isNull : 'bytes 2-5/10');
      expect(result.body, isEmpty);
      expect(server.activeRequests, 0);
    }
  });

  test('methods other than GET and HEAD return 405 with Allow and empty body', () async {
    for (final method in ['POST', 'PUT', 'DELETE', 'OPTIONS']) {
      final result = await request(method, 'sample');
      expect(result.response.statusCode, HttpStatus.methodNotAllowed, reason: method);
      expect(result.response.headers.value(HttpHeaders.allowHeader), 'GET, HEAD');
      expect(result.response.headers.contentLength, 0);
      expect(result.body, isEmpty);
      expect(server.activeRequests, 0);
    }
  });

  test('successful requests do not make the server stop after ready/play window', () async {
    expect((await request('GET', 'sample')).response.statusCode, HttpStatus.ok);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(server.running, isTrue);
    expect((await request('GET', 'sample')).body, List<int>.generate(10, (i) => i));
  });
}
