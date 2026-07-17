import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/messages.dart';
import 'package:remote_flutter/state/group_playlist_load.dart';

const _a = MediaItem(itemId: 'a', type: 'video', name: 'A', url: 'http://c/a');
const _b = MediaItem(itemId: 'b', type: 'video', name: 'B', url: 'http://c/b');
const _c = MediaItem(itemId: 'c', type: 'image', name: 'C', url: 'http://c/c');

ActivePlaylist _pl(String id, String group, List<MediaItem> items) =>
    ActivePlaylist(
      playlistId: id,
      groupId: group,
      sync: true,
      loopMode: LoopMode.all,
      items: items,
    );

DeviceStatus _dev(
  String id, {
  bool online = true,
  String state = 'idle',
  ActivePlaylist? active,
  int? currentIndex,
}) =>
    DeviceStatus(
      deviceId: id,
      online: online,
      state: state,
      activePlaylist: active,
      currentIndex: currentIndex,
    );

void main() {
  group('loadGroupPlaylist', () {
    test('empty group fails with a clear message and no draft', () {
      final r = loadGroupPlaylist(const [], selectedGroupId: 'lobby');
      expect(r.ok, isFalse);
      expect(r.draft, isNull);
      expect(r.message, contains('无成员'));
    });

    test('all online but none report active_playlist -> no load, missing counted', () {
      final r = loadGroupPlaylist(
        [_dev('and-1'), _dev('and-2')],
        selectedGroupId: 'lobby',
      );
      expect(r.ok, isFalse);
      expect(r.missingCount, 2);
      expect(r.onlineCount, 2);
      expect(r.message, contains('均未上报'));
    });

    test('offline members are ignored; an offline holder does not become rep', () {
      final r = loadGroupPlaylist(
        [
          _dev('and-off',
              online: false, active: _pl('pl-x', 'lobby', [_a, _b])),
          _dev('and-on'),
        ],
        selectedGroupId: 'lobby',
      );
      // Only one online member and it has no active_playlist.
      expect(r.ok, isFalse);
      expect(r.onlineCount, 1);
      expect(r.missingCount, 1);
    });

    test('single member with active_playlist loads it as the draft', () {
      final r = loadGroupPlaylist(
        [_dev('and-1', active: _pl('pl-1', 'lobby', [_a, _b]))],
        selectedGroupId: 'lobby',
      );
      expect(r.ok, isTrue);
      expect(r.representative!.deviceId, 'and-1');
      expect(r.draft!.playlistId, 'pl-1');
      expect(r.matchCount, 1);
      expect(r.divergeCount, 0);
      expect(r.missingCount, 0);
    });

    test('multiple consistent members -> matchCount == N, no divergence', () {
      final pl = _pl('pl-1', 'lobby', [_a, _b]);
      final r = loadGroupPlaylist(
        [
          _dev('and-1', active: pl),
          _dev('and-2', active: _pl('pl-1', 'lobby', [_a, _b])),
          _dev('and-3', active: _pl('pl-1', 'lobby', [_a, _b])),
        ],
        selectedGroupId: 'lobby',
      );
      expect(r.ok, isTrue);
      expect(r.matchCount, 3);
      expect(r.divergeCount, 0);
      expect(r.message, contains('3/3'));
    });

    test('divergent members still load the representative and count divergence', () {
      final r = loadGroupPlaylist(
        [
          _dev('and-1', active: _pl('pl-1', 'lobby', [_a, _b])),
          _dev('and-2', active: _pl('pl-2', 'lobby', [_c])), // different
          _dev('and-3'), // missing
        ],
        selectedGroupId: 'lobby',
      );
      expect(r.ok, isTrue);
      expect(r.divergeCount, greaterThan(0));
      expect(r.missingCount, 1);
      expect(r.message, contains('不同'));
      expect(r.message, contains('未上报'));
    });

    test('prefers a playing member over an idle one when both hold playlists', () {
      final r = loadGroupPlaylist(
        [
          _dev('and-zzz', state: 'idle', active: _pl('pl-1', 'lobby', [_a])),
          _dev('and-aaa',
              state: 'playing', active: _pl('pl-1', 'lobby', [_a])),
        ],
        selectedGroupId: 'lobby',
      );
      // Even though and-aaa sorts first lexicographically, the tie-break only
      // applies within the same play-state rank; here playing wins outright.
      expect(r.representative!.deviceId, 'and-aaa');
    });

    test('prefers a member whose active_playlist group matches the selection', () {
      final r = loadGroupPlaylist(
        [
          _dev('and-1', state: 'playing', active: _pl('pl-x', 'other', [_a])),
          _dev('and-2', state: 'idle', active: _pl('pl-y', 'lobby', [_b])),
        ],
        selectedGroupId: 'lobby',
      );
      // Policy (a) beats play-state preference: the group-matching idle member
      // is the representative even though the other is playing.
      expect(r.representative!.deviceId, 'and-2');
      expect(r.draft!.groupId, 'lobby');
    });

    test('lexicographic tie-break when play-state and group are equal', () {
      final r = loadGroupPlaylist(
        [
          _dev('and-bbb', state: 'idle', active: _pl('pl-1', 'lobby', [_a])),
          _dev('and-aaa', state: 'idle', active: _pl('pl-1', 'lobby', [_a])),
        ],
        selectedGroupId: 'lobby',
      );
      expect(r.representative!.deviceId, 'and-aaa');
    });
  });

  group('playlistFingerprint', () {
    test('same id but reordered items produce different fingerprints', () {
      final f1 = playlistFingerprint(_pl('pl-1', 'g', [_a, _b]));
      final f2 = playlistFingerprint(_pl('pl-1', 'g', [_b, _a]));
      expect(f1, isNot(equals(f2)));
    });

    test('identical id and ordered items produce equal fingerprints', () {
      final f1 = playlistFingerprint(_pl('pl-1', 'g', [_a, _b]));
      final f2 = playlistFingerprint(_pl('pl-1', 'g', [_a, _b]));
      expect(f1, equals(f2));
    });
  });
}
