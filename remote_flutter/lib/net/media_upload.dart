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

/// 模式 A 的控制端临时 HTTP 服务(§20.2)。仅在分发窗口存活:注册若干本地文件,
/// 对被控端提供 `GET /m/<itemId>`(支持 Range 断点续传,与 broker 媒体库同契约)。
/// 分发+全员就绪起播后可 [stop](被控端已缓存到本地,不再依赖此服务)。
class LocalMediaServer {
  HttpServer? _server;
  final Map<String, _Served> _files = {};
  String _host = '';

  int get port => _server?.port ?? 0;
  bool get running => _server != null;

  /// 启动服务,绑定到 [bindHost](控制端 LAN IP,用于对外 URL)。端口 0 = 系统分配。
  Future<void> start({required String bindHost, int port = 0}) async {
    if (_server != null) return;
    _host = bindHost;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handle, onError: (_) {});
  }

  /// 登记一个本地文件,返回其可 GET 的 URL(指向控制端 IP)。
  String register({required String itemId, required File file, String ext = ''}) {
    _files[itemId] = _Served(file, ext);
    final suffix = ext.isEmpty ? '' : '.$ext';
    return 'http://$_host:$port/m/$itemId$suffix';
  }

  Future<void> _handle(HttpRequest req) async {
    final resp = req.response;
    // 路径 /m/<itemId>[.ext]
    final seg = req.uri.pathSegments;
    if (seg.length != 2 || seg[0] != 'm') {
      resp.statusCode = HttpStatus.notFound;
      await resp.close();
      return;
    }
    final itemId = seg[1].split('.').first;
    final served = _files[itemId];
    if (served == null || !await served.file.exists()) {
      resp.statusCode = HttpStatus.notFound;
      await resp.close();
      return;
    }
    final total = await served.file.length();
    resp.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    resp.headers.contentType = ContentType.parse(served.contentType);

    // Range 支持(断点续传,§6.2/§20.2)。
    final range = req.headers.value(HttpHeaders.rangeHeader);
    var start = 0, end = total - 1;
    if (range != null && range.startsWith('bytes=')) {
      final spec = range.substring(6).split('-');
      start = int.tryParse(spec[0]) ?? 0;
      if (spec.length > 1 && spec[1].isNotEmpty) {
        end = int.tryParse(spec[1]) ?? end;
      }
      if (start > end || start >= total) {
        resp.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        resp.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await resp.close();
        return;
      }
      end = end.clamp(0, total - 1);
      resp.statusCode = HttpStatus.partialContent;
      resp.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    }
    resp.headers.contentLength = end - start + 1;
    if (req.method == 'HEAD') {
      await resp.close();
      return;
    }
    try {
      await resp.addStream(served.file.openRead(start, end + 1));
    } catch (_) {/* 客户端断开等 */}
    await resp.close();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _files.clear();
  }
}

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
