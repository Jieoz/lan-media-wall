import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/messages.dart';

void main() {
  test('music playlist wire contract rejects visual media', () {
    const audio = MediaItem(
        itemId: 'a', type: 'audio', name: 'A', url: 'http://x/a.mp3');
    final payload = Commands.musicPlaylist(
      requestId: 'r1', deviceId: 'dev', playlistId: 'music-dev',
      revision: 7, items: const [audio],
    );
    expect(payload['revision'], 7);
    expect((payload['items'] as List).single['type'], 'audio');
    expect(
      () => Commands.musicPlaylist(
        requestId: 'r2', deviceId: 'dev', playlistId: 'music-dev',
        revision: 8,
        items: const [
          MediaItem(itemId: 'v', type: 'video', name: 'V', url: 'http://x/v.mp4'),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('runtime mode commands keep restore as an action not a fourth mode', () {
    expect(Commands.setRuntimeMode(
      requestId: 'r1', mode: RuntimeMode.standby, groupId: 'g'), {
      'request_id': 'r1', 'group_id': 'g', 'mode': 'standby',
    });
    expect(Commands.restoreRuntimeMode(
      requestId: 'r2', deviceId: 'd'), {
      'request_id': 'r2', 'device_id': 'd',
    });
    expect(RuntimeModeCodec.parse('unknown'), isNull);
  });

  test('device status parses additive music and standby fields defensively', () {
    final status = DeviceStatus.fromMap({
      'device_id': 'd', 'online': true,
      'runtime_mode': 'music', 'previous_active_mode': 'visual',
      'mode_generation': 3, 'music_playlist_id': 'music-dev-1',
      'music_playlist_revision': 9, 'music_playlist_size': 3,
      'music_current_item_id': 'song-b', 'music_shuffle_cycle': 2,
      'music_play_count': 8, 'music_failed_item_ids': ['bad-1'],
      'standby_since_ms': null,
      'capabilities': ['runtime_modes_v1', 'music_shuffle_v1'],
    });
    expect(status.runtimeMode, RuntimeMode.music);
    expect(status.previousActiveMode, RuntimeMode.visual);
    expect(status.modeGeneration, 3);
    expect(status.musicPlaylistId, 'music-dev-1');
    expect(status.musicPlaylistRevision, 9);
    expect(status.musicCurrentItemId, 'song-b');
    expect(status.musicFailedItemIds, ['bad-1']);
    expect(status.supportsRuntimeModes, isTrue);
    expect(status.supportsMusicShuffle, isTrue);
  });

  test('runtime result correlates request and actual device mode', () {
    final result = RuntimeModeResult.fromMap({
      'request_id': 'r1', 'device_id': 'd', 'ok': true,
      'runtime_mode': 'standby', 'previous_active_mode': 'music',
    });
    expect(result.requestId, 'r1');
    expect(result.mode, RuntimeMode.standby);
    expect(result.previousActiveMode, RuntimeMode.music);
  });
}
