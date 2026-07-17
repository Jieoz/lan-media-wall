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
        loopMode: LoopMode.all,
        items: [_c, _a],
      );

      draft.load(active);

      expect(draft.playlistId, 'pl-live');
      expect(draft.groupId, 'lobby');
      expect(draft.sync, isFalse);
      expect(draft.loopMode, LoopMode.all);
      expect(draft.items.map((item) => item.itemId), ['c', 'a']);
    });

    test('loading a device status imports its active playlist and current index', () {
      final draft = PlaylistDraft()..add(_b);
      const status = DeviceStatus(
        deviceId: 'box-1',
        online: true,
        currentIndex: 1,
        activePlaylist: ActivePlaylist(
          playlistId: 'pl-live',
          groupId: 'lobby',
          sync: false,
          loopMode: LoopMode.one,
          items: [_c, _a],
        ),
      );

      expect(draft.loadFromDevice(status), isTrue);

      expect(draft.playlistId, 'pl-live');
      expect(draft.groupId, 'lobby');
      expect(draft.currentIndex, 1);
      expect(draft.loopMode, LoopMode.one);
      expect(draft.items.map((item) => item.itemId), ['c', 'a']);
    });

    test('loading a legacy status without active playlist is a no-op', () {
      final draft = PlaylistDraft()..add(_a);
      const status = DeviceStatus(
        deviceId: 'legacy-box',
        online: true,
        playlistId: 'pl-legacy',
        currentIndex: 0,
      );

      expect(draft.loadFromDevice(status), isFalse);
      expect(draft.playlistId, isNull);
      expect(draft.currentIndex, isNull);
      expect(draft.items, [_a]);
    });

    test('moving the current item follows it and moving another item shifts its index', () {
      final draft = PlaylistDraft()
        ..load(const ActivePlaylist(
          playlistId: 'pl-live',
          groupId: 'lobby',
          sync: true,
          loopMode: LoopMode.all,
          items: [_a, _b, _c],
        ), currentIndex: 1);

      draft.move(1, 2);
      expect(draft.items.map((item) => item.itemId), ['a', 'c', 'b']);
      expect(draft.currentIndex, 2);

      draft.move(0, 2);
      expect(draft.items.map((item) => item.itemId), ['c', 'b', 'a']);
      expect(draft.currentIndex, 1);
    });

    test('setDurationMs edits image dwell in place, ignoring bad input', () {
      final draft = PlaylistDraft()..addAll(const [_a, _c]);
      var notifications = 0;
      draft.addListener(() => notifications++);

      draft.setDurationMs(1, 15000);
      expect(draft.items[1].durationMs, 15000);
      expect(draft.items[1].itemId, 'c'); // 其余字段保序不变
      expect(notifications, 1);

      draft.setDurationMs(1, 0); // 非正值无操作
      draft.setDurationMs(5, 10000); // 越界无操作
      expect(draft.items[1].durationMs, 15000);
      expect(notifications, 1);
    });

    test('public item view is immutable', () {
      final draft = PlaylistDraft()..addAll(const [_a]);

      expect(() => draft.items.add(_b), throwsUnsupportedError);
      expect(draft.items, [_a]);
    });
  });
}
