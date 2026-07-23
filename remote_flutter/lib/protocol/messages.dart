/// 协议各消息类型的 Dart 模型（序列化 / 反序列化），对齐 protocol_spec.md §4–§9。
///
/// 出站命令的 payload 由各 build* 静态方法产出（纯 Map，交给 EnvelopeCodec 签名）；
/// 入站数据（wall / status / thumb_meta）由对应 model 的 fromMap 解析。
library;

import 'loop_mode.dart';
import 'remote_endpoint.dart';

export 'loop_mode.dart' show LoopMode, LoopModeCodec;

int _asInt(Object? v, [int def = 0]) =>
    v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? def : def);

String _asStr(Object? v, [String def = '']) => v is String ? v : def;

bool _asBool(Object? v, [bool def = false]) => v is bool ? v : def;

enum RuntimeMode { visual, music, standby }

/// Allocate the next music-playlist revision from every authoritative value
/// the Controller has observed. A result can arrive before the next status
/// frame, so relying on status alone can reuse a revision on a rapid re-save.
int nextMusicPlaylistRevision(
  int? statusRevision,
  int? acknowledgedRevision,
) {
  final status = statusRevision ?? 0;
  final acknowledged = acknowledgedRevision ?? 0;
  return (status > acknowledged ? status : acknowledged) + 1;
}

class RuntimeModeCodec {
  static RuntimeMode? parse(Object? raw) {
    final wire = raw?.toString();
    for (final mode in RuntimeMode.values) {
      if (mode.name == wire) return mode;
    }
    return null;
  }
}

/// 媒体单元（§6.1）。
class MediaItem {
  final String itemId;
  final String type; // "video" | "image" | "audio"
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
  bool get isAudio => type == 'audio';

  /// Copy with a changed [durationMs] (image dwell edit). Everything else is
  /// preserved — only the wire field `duration_ms` (ms) changes; the seconds UI
  /// is a controller-side presentation on top of this millisecond value.
  MediaItem copyWith({int? durationMs}) => MediaItem(
        itemId: itemId,
        type: type,
        name: name,
        url: url,
        size: size,
        sha256: sha256,
        durationMs: durationMs ?? this.durationMs,
        loop: loop,
      );

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

class ActivePlaylist {
  final String playlistId;
  final String groupId;
  final bool sync;
  final LoopMode loopMode;
  final List<MediaItem> items;
  const ActivePlaylist({required this.playlistId, required this.groupId,
    required this.sync, required this.loopMode, required this.items});

  /// Legacy accessor retained for callers that still think in booleans.
  bool get loop => loopMode.legacyLoopBool;

  static ActivePlaylist? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    return ActivePlaylist(
      playlistId: _asStr(m['playlist_id']), groupId: _asStr(m['group_id']),
      sync: _asBool(m['sync'], true),
      loopMode: LoopModeCodec.resolve(m), // §6.3 single fold point
      items: ((m['items'] as List?) ?? const []).whereType<Map>()
          .map((e) => MediaItem.fromMap(e.cast<String, dynamic>())).toList(),
    );
  }
}

class MusicPlaylistSnapshot {
  final String playlistId;
  final int revision;
  final List<MediaItem> items;

  const MusicPlaylistSnapshot({
    required this.playlistId,
    required this.revision,
    required this.items,
  });

  static MusicPlaylistSnapshot? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final items = ((m['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => MediaItem.fromMap(e.cast<String, dynamic>()))
        .where((e) => e.isAudio)
        .toList(growable: false);
    return MusicPlaylistSnapshot(
      playlistId: _asStr(m['playlist_id']),
      revision: _asInt(m['revision']),
      items: items,
    );
  }
}

class PlaylistEditing {
  static List<MediaItem> move(List<MediaItem> source, int from, int to) {
    final out = List<MediaItem>.of(source);
    if (from < 0 || from >= out.length || to < 0 || to >= out.length) return out;
    final item = out.removeAt(from);
    out.insert(to, item);
    return out;
  }
  static List<MediaItem> removeAt(List<MediaItem> source, int index) {
    final out = List<MediaItem>.of(source);
    if (index >= 0 && index < out.length) out.removeAt(index);
    return out;
  }
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

class RuntimeModeResult {
  final String requestId;
  final String deviceId;
  final bool ok;
  final RuntimeMode? mode;
  final RuntimeMode? previousActiveMode;
  final String error;

  const RuntimeModeResult({
    required this.requestId,
    required this.deviceId,
    required this.ok,
    this.mode,
    this.previousActiveMode,
    this.error = '',
  });

  factory RuntimeModeResult.fromMap(Map<String, dynamic> m) =>
      RuntimeModeResult(
        requestId: _asStr(m['request_id']),
        deviceId: _asStr(m['device_id']),
        ok: _asBool(m['ok']),
        mode: RuntimeModeCodec.parse(m['runtime_mode'] ?? m['mode']),
        previousActiveMode: RuntimeModeCodec.parse(m['previous_active_mode']),
        error: _asStr(m['error']),
      );
}

class MusicPlaylistResult {
  final String requestId;
  final String deviceId;
  final bool ok;
  final String playlistId;
  final int? revision;
  final String error;

  const MusicPlaylistResult({
    required this.requestId,
    required this.deviceId,
    required this.ok,
    this.playlistId = '',
    this.revision,
    this.error = '',
  });

  factory MusicPlaylistResult.fromMap(Map<String, dynamic> m) =>
      MusicPlaylistResult(
        requestId: _asStr(m['request_id']),
        deviceId: _asStr(m['device_id']),
        ok: _asBool(m['ok']),
        playlistId: _asStr(m['playlist_id']),
        revision: m['revision'] == null ? null : _asInt(m['revision']),
        error: _asStr(m['error']),
      );
}

/// §26 轻量缓存摘要。周期性 status 里承载,只有总量/可回收/受保护等标量,
/// 不含逐项清单(完整清单按需用 §28 cache_inventory 拉取)。防御式解析:
/// 老端不带该字段时 [DeviceStatus.cacheSummary] 为 null,任何缺失键走 0/空。
class CacheSummary {
  final int readyItems;
  final int totalBytes;
  final int reclaimableItems;
  final int reclaimableBytes;
  final int protectedItems;
  final int inflightItems;
  final int lastCleanupAt;
  final String lastCleanupError;

  const CacheSummary({
    this.readyItems = 0,
    this.totalBytes = 0,
    this.reclaimableItems = 0,
    this.reclaimableBytes = 0,
    this.protectedItems = 0,
    this.inflightItems = 0,
    this.lastCleanupAt = 0,
    this.lastCleanupError = '',
  });

  /// null-in → null-out (老端未上报)。畸形/未知字段不崩:每个键独立防御。
  static CacheSummary? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    return CacheSummary(
      readyItems: _asInt(m['ready_items']),
      totalBytes: _asInt(m['total_bytes']),
      reclaimableItems: _asInt(m['reclaimable_items']),
      reclaimableBytes: _asInt(m['reclaimable_bytes']),
      protectedItems: _asInt(m['protected_items']),
      inflightItems: _asInt(m['inflight_items']),
      lastCleanupAt: _asInt(m['last_cleanup_at']),
      lastCleanupError: _asStr(m['last_cleanup_error']),
    );
  }
}

/// §19 远程配置能力集。播放端在 status 里广告"安全补丁能改哪些字段"以及是否支持
/// 独立高危通道（transport_configure / rotate_device_key）。控制端据此渲染正确的
/// 编辑器并对不支持的端禁用入口。老端不上报时为 null，UI 防御式处理。
class ConfigCapabilities {
  final List<String> safeFields;
  final List<String> transportFields;
  final bool supportsTransportConfigure;
  final bool supportsRotateDeviceKey;
  final int configVersion;

  const ConfigCapabilities({
    this.safeFields = const [],
    this.transportFields = const [],
    this.supportsTransportConfigure = false,
    this.supportsRotateDeviceKey = false,
    this.configVersion = 0,
  });

  static ConfigCapabilities? fromMap(Map<String, dynamic>? m) {
    if (m == null || m.isEmpty) return null;
    return ConfigCapabilities(
      safeFields: ((m['safe_fields'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      transportFields: ((m['transport_fields'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      supportsTransportConfigure: _asBool(m['transport_configure']),
      supportsRotateDeviceKey: _asBool(m['rotate_device_key']),
      configVersion: _asInt(m['config_version']),
    );
  }
}

/// §19 配置快照。控制端的权威视图：`revision` 是乐观并发令牌（回发为 base_revision
/// 检测丢失更新）；脱敏值——**绝不含 psk 明文**，只有 [pskConfigured] 标记是否已配
/// 真钥（§19.5 脱敏边界）。传输字段单列，便于 UI 展示当前接入而无需 rotate 往返。
class ConfigSnapshot {
  final int revision;
  final String? deviceName;
  final String? groupId;
  final int volume;
  final bool muted;
  final bool pskConfigured;
  final String? brokerHost;
  final int? brokerPort;
  final bool? useWss;
  final bool autoDiscovery;
  final String transportMode;
  final bool requiresRestart;

  const ConfigSnapshot({
    this.revision = 0,
    this.deviceName,
    this.groupId,
    this.volume = 0,
    this.muted = false,
    this.pskConfigured = false,
    this.brokerHost,
    this.brokerPort,
    this.useWss,
    this.autoDiscovery = true,
    this.transportMode = 'auto',
    this.requiresRestart = false,
  });

  static ConfigSnapshot? fromMap(Map<String, dynamic>? m) {
    if (m == null || m.isEmpty) return null;
    final values = (m['values'] as Map?)?.cast<String, dynamic>() ?? const {};
    final transport =
        (m['transport'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ConfigSnapshot(
      revision: _asInt(m['revision']),
      deviceName: values['device_name'] as String?,
      groupId: values['group_id'] as String?,
      volume: _asInt(values['volume']),
      muted: _asBool(values['muted']),
      pskConfigured: _asBool(values['psk_configured']),
      brokerHost: transport['broker_host'] as String?,
      brokerPort: transport['broker_port'] == null
          ? null
          : _asInt(transport['broker_port']),
      useWss: transport['use_wss'] is bool ? transport['use_wss'] as bool : null,
      autoDiscovery: _asBool(transport['auto_discovery'], true),
      transportMode: transport['transport_mode'] is String
          ? transport['transport_mode'] as String
          : (_asBool(transport['auto_discovery'], true) ? 'auto' : 'broker'),
      requiresRestart: _asBool(m['requires_restart']),
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
  final RuntimeMode runtimeMode;
  final RuntimeMode? previousActiveMode;
  final int modeGeneration;
  final String musicPlaylistId;
  final int? musicPlaylistRevision;
  final int musicPlaylistSize;
  final MusicPlaylistSnapshot? activeMusicPlaylist;
  final String? musicCurrentItemId;
  final int musicShuffleCycle;
  final int musicPlayCount;
  final List<String> musicFailedItemIds;
  final int? standbySinceMs;
  final CurrentItem? current;
  final String? playlistId;
  /// Per-replace identity echoed by upgraded players after command adoption.
  /// Unlike playlistId, this changes even when a playlist ID is reused.
  final String? pushId;
  final ActivePlaylist? activePlaylist;
  /// §6.3 被控端在有序 active_playlist 中的当前位置与长度（播放器 additive 上报）。
  /// 老端不上报时为 null，UI 防御式处理。
  final int? currentIndex;
  final int? playlistCount;
  final int volume;
  final bool muted;
  final bool audioMaster;
  final Map<String, String> cache;
  final int clockOffsetMs;
  final int cpu;
  final List<String> errors;
  final int? lastSeen;
  final String? updateState;
  final String? updateDetail;
  final int? updateVersionCode;

  /// §26 轻量缓存摘要（可选）。老端不上报时为 null，UI 防御式处理。
  final CacheSummary? cacheSummary;

  /// §4 hello 广告的能力集（video/image/.../cache_cleanup_v1/cache_inventory_v1）。
  /// 只有真正带 live 清理/清单 handler 的播放端才会广告 cache_*_v1（capability
  /// truth, E0001）。控制端据此启用/禁用缓存清理入口，绝不对不支持的端静默超时。
  final List<String> capabilities;

  /// §19 远程配置能力集/快照（可选）。老端不上报时为 null，UI 防御式处理。
  final ConfigCapabilities? configCapabilities;
  final ConfigSnapshot? configSnapshot;

  /// 被控端上报的应用版本号（§4 hello / §5 status 的 `app_version`）。
  /// 单台状态弹窗展示用；缺失时为 null（老端/未上报，防御式处理）。
  final String? appVersion;

  const DeviceStatus({
    required this.deviceId,
    this.deviceName,
    this.online = false,
    this.groupId = '',
    this.state = 'idle',
    this.runtimeMode = RuntimeMode.visual,
    this.previousActiveMode,
    this.modeGeneration = 0,
    this.musicPlaylistId = '',
    this.musicPlaylistRevision,
    this.musicPlaylistSize = 0,
    this.activeMusicPlaylist,
    this.musicCurrentItemId,
    this.musicShuffleCycle = 0,
    this.musicPlayCount = 0,
    this.musicFailedItemIds = const [],
    this.standbySinceMs,
    this.current,
    this.playlistId,
    this.pushId,
    this.activePlaylist,
    this.currentIndex,
    this.playlistCount,
    this.volume = 0,
    this.muted = false,
    this.audioMaster = false,
    this.cache = const {},
    this.clockOffsetMs = 0,
    this.cpu = 0,
    this.errors = const [],
    this.lastSeen,
    this.appVersion,
    this.updateState,
    this.updateDetail,
    this.updateVersionCode,
    this.cacheSummary,
    this.capabilities = const [],
    this.configCapabilities,
    this.configSnapshot,
  });

  /// §27 缓存清理能力真值：仅当播放端广告 `cache_cleanup_v1`（其确有 live handler
  /// 且回终态结果）时为 true。控制端据此启用清理入口，否则显示「不支持/需升级」。
  bool get supportsCacheCleanup => capabilities.contains('cache_cleanup_v1');

  /// §28 缓存清单能力真值。
  bool get supportsCacheInventory => capabilities.contains('cache_inventory_v1');
  bool get supportsRuntimeModes => capabilities.contains('runtime_modes_v1');
  bool get supportsMusicShuffle => capabilities.contains('music_shuffle_v1');

  static DeviceStatus fromMap(Map<String, dynamic> m) {
    final cacheRaw = (m['cache'] as Map?) ?? {};
    return DeviceStatus(
      deviceId: _asStr(m['device_id']),
      deviceName: m['device_name'] as String?,
      online: _asBool(m['online']),
      groupId: _asStr(m['group_id']),
      state: _asStr(m['state'], 'idle'),
      runtimeMode: RuntimeModeCodec.parse(m['runtime_mode']) ?? RuntimeMode.visual,
      previousActiveMode: RuntimeModeCodec.parse(m['previous_active_mode']),
      modeGeneration: _asInt(m['mode_generation']),
      musicPlaylistId: _asStr(m['music_playlist_id']),
      musicPlaylistRevision: m['music_playlist_revision'] == null
          ? null : _asInt(m['music_playlist_revision']),
      musicPlaylistSize: _asInt(m['music_playlist_size']),
      activeMusicPlaylist: MusicPlaylistSnapshot.fromMap(
          (m['active_music_playlist'] as Map?)?.cast<String, dynamic>()),
      musicCurrentItemId: m['music_current_item_id'] as String?,
      musicShuffleCycle: _asInt(m['music_shuffle_cycle']),
      musicPlayCount: _asInt(m['music_play_count']),
      musicFailedItemIds: ((m['music_failed_item_ids'] as List?) ?? const [])
          .map((e) => e.toString()).toList(),
      standbySinceMs: m['standby_since_ms'] == null
          ? null : _asInt(m['standby_since_ms']),
      current:
          CurrentItem.fromMap((m['current'] as Map?)?.cast<String, dynamic>()),
      playlistId: m['playlist_id'] as String?,
      pushId: m['push_id'] as String?,
      activePlaylist: ActivePlaylist.fromMap(
          (m['active_playlist'] as Map?)?.cast<String, dynamic>()),
      currentIndex: m['current_index'] == null ? null : _asInt(m['current_index']),
      playlistCount: m['playlist_count'] == null ? null : _asInt(m['playlist_count']),
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
      appVersion: m['app_version'] as String?,
      updateState: m['update_state'] as String?,
      updateDetail: m['update_detail'] as String?,
      updateVersionCode: m['update_version_code'] == null
          ? null
          : _asInt(m['update_version_code']),
      cacheSummary: CacheSummary.fromMap(
          (m['cache_summary'] as Map?)?.cast<String, dynamic>()),
      capabilities: ((m['capabilities'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      configCapabilities: ConfigCapabilities.fromMap(
          (m['config_capabilities'] as Map?)?.cast<String, dynamic>()),
      configSnapshot: ConfigSnapshot.fromMap(
          (m['config_snapshot'] as Map?)?.cast<String, dynamic>()),
    );
  }

  /// 浅拷贝并覆盖部分字段（p2p 状态墙聚合用：补 last_seen、置 online=false）。
  DeviceStatus copyWith({
    bool? online,
    String? groupId,
    String? state,
    int? volume,
    bool? muted,
    bool? audioMaster,
    int? lastSeen,
  }) =>
      DeviceStatus(
        deviceId: deviceId,
        deviceName: deviceName,
        online: online ?? this.online,
        groupId: groupId ?? this.groupId,
        state: state ?? this.state,
        runtimeMode: runtimeMode,
        previousActiveMode: previousActiveMode,
        modeGeneration: modeGeneration,
        musicPlaylistId: musicPlaylistId,
        musicPlaylistRevision: musicPlaylistRevision,
        musicPlaylistSize: musicPlaylistSize,
        activeMusicPlaylist: activeMusicPlaylist,
        musicCurrentItemId: musicCurrentItemId,
        musicShuffleCycle: musicShuffleCycle,
        musicPlayCount: musicPlayCount,
        musicFailedItemIds: musicFailedItemIds,
        standbySinceMs: standbySinceMs,
        current: current,
        playlistId: playlistId,
        pushId: pushId,
        activePlaylist: activePlaylist,
        currentIndex: currentIndex,
        playlistCount: playlistCount,
        volume: volume ?? this.volume,
        muted: muted ?? this.muted,
        audioMaster: audioMaster ?? this.audioMaster,
        cache: cache,
        clockOffsetMs: clockOffsetMs,
        cpu: cpu,
        errors: errors,
        lastSeen: lastSeen ?? this.lastSeen,
        appVersion: appVersion,
        updateState: updateState,
        updateDetail: updateDetail,
        updateVersionCode: updateVersionCode,
        cacheSummary: cacheSummary,
        capabilities: capabilities,
        configCapabilities: configCapabilities,
        configSnapshot: configSnapshot,
      );
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
  final String itemId;
  final String runtimeMode;
  final int? modeGeneration;
  final String sessionId;
  final int seq;
  final int bytes;
  final String mime;

  const ThumbMeta({
    required this.deviceId,
    this.itemId = '',
    this.runtimeMode = '',
    this.modeGeneration,
    this.sessionId = '',
    required this.seq,
    required this.bytes,
    this.mime = 'image/jpeg',
  });
  static ThumbMeta? fromMap(Map<String, dynamic> m) {
    final meta = ThumbMeta(
      deviceId: _asStr(m['device_id']),
      itemId: _asStr(m['item_id']),
      runtimeMode: _asStr(m['runtime_mode']),
      modeGeneration: m['mode_generation'] == null
          ? null
          : _asInt(m['mode_generation']),
      sessionId: _asStr(m['session_id']),
      seq: _asInt(m['seq']),
      bytes: _asInt(m['bytes']),
      mime: _asStr(m['mime'], 'image/jpeg'),
    );
    return meta.hasCompleteIdentity ? meta : null;
  }

  bool get hasCompleteIdentity =>
      deviceId.isNotEmpty &&
      itemId.isNotEmpty &&
      runtimeMode.isNotEmpty &&
      modeGeneration != null &&
      sessionId.isNotEmpty &&
      seq > 0 &&
      bytes > 0;
}

/// UDP announce（§7 + §13/§14：可带 auth_mode / topology）。
class AnnounceInfo {
  final String deviceId;
  final String deviceName;
  final String ip;
  final String? brokerHint;

  /// 协调端声明的鉴权模式（§13）。缺失时为 null（端侧按默认 open 处理）。
  final String? authMode;

  /// 协调端声明的拓扑（§14）：dedicated|cohosted|p2p。缺失为 null。
  final String? topology;

  const AnnounceInfo({
    required this.deviceId,
    required this.deviceName,
    required this.ip,
    this.brokerHint,
    this.authMode,
    this.topology,
  });

  /// 是否给出了 broker 接入点（有 → 走 A/B；无 → 候选 p2p 直连目标，§14.5）。
  bool get hasBroker => brokerHint != null && brokerHint!.isNotEmpty;

  /// 解析 broker_hint "ip:port" → (host, port)；无 hint 返回 null。
  /// 明确声明 topology=p2p 的 announce 来自被控端自身，它的 broker_hint 只是
  /// 兼容字段，不能据此把控制端切到 broker 路径；否则 raw status/time_sync 会被
  /// BrokerClient 按 broker 合同丢弃，设备永久停在「已发现」，定向配置也无回包。
  ({String host, int port})? get brokerEndpoint {
    if (topology?.toLowerCase() == 'p2p') return null;
    final h = brokerHint;
    if (h == null || h.isEmpty) return null;
    if (normalizeRemoteHost(h).isEmpty) return null;
    final idx = h.lastIndexOf(':');
    if (idx <= 0) {
      return (host: h, port: 8770);
    }
    final host = h.substring(0, idx);
    if (normalizeRemoteHost(host).isEmpty) return null;
    final port = int.tryParse(h.substring(idx + 1)) ?? 8770;
    return (host: host, port: port);
  }

  static AnnounceInfo fromMap(Map<String, dynamic> m) => AnnounceInfo(
        deviceId: _asStr(m['device_id']),
        deviceName: _asStr(m['device_name']),
        ip: _asStr(m['ip']),
        brokerHint: m['broker_hint'] as String?,
        authMode: m['auth_mode'] as String?,
        topology: m['topology'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'device_id': deviceId,
        'device_name': deviceName,
        'ip': ip,
        if (brokerHint != null) 'broker_hint': brokerHint,
        if (authMode != null) 'auth_mode': authMode,
        if (topology != null) 'topology': topology,
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

  /// playlist 下发（§6.3）。[mode] 显式区分 append（控制端普通编排默认：按 item_id
  /// 去重合并到当前有序列表尾部，保留当前播放位置）与 replace（显式整列替换并从头播）。
  /// 老遥控端不带 mode 时播放器仍默认 replace（线协议向后兼容）。
  /// [loopMode] is canonical (§6.3). During the compatibility window we also
  /// emit the legacy boolean `loop = (mode != none)` so un-upgraded players
  /// still wrap a looping list.
  static Map<String, dynamic> playlist({
    required String playlistId,
    required String groupId,
    required bool sync,
    required LoopMode loopMode,
    required List<MediaItem> items,
    String mode = 'append',
    String? pushId,
  }) =>
      {
        'playlist_id': playlistId,
        'group_id': groupId,
        'sync': sync,
        'loop_mode': loopMode.wire,
        'loop': loopMode.legacyLoopBool,
        'mode': mode,
        if (pushId != null && pushId.isNotEmpty) 'push_id': pushId,
        'items': items.map((e) => e.toMap()).toList(),
      };

  /// Device-local audio list. It is never folded into the visual playlist.
  static Map<String, dynamic> musicPlaylist({
    required String requestId,
    required String deviceId,
    required String playlistId,
    required int revision,
    required List<MediaItem> items,
  }) {
    if (deviceId.isEmpty || playlistId.isEmpty || revision < 0 ||
        items.any((item) => !item.isAudio)) {
      throw ArgumentError('music_playlist requires one device and audio-only items');
    }
    return {
      'request_id': requestId,
      'device_id': deviceId,
      'playlist_id': playlistId,
      'revision': revision,
      'items': items.map((item) => item.toMap()).toList(),
    };
  }

  static Map<String, dynamic> setRuntimeMode({
    required String requestId,
    required RuntimeMode mode,
    String? groupId,
    String? deviceId,
  }) => {
        ..._target(groupId: groupId, deviceId: deviceId),
        'request_id': requestId,
        'mode': mode.name,
      };

  static Map<String, dynamic> restoreRuntimeMode({
    required String requestId,
    String? groupId,
    String? deviceId,
  }) => {
        ..._target(groupId: groupId, deviceId: deviceId),
        'request_id': requestId,
      };

  /// prepare（§9.1）。p2p 模式下遥控端自分配 [prepareId]（= prepare 的 msg_id），
  /// 随帧带上以便按会话精确匹配 ready（§9.1 v1.1）。broker 模式下 broker 负责分配，
  /// 此处 [prepareId] 留空即可。
  static Map<String, dynamic> prepare({
    required String playlistId,
    required String groupId,
    int startIndex = 0,
    int seekMs = 0,
    String? prepareId,
    String? pushId,
    bool prefetch = false,
    int? barrierTimeoutMs,
    String? deviceId,
  }) =>
      {
        'playlist_id': playlistId,
        'group_id': groupId,
        'start_index': startIndex,
        'seek_ms': seekMs,
        if (prepareId != null && prepareId.isNotEmpty) 'prepare_id': prepareId,
        if (pushId != null && pushId.isNotEmpty) 'push_id': pushId,
        if (prefetch) 'prefetch': true,
        if (barrierTimeoutMs != null) 'barrier_timeout_ms': barrierTimeoutMs,
        // §9.4b 单台推送：带 device_id 时 broker 只把这一台纳入 ready 会话并单发
        // play_at（不牵动整组）；p2p 下协调端直接把 targets 锁到这一台。
        if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
      };

  /// play_at（§9.2）。p2p 模式下遥控端收齐 ready 后直接下发给各成员。
  static Map<String, dynamic> playAt({
    required String playlistId,
    required String groupId,
    required int playAtMs,
    int startIndex = 0,
    int seekMs = 0,
    String? pushId,
  }) =>
      {
        'playlist_id': playlistId,
        'group_id': groupId,
        'start_index': startIndex,
        'seek_ms': seekMs,
        'play_at': playAtMs,
        if (pushId != null && pushId.isNotEmpty) 'push_id': pushId,
      };

  /// time_sync_ack（§8.1）。p2p 模式下遥控端兼任主时钟，回应 player 的 time_sync。
  static Map<String, dynamic> timeSyncAck({
    required int t1,
    required int t2,
    required int t3,
    String? reqMsgId,
  }) =>
      {
        't1': t1,
        't2': t2,
        't3': t3,
        if (reqMsgId != null) 'req_msg_id': reqMsgId,
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

  /// debug_snapshot：请求被控端返回一段结构化诊断文本。
  /// 走同样的 group/device 目标路由，不新增传输层。
  static Map<String, dynamic> debugSnapshot({String? groupId, String? deviceId}) =>
      _target(groupId: groupId, deviceId: deviceId);

  /// restart（§9.4）：只重启被控端播放 App（不整机重启，保住 Wi-Fi）。
  /// 走 root 守护进程 RESTART_APP。仿 pause/resume 走 [_target] 单播/组播。
  static Map<String, dynamic> restart({String? groupId, String? deviceId}) =>
      _target(groupId: groupId, deviceId: deviceId);

  /// reboot（§10）：整机重启——单独的高危动作（不是普通 restart）。QZX_C1 warm
  /// reboot 会丢 Wi-Fi（SDIO -110，冷启动才恢复），故 UI 必须二次确认后才下发。
  static Map<String, dynamic> reboot({String? groupId, String? deviceId}) =>
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

  /// create_group（§18.1）：新建空分组。
  static Map<String, dynamic> createGroup({
    required String groupId,
    String? name,
    bool? sync,
  }) =>
      {
        'group_id': groupId,
        if (name != null) 'name': name,
        if (sync != null) 'sync': sync,
      };

  /// update_group（§18.2）：改组名/同步模式（只传要改的字段）。
  static Map<String, dynamic> updateGroup({
    required String groupId,
    String? name,
    bool? sync,
  }) =>
      {
        'group_id': groupId,
        if (name != null) 'name': name,
        if (sync != null) 'sync': sync,
      };

  /// delete_group（§18.3）：删组，成员回落 [reassignTo]（默认 default）。
  static Map<String, dynamic> deleteGroup({
    required String groupId,
    String reassignTo = 'default',
  }) =>
      {
        'group_id': groupId,
        'reassign_to': reassignTo,
      };

  /// configure_device (§19): safe per-device patch only. Transport wiring and
  /// key rotation deliberately use their dedicated builders below.
  static Map<String, dynamic> configureDevice({
    required String deviceId,
    String? deviceName,
    String? groupId,
    int? volume,
    bool? muted,
    String? requestId,
    int? baseRevision,
  }) =>
      {
        'device_id': deviceId,
        if (deviceName != null) 'device_name': deviceName,
        if (groupId != null) 'group_id': groupId,
        if (volume != null) 'volume': volume.clamp(0, 100),
        if (muted != null) 'muted': muted,
        if (requestId != null) 'request_id': requestId,
        if (baseRevision != null) 'base_revision': baseRevision,
      };

  static const _safeConfigFields = {
    'device_name',
    'group_id',
    'volume',
    'muted',
  };

  /// Builds a safe §19 patch from a dynamic editor map. The whitelist is
  /// deliberate: callers cannot smuggle transport or secret fields through the
  /// generic editor path.
  static Map<String, dynamic> configPatch({
    required String deviceId,
    required Map<String, dynamic> patch,
    String? requestId,
    int? baseRevision,
  }) {
    final unsupported = patch.keys
        .where((key) => !_safeConfigFields.contains(key))
        .toList(growable: false);
    if (unsupported.isNotEmpty) {
      throw ArgumentError.value(
        unsupported,
        'patch',
        'configure_device only accepts safe configuration fields',
      );
    }
    return {
      'device_id': deviceId,
      ...patch,
      if (requestId != null) 'request_id': requestId,
      if (baseRevision != null) 'base_revision': baseRevision,
    };
  }

  static Map<String, dynamic> transportConfigure({
    required String deviceId,
    required String brokerHost,
    required String transportMode,
    int? brokerPort,
    bool? useWss,
    String? requestId,
    int? rollbackTimeoutMs,
  }) => {
    'device_id': deviceId,
    'broker_host': brokerHost,
    'transport_mode': transportMode,
    if (brokerPort != null) 'broker_port': brokerPort,
    if (useWss != null) 'use_wss': useWss,
    if (requestId != null) 'request_id': requestId,
    if (rollbackTimeoutMs != null) 'rollback_timeout_ms': rollbackTimeoutMs,
  };

  static Map<String, dynamic> rotateDeviceKey({
    required String deviceId,
    required String psk,
    required String requestId,
  }) => {'device_id': deviceId, 'psk': psk, 'request_id': requestId};

  /// update_app（§23）：令目标被控端自更新到 [url] 指向的 APK。
  /// [versionCode] 必须严格大于被控端当前版本（被控端会二次校验，防降级/重放）；
  /// [sha256] 为 64 位十六进制，被控端下载后重算比对（不符拒装）。
  /// 需目标处于已鉴权链路（auth_mode≠open 且已配 PSK），否则被控端拒绝。
  static Map<String, dynamic> updateApp({
    required String url,
    required int versionCode,
    required String sha256,
    String? versionName,
    String? groupId,
    String? deviceId,
  }) =>
      {
        ..._target(groupId: groupId, deviceId: deviceId),
        'url': url,
        'version_code': versionCode,
        'sha256': sha256,
        if (versionName != null) 'version_name': versionName,
      };

  /// §27 cache_cleanup 请求。控制端只发 item ID / 范围,绝不发路径(删除权威在
  /// 播放端)。[requestId] 是幂等键——同一 request_id 重复请求返回原终态、绝不二次
  /// 删除。[dryRun] 只规划回候选、不动磁盘。[expectedPushId] 应用后清理时必填:
  /// 与当前采纳代次不符→整单 generation_mismatch。方向 controller→player,单播时
  /// 带 device_id;整组时带 group_id。
  static Map<String, dynamic> cacheCleanup({
    required String requestId,
    String mode = 'unreferenced',
    List<String>? itemIds,
    bool dryRun = false,
    String? expectedPushId,
    String reason = 'manual',
    String? groupId,
    String? deviceId,
  }) =>
      {
        ..._target(groupId: groupId, deviceId: deviceId),
        'request_id': requestId,
        'mode': mode,
        if (itemIds != null) 'item_ids': itemIds,
        'dry_run': dryRun,
        if (expectedPushId != null && expectedPushId.isNotEmpty)
          'expected_push_id': expectedPushId,
        'reason': reason,
      };

  /// §28 cache_inventory 请求(按需拉取完整逐项清单,不进周期性 status)。
  static Map<String, dynamic> cacheInventory({
    required String requestId,
    String? groupId,
    String? deviceId,
  }) =>
      {
        ..._target(groupId: groupId, deviceId: deviceId),
        'request_id': requestId,
      };

  static Map<String, dynamic> _target({String? groupId, String? deviceId}) => {
        if (groupId != null) 'group_id': groupId,
        if (deviceId != null) 'device_id': deviceId,
      };
}
