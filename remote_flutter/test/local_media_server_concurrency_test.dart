import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/net/media_upload.dart';

void main() {
  late Directory temp;
  late File file;
  late LocalMediaServer server;
  final clients = <HttpClient>[];

  tearDown(() async {
    for (final client in clients) {
      client.close(force: true);
    }
    await server.stop();
    await temp.delete(recursive: true);
  });

  HttpClient newClient() {
    final value = HttpClient();
    clients.add(value);
    return value;
  }

  Future<void> waitFor(bool Function() predicate) async {
    for (var i = 0; i < 100; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('condition not reached');
  }

  test('slow HTTP requests obey active limit, FIFO queue, and empty 503 contract',
      () async {
    temp = await Directory.systemTemp.createTemp('media-concurrency-test-');
    file = File('${temp.path}/slow.bin');
    await file.writeAsBytes([1]);
    final streams = <StreamController<List<int>>>[];
    server = LocalMediaServer(
      maxConcurrentStreams: 1,
      maxQueuedRequests: 1,
      streamFactory: (file, start, end) {
        final controller = StreamController<List<int>>();
        streams.add(controller);
        return controller.stream;
      },
    );
    await server.start(bindHost: '127.0.0.1');
    server.register(itemId: 'slow', file: file);
    final uri = Uri.parse('http://127.0.0.1:${server.port}/m/slow');

    Future<HttpClientResponse> get({String? range}) async {
      final request = await newClient().getUrl(uri);
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      return request.close();
    }

    final first = get();
    await waitFor(() => server.activeRequests == 1 && streams.length == 1);
    final second = get();
    await waitFor(() => server.queuedRequests == 1);
    final third = await get(range: 'bytes=0-0');

    expect(third.statusCode, HttpStatus.serviceUnavailable);
    expect(third.headers.value(HttpHeaders.retryAfterHeader), '1');
    expect(third.headers.value(HttpHeaders.contentRangeHeader), isNull);
    expect(third.headers.contentLength, 0);
    expect(await third.fold<List<int>>(<int>[], (a, b) => a..addAll(b)), isEmpty);
    expect(server.activeRequests, 1);
    expect(server.queuedRequests, 1);

    streams[0]
      ..add([1])
      ..close();
    expect((await first).statusCode, HttpStatus.ok);
    await waitFor(() => streams.length == 2);
    expect(server.activeRequests, 1);
    expect(server.queuedRequests, 0);
    streams[1]
      ..add([1])
      ..close();
    expect((await second).statusCode, HttpStatus.ok);
    await waitFor(() => server.activeRequests == 0);
  });

  test('client disconnect returns its permit', () async {
    temp = await Directory.systemTemp.createTemp('media-disconnect-test-');
    file = File('${temp.path}/large.bin');
    await file.writeAsBytes(List<int>.filled(1024 * 1024, 7));
    server = LocalMediaServer(
      maxConcurrentStreams: 1,
      streamFactory: (file, start, end) async* {
        var sent = start;
        while (sent < end) {
          final remaining = end - sent;
          final count = remaining > 1024 ? 1024 : remaining;
          yield List<int>.filled(count, 7);
          sent += count;
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      },
    );
    await server.start(bindHost: '127.0.0.1');
    server.register(itemId: 'large', file: file);

    final socket = await Socket.connect('127.0.0.1', server.port);
    socket.write('GET /m/large HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n');
    await socket.flush();
    await socket.cast<List<int>>().transform(utf8.decoder).first;
    await waitFor(() => server.activeRequests == 1);
    socket.destroy();

    await waitFor(() => server.activeRequests == 0);
  });

  test('stop unblocks queued HTTP requests and restart uses a fresh gate', () async {
    temp = await Directory.systemTemp.createTemp('media-restart-test-');
    file = File('${temp.path}/slow.bin');
    await file.writeAsBytes([1]);
    final blocker = StreamController<List<int>>();
    var blockStream = true;
    server = LocalMediaServer(
      maxConcurrentStreams: 1,
      maxQueuedRequests: 1,
      streamFactory: (source, start, end) => blockStream
          ? blocker.stream
          : source.openRead(start, end),
    );
    await server.start(bindHost: '127.0.0.1');
    server.register(itemId: 'slow', file: file);
    final oldPort = server.port;
    final uri = Uri.parse('http://127.0.0.1:$oldPort/m/slow');

    final first = newClient().getUrl(uri).then((r) => r.close());
    await waitFor(() => server.activeRequests == 1);
    final queued = newClient().getUrl(uri).then((r) => r.close());
    await waitFor(() => server.queuedRequests == 1);

    await server.stop();
    expect(server.activeRequests, 0);
    expect(server.queuedRequests, 0);
    await expectLater(queued, throwsA(anything));
    await expectLater(first, throwsA(anything));

    await blocker.close();
    blockStream = false;
    await server.start(bindHost: '127.0.0.1');
    server.register(itemId: 'slow', file: file);
    final response = await newClient()
        .getUrl(Uri.parse('http://127.0.0.1:${server.port}/m/slow'))
        .then((r) => r.close());
    expect(response.statusCode, HttpStatus.ok);
    expect(await response.fold<List<int>>(<int>[], (a, b) => a..addAll(b)), [1]);
  });
}
