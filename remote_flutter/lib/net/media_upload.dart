import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../protocol/messages.dart';

/// 本地媒体上传(protocol_spec v1.4 §20) —— 让控制端本地文件在**分发窗口**变成
/// 被控端可 GET 的 URL。两条路,由 [WallState] 按当前拓扑择一:
///
///  - **模式 B([uploadToBroker])**:broker 模式主路径。把文件 HTTP PUT 到 broker
///    媒体库(`PUT /media/<sha256>.<ext>`),回填 `http://<broker>:<mediaPort>/media/...`
///    的 URL。被控端走现有 cache_prefetch 下载(§6.2),零改动。
///  - **模式 A([LocalMediaServer])**:p2p / 无 broker 兜底。控制端本机起临时 HTTP
///    服务,URL 指向控制端 IP。分发+校验完成后可关服务(§20.2)。
///
/// 播放模型不变:被控端始终从**本地缓存**播放,不流媒体(设计合同 §0)。
class MediaUpload {
  MediaUpload._();

  static const int mediaPort = 8773; // broker 媒体库端口(§20.1)

  /// 计算文件的 sha256(hex) 与大小 —— 两种模式都需要,供被控端完整性校验(§20.3)。
  static Future<({String sha256, int size})> digestFile(File f) async {
    final len = await f.length();
    final sink = _Sha256Sink();
    await f.openRead().forEach(sink.add);
    return (sha256: sink.hex, size: len);
  }

  /// 模式 B:上传到 broker 媒体库,返回可 GET 的 media item(url 已回填)。
  ///
  /// [brokerHost] 为当前 broker 地址;[ext] 取自原文件名后缀(如 mp4/jpg)。
  /// 上传幂等:同 sha256 已在 broker 上则秒回(§20.1)。失败抛异常,调用方回落模式 A。
  static Future<MediaItem> uploadToBroker({
    required File file,
    required String brokerHost,
    required String type, // "video" | "image"
    required String name,
    int? durationMs,
    int port = mediaPort,
    String uploadToken = '',
    void Function(int sent, int total)? onProgress,
  }) async {
    final d = await digestFile(file);
    final ext = _extOf(file.path);
    final path = ext.isEmpty ? '/media/${d.sha256}' : '/media/${d.sha256}.$ext';
    final uri = Uri.parse('http://$brokerHost:$port$path');

    final client = HttpClient();
    try {
      final req = await client.putUrl(uri);
      req.headers.contentType = ContentType.binary;
      req.headers.contentLength = d.size;
      if (uploadToken.trim().isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader,
            'Bearer ${uploadToken.trim()}');
      }
      var sent = 0;
      await for (final chunk in file.openRead()) {
        req.add(chunk);
        sent += chunk.length;
        onProgress?.call(sent, d.size);
      }
      final resp = await req.close();
      // 201 Created(新存) / 200 OK(已存,秒传) 都算成功。
      if (resp.statusCode != 200 && resp.statusCode != 201) {
        final body = await resp.transform(const SystemEncoding().decoder).join();
        throw HttpException('broker 上传失败 ${resp.statusCode}: $body', uri: uri);
      }
      await resp.drain<void>();
      return MediaItem(
        itemId: d.sha256.substring(0, 12),
        type: type,
        name: name,
        url: uri.toString(),
        size: d.size,
        sha256: d.sha256,
        durationMs: durationMs,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 模式 A:把文件登记进本机临时 HTTP 服务,返回 url 指向控制端 IP 的 media item。
  /// 实际的 HTTP serving 由 [LocalMediaServer] 负责;此处仅算摘要 + 拼 URL。
  static Future<MediaItem> registerLocal({
    required File file,
    required LocalMediaServer server,
    required String type,
    required String name,
    int? durationMs,
  }) async {
    final d = await digestFile(file);
    final ext = _extOf(file.path);
    final itemId = d.sha256.substring(0, 12);
    final url = server.register(itemId: itemId, file: file, ext: ext);
    return MediaItem(
      itemId: itemId,
      type: type,
      name: name,
      url: url,
      size: d.size,
      sha256: d.sha256,
      durationMs: durationMs,
    );
  }

  static String _extOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    final ext = path.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,8}$').hasMatch(ext) ? ext : '';
  }
}

/// 捕获单个 [Digest] 的极简 Sink —— 免依赖 package:convert 的 AccumulatorSink。
class _DigestCatcher implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// 流式 sha256 累加器(避免把大视频整个读进内存)。
class _Sha256Sink {
  final _output = _DigestCatcher();
  late final ByteConversionSink _input =
      sha256.startChunkedConversion(_output);

  void add(List<int> chunk) => _input.add(chunk);

  String get hex {
    _input.close();
    return _output.value!.toString();
  }
}

/// Small async admission gate used by [LocalMediaServer]. It bounds concurrent
/// file streams without buffering payloads in memory; queued HTTP handlers keep
/// natural TCP backpressure until a permit is available.
class MediaRequestGate {
  MediaRequestGate(int maxConcurrent, {int maxQueued = 64})
      : maxConcurrent = _positive(maxConcurrent, 'maxConcurrent'),
        maxQueued = _nonNegative(maxQueued, 'maxQueued');

  final int maxConcurrent;
  final int maxQueued;
  int _active = 0;
  bool _closed = false;
  final List<Completer<MediaRequestPermit?>> _waiters = [];

  static int _positive(int value, String name) {
    if (value <= 0) throw ArgumentError.value(value, name, 'must be positive');
    return value;
  }

  static int _nonNegative(int value, String name) {
    if (value < 0) {
      throw ArgumentError.value(value, name, 'must not be negative');
    }
    return value;
  }

  int get active => _active;
  int get queued => _waiters.length;
  bool get closed => _closed;

  Future<MediaRequestPermit?> acquire() {
    if (_closed) return Future.value(null);
    if (_active < maxConcurrent) {
      _active++;
      return Future.value(MediaRequestPermit._(this));
    }
    if (_waiters.length >= maxQueued) return Future.value(null);
    final waiter = Completer<MediaRequestPermit?>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final waiters = List<Completer<MediaRequestPermit?>>.of(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      waiter.complete(null);
    }
  }

  void _release() {
    if (!_closed && _waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(MediaRequestPermit._(this));
      return;
    }
    if (_active > 0) _active--;
  }
}

class MediaRequestPermit {
  MediaRequestPermit._(this._gate);
  final MediaRequestGate _gate;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _gate._release();
  }
}

/// A normalized byte interval for one HTTP representation.
class MediaByteRange {
  const MediaByteRange(this.start, this.end, this.partial);

  final int start;
  final int end;
  final bool partial;

  int get length => end < start ? 0 : end - start + 1;

  @override
  bool operator ==(Object other) =>
      other is MediaByteRange &&
      start == other.start &&
      end == other.end &&
      partial == other.partial;

  @override
  int get hashCode => Object.hash(start, end, partial);

  @override
  String toString() => 'MediaByteRange($start, $end, partial: $partial)';
}

class MediaRangeNotSatisfiable implements Exception {
  const MediaRangeNotSatisfiable();
}

/// Strictly parses one RFC 7233 byte range. This server deliberately rejects
/// malformed and multipart ranges instead of silently serving the whole file.
MediaByteRange parseSingleByteRange(String? header, int total) {
  if (total < 0) throw ArgumentError.value(total, 'total', 'must not be negative');
  if (header == null) return MediaByteRange(0, total - 1, false);

  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header);
  if (match == null) throw const MediaRangeNotSatisfiable();
  final first = match.group(1)!;
  final last = match.group(2)!;
  if (first.isEmpty && last.isEmpty || total == 0) {
    throw const MediaRangeNotSatisfiable();
  }

  if (first.isEmpty) {
    final suffixLength = int.tryParse(last);
    if (suffixLength == null || suffixLength <= 0) {
      throw const MediaRangeNotSatisfiable();
    }
    final start = suffixLength >= total ? 0 : total - suffixLength;
    return MediaByteRange(start, total - 1, true);
  }

  final start = int.tryParse(first);
  final requestedEnd = last.isEmpty ? total - 1 : int.tryParse(last);
  if (start == null || requestedEnd == null || start >= total || start > requestedEnd) {
    throw const MediaRangeNotSatisfiable();
  }
  final end = requestedEnd >= total ? total - 1 : requestedEnd;
  return MediaByteRange(start, end, true);
}

/// 模式 A 的控制端本地 HTTP 服务(§20.2)。服务在控制端状态对象 dispose 前保持存活，
/// 避免首项 ready/play_at 后关闭导致后续节目单项目或新上传无法下载。每次显式 stop 后仍可
/// start 新生命周期；对被控端提供 `GET /m/<itemId>`(支持严格单 Range 断点续传)。
typedef MediaStreamFactory = Stream<List<int>> Function(
  File file,
  int start,
  int endExclusive,
);

class LocalMediaServer {
  LocalMediaServer({
    int maxConcurrentStreams = 6,
    int maxQueuedRequests = 64,
    MediaStreamFactory? streamFactory,
  })  : _maxConcurrentStreams = MediaRequestGate._positive(
            maxConcurrentStreams, 'maxConcurrentStreams'),
        _maxQueuedRequests = MediaRequestGate._nonNegative(
            maxQueuedRequests, 'maxQueuedRequests'),
        _streamFactory = streamFactory ?? _openFileRange;

  final int _maxConcurrentStreams;
  final int _maxQueuedRequests;
  final MediaStreamFactory _streamFactory;
  HttpServer? _server;
  MediaRequestGate? _requestGate;
  final Map<String, _Served> _files = {};
  String _host = '';

  int get port => _server?.port ?? 0;
  bool get running => _server != null;
  int get activeRequests => _requestGate?.active ?? 0;
  int get queuedRequests => _requestGate?.queued ?? 0;

  /// Starts a fresh server lifecycle. Every start gets a new admission gate, so
  /// requests cancelled by [stop] can never leak into a restarted generation.
  Future<void> start({required String bindHost, int port = 0}) async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    final gate = MediaRequestGate(
      _maxConcurrentStreams,
      maxQueued: _maxQueuedRequests,
    );
    _host = bindHost;
    _server = server;
    _requestGate = gate;
    server.listen((request) => _handle(request, gate), onError: (_) {});
  }

  /// 登记一个本地文件,返回其可 GET 的 URL(指向控制端 IP)。
  String register({required String itemId, required File file, String ext = ''}) {
    if (_server == null) throw StateError('LocalMediaServer is not running');
    _files[itemId] = _Served(file, ext);
    final suffix = ext.isEmpty ? '' : '.$ext';
    return 'http://$_host:$port/m/$itemId$suffix';
  }

  Future<void> _empty(HttpResponse response, int status) async {
    response.statusCode = status;
    response.headers.contentLength = 0;
    await response.close();
  }

  Future<void> _handle(HttpRequest req, MediaRequestGate gate) async {
    final resp = req.response;
    if (req.method != 'GET' && req.method != 'HEAD') {
      resp.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await _empty(resp, HttpStatus.methodNotAllowed);
      return;
    }

    // 路径 /m/<itemId>[.ext]
    final seg = req.uri.pathSegments;
    if (seg.length != 2 || seg[0] != 'm') {
      await _empty(resp, HttpStatus.notFound);
      return;
    }
    final itemId = seg[1].split('.').first;
    final served = _files[itemId];
    if (served == null || !await served.file.exists()) {
      await _empty(resp, HttpStatus.notFound);
      return;
    }
    final total = await served.file.length();
    resp.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    resp.headers.contentType = ContentType.parse(served.contentType);

    late final MediaByteRange range;
    try {
      range = parseSingleByteRange(
        req.headers.value(HttpHeaders.rangeHeader),
        total,
      );
    } on MediaRangeNotSatisfiable {
      resp.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
      await _empty(resp, HttpStatus.requestedRangeNotSatisfiable);
      return;
    }

    // HEAD reports exactly the metadata GET would return, but never consumes a
    // stream permit and never emits a response body.
    if (req.method == 'HEAD') {
      if (range.partial) {
        resp.statusCode = HttpStatus.partialContent;
        resp.headers.set(HttpHeaders.contentRangeHeader,
            'bytes ${range.start}-${range.end}/$total');
      }
      resp.headers.contentLength = range.length;
      await resp.close();
      return;
    }

    // Admission precedes every successful range/status/length header. A closed
    // generation and a full queue both produce the same retryable empty 503.
    final permit = await gate.acquire();
    if (permit == null) {
      resp.headers.removeAll(HttpHeaders.contentRangeHeader);
      resp.headers.set(HttpHeaders.retryAfterHeader, '1');
      await _empty(resp, HttpStatus.serviceUnavailable);
      return;
    }

    if (range.partial) {
      resp.statusCode = HttpStatus.partialContent;
      resp.headers.set(HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/$total');
    }
    resp.headers.contentLength = range.length;
    try {
      if (range.length > 0) {
        await resp.addStream(
          _streamFactory(served.file, range.start, range.end + 1),
        );
      }
    } catch (_) {
      // A disconnected client must not retain its admission permit.
    } finally {
      permit.release();
      try {
        await resp.close();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    final server = _server;
    final gate = _requestGate;
    _server = null;
    _requestGate = null;
    _files.clear();
    gate?.close();
    await server?.close(force: true);
  }
}

Stream<List<int>> _openFileRange(File file, int start, int endExclusive) =>
    file.openRead(start, endExclusive);

class _Served {
  _Served(this.file, this.ext);
  final File file;
  final String ext;

  String get contentType {
    switch (ext) {
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mkv':
        return 'video/x-matroska';
      case 'webm':
        return 'video/webm';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      default:
        return 'application/octet-stream';
    }
  }
}
