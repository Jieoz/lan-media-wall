/// 协议各消息类型的 Dart 模型（序列化 / 反序列化），对齐 protocol_spec.md §4–§9。
///
/// 出站命令的 payload 由各 build* 静态方法产出（纯 Map，交给 EnvelopeCodec 签名）；
/// 入站数据（wall / status / thumb_meta）由对应 model 的 fromMap 解析。

int _asInt(Object? v, [int def = 0]) =>
    v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? def : def);

String _asStr(Object? v, [String def = '']) => v is String ? v : def;

bool _asBool(Object? v, [bool def = false]) => v is bool ? v : def;

/// 媒体单元（§6.1）。
class MediaItem {
  final String itemId;
  final String type; // "video" | "image"
  final String name;
  final String url;
  final int? size;
  final String? sha256;
  final int? durationMs; // image 必填；video 可选
  final bool loop;

  const MediaItem({
    required this.itemId,
    required this.type,
    required this.name,
    required this.url,
    this.size,
    this.sha256,
    this.durationMs,
    this.loop = false,
  });

  bool get isImage => type == 'image';

  Map<String, dynamic> toMap() => {
        'item_id': itemId,
        'type': type,
        'name': name,
        'url': url,
        if (size != null) 'size': size,
        if (sha256 != null) 'sha256': sha256,
        if (durationMs != null) 'duration_ms': durationMs,
        'loop': loop,
      };

  static MediaItem fromMap(Map<String, dynamic> m) => MediaItem(
        itemId: _asStr(m['item_id']),
        type: _asStr(m['type'], 'video'),
        name: _asStr(m['name']),
        url: _asStr(m['url']),
        size: m['size'] == null ? null : _asInt(m['size']),
        sha256: m['sha256'] as String?,
        durationMs: m['duration_ms'] == null ? null : _asInt(m['duration_ms']),
        loop: _asBool(m['loop']),
      );
}

/// 设备当前播放项（§5.1 current）。
class CurrentItem {
  final String itemId;
  final String name;
  final int positionMs;
  final int durationMs;

  const CurrentItem({
    required this.itemId,
    required this.name,
    required this.positionMs,
    required this.durationMs,
  });

  static CurrentItem? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    return CurrentItem(
      itemId: _asStr(m['item_id']),
      name: _asStr(m['name']),
      positionMs: _asInt(m['position_ms']),
      durationMs: _asInt(m['duration_ms']),
    );
  }
}

/// 单台设备状态（§5.1 / §5.2 devices 子集）。
class DeviceStatus {
  final String deviceId;
  final String? deviceName;
  final bool online;
  final String groupId;
  final String state; // playing|paused|idle|buffering|downloading
  final CurrentItem? current;
  final String? playlistId;
  final int volume;
  final bool muted;
  final bool audioMaster;
  final Map<String, String> cache;
  final int clockOffsetMs;
  final int cpu;
  final List<String> errors;
  final int? lastSeen;

  const DeviceStatus({
    required this.deviceId,
    this.deviceName,
    this.online = false,
    this.groupId = '',
    this.state = 'idle',
    this.current,
    this.playlistId,
    this.volume = 0,
    this.muted = false,
    this.audioMaster = false,
    this.cache = const {},
    this.clockOffsetMs = 0,
    this.cpu = 0,
    this.errors = const [],
    this.lastSeen,
  });

  static DeviceStatus fromMap(Map<String, dynamic> m) {
    final cacheRaw = (m['cache'] as Map?) ?? {};
    return DeviceStatus(
      deviceId: _asStr(m['device_id']),
      deviceName: m['device_name'] as String?,
      online: _asBool(m['online']),
      groupId: _asStr(m['group_id']),
      state: _asStr(m['state'], 'idle'),
      current:
          CurrentItem.fromMap((m['current'] as Map?)?.cast<String, dynamic>()),
      playlistId: m['playlist_id'] as String?,
      volume: _asInt(m['volume']),
      muted: _asBool(m['muted']),
      audioMaster: _asBool(m['audio_master']),
      cache: {
        for (final e in cacheRaw.entries) e.key.toString(): e.value.toString()
      },
      clockOffsetMs: _asInt(m['clock_offset_ms']),
      cpu: _asInt(m['cpu']),
      errors: ((m['errors'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      lastSeen: m['last_seen'] == null ? null : _asInt(m['last_seen']),
    );
  }
}

/// 分组（§5.2 groups）。
class WallGroup {
  final String groupId;
  final String name;
  final bool sync;
  final String? playlistId;
  final List<String> members;

  const WallGroup({
    required this.groupId,
    this.name = '',
    this.sync = true,
    this.playlistId,
    this.members = const [],
  });

  static WallGroup fromMap(Map<String, dynamic> m) => WallGroup(
        groupId: _asStr(m['group_id']),
        name: _asStr(m['name']),
        sync: _asBool(m['sync'], true),
        playlistId: m['playlist_id'] as String?,
        members: ((m['members'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// 设备墙快照（§5.2 wall payload）。
class WallSnapshot {
  final int serverTime;
  final List<WallGroup> groups;
  final List<DeviceStatus> devices;

  const WallSnapshot({
    this.serverTime = 0,
    this.groups = const [],
    this.devices = const [],
  });

  static WallSnapshot fromMap(Map<String, dynamic> m) => WallSnapshot(
        serverTime: _asInt(m['server_time']),
        groups: ((m['groups'] as List?) ?? const [])
            .map((e) => WallGroup.fromMap((e as Map).cast<String, dynamic>()))
            .toList(),
        devices: ((m['devices'] as List?) ?? const [])
            .map((e) => DeviceStatus.fromMap((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// 缩略图元信息（§6.4），随后紧跟一个二进制帧。
class ThumbMeta {
  final String deviceId;
  final int seq;
  final int bytes;
  final String mime;

  const ThumbMeta({
    required this.deviceId,
    required this.seq,
    required this.bytes,
    this.mime = 'image/jpeg',
  });

  static ThumbMeta fromMap(Map<String, dynamic> m) => ThumbMeta(
        deviceId: _asStr(m['device_id']),
        seq: _asInt(m['seq']),
        bytes: _asInt(m['bytes']),
        mime: _asStr(m['mime'], 'image/jpeg'),
      );
}

/// UDP announce（§7）。
class AnnounceInfo {
  final String deviceId;
  final String deviceName;
  final String ip;
  final String? brokerHint;

  const AnnounceInfo({
    required this.deviceId,
    required this.deviceName,
    required this.ip,
    this.brokerHint,
  });

  static AnnounceInfo fromMap(Map<String, dynamic> m) => AnnounceInfo(
        deviceId: _asStr(m['device_id']),
        deviceName: _asStr(m['device_name']),
        ip: _asStr(m['ip']),
        brokerHint: m['broker_hint'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'device_id': deviceId,
        'device_name': deviceName,
        'ip': ip,
        if (brokerHint != null) 'broker_hint': brokerHint,
      };
}

/// 把毫秒格式化成 mm:ss（用于设备墙进度展示）。
String fmtMs(int ms) {
  if (ms < 0) ms = 0;
  final totalSec = ms ~/ 1000;
  final m = totalSec ~/ 60;
  final s = totalSec % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// 出站命令 payload 构造器（controller→broker，broker 再扇出到 group/player）。
///
/// 路由：信封 `to` 字段交给 BrokerClient 按 group/device 填写；
/// payload 内同时带 group_id / device_id，便于 broker 精确扇出（与 §9 一致）。
class Commands {
  /// hello（§4.1 controller）。
  static Map<String, dynamic> hello({
    required String controllerId,
    String appVersion = '1.0.0',
  }) =>
      {
        'role': 'controller',
        'controller_id': controllerId,
        'app_version': appVersion,
      };

  /// cache_prefetch（§6.2）。
  static Map<String, dynamic> cachePrefetch(List<MediaItem> items) => {
        'items': items.map((e) => e.toMap()).toList(),
      };

  /// playlist 下发（§6.3）。
  static Map<String, dynamic> playlist({
    required String playlistId,
    required String groupId,
    required bool sync,
    required bool loop,
    required List<MediaItem> items,
  }) =>
      {
        'playlist_id': playlistId,
        'group_id': groupId,
        'sync': sync,
        'loop': loop,
        'items': items.map((e) => e.toMap()).toList(),
      };

  /// prepare（§9.1）。
  static Map<String, dynamic> prepare({
    required String playlistId,
    required String groupId,
    int startIndex = 0,
    int seekMs = 0,
  }) =>
      {
        'playlist_id': playlistId,
        'group_id': groupId,
        'start_index': startIndex,
        'seek_ms': seekMs,
      };

  static Map<String, dynamic> pause({String? groupId, String? deviceId}) =>
      _target(groupId: groupId, deviceId: deviceId);

  static Map<String, dynamic> resume({String? groupId, String? deviceId}) =>
      _target(groupId: groupId, deviceId: deviceId);

  static Map<String, dynamic> stop({String? groupId, String? deviceId}) =>
      _target(groupId: groupId, deviceId: deviceId);

  static Map<String, dynamic> next({String? groupId, String? deviceId}) =>
      _target(groupId: groupId, deviceId: deviceId);

  static Map<String, dynamic> prev({String? groupId, String? deviceId}) =>
      _target(groupId: groupId, deviceId: deviceId);

  static Map<String, dynamic> setVolume({
    required int volume,
    String? groupId,
    String? deviceId,
  }) =>
      {
        'volume': volume.clamp(0, 100),
        ..._target(groupId: groupId, deviceId: deviceId),
      };

  static Map<String, dynamic> setMute({
    required bool muted,
    String? groupId,
    String? deviceId,
  }) =>
      {
        'muted': muted,
        ..._target(groupId: groupId, deviceId: deviceId),
      };

  /// set_audio_master（§9.3）：指定本组哪几台出声。
  static Map<String, dynamic> setAudioMaster({
    required String groupId,
    required List<String> deviceIds,
  }) =>
      {
        'group_id': groupId,
        'device_ids': deviceIds,
      };

  /// assign_group（§9.3）。
  static Map<String, dynamic> assignGroup({
    required String deviceId,
    required String groupId,
  }) =>
      {
        'device_id': deviceId,
        'group_id': groupId,
      };

  static Map<String, dynamic> _target({String? groupId, String? deviceId}) => {
        if (groupId != null) 'group_id': groupId,
        if (deviceId != null) 'device_id': deviceId,
      };
}
