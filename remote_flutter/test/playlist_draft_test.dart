import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/messages.dart';
import 'package:remote_flutter/state/playlist_draft.dart';

const _a = MediaItem(
  itemId: 'a',
  type: 'video',
  name: 'A.mp4',
  url: 'http://controller/a.mp4',
);
const _b = MediaItem(
  itemId: 'b',
  type: 'video',
  name: 'B.mp4',
  url: 'http://controller/b.mp4',
);
const _c = MediaItem(
  itemId: 'c',
  type: 'image',
  name: 'C.png',
  url: 'http://controller/c.png',
  durationMs: 8000,
);

void main() {
  group('PlaylistDraft', () {
    test('keeps multi-file selection order and ignores duplicate item ids', () {
      final draft = PlaylistDraft();

      draft.addAll(const [_b, _a, _b, _c]);

      expect(draft.items.map((item) => item.itemId), ['b', 'a', 'c']);
    });

    test('move, remove, and clear notify while preserving an ordered list', () {
      final draft = PlaylistDraft()..addAll(const [_a, _b, _c]);
      var notifications = 0;
      draft.addListener(() => notifications++);

      draft.move(2, 0);
      expect(draft.items.map((item) => item.itemId), ['c', 'a', 'b']);

      draft.removeAt(1);
      expect(draft.items.map((item) => item.itemId), ['c', 'b']);

      draft.clear();
      expect(draft.items, isEmpty);
      expect(notifications, 3);
    });

    test('loading an active playlist replaces the draft and its playback options', () {
      final draft = PlaylistDraft();
      const active = ActivePlaylist(
        playlistId: 'pl-live',
        groupId: 'lobby',
        sync: false,
        loop: true,
        items: [_c, _a],
      );

      draft.load(active);

      expect(draft.playlistId, 'pl-live');
      expect(draft.groupId, 'lobby');
      expect(draft.sync, isFalse);
      expect(draft.loop, isTrue);
      expect(draft.items.map((item) => item.itemId), ['c', 'a']);
    });

    test('public item view is immutable', () {
      final draft = PlaylistDraft()..addAll(const [_a]);

      expect(() => draft.items.add(_b), throwsUnsupportedError);
      expect(draft.items, [_a]);
    });
  });
}
