import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/loop_mode.dart';
import 'package:remote_flutter/protocol/messages.dart';

void main() {
  group('LoopModeCodec.resolve — the single legacy fold point', () {
    test('canonical loop_mode wins', () {
      expect(LoopModeCodec.resolve({'loop_mode': 'one'}), LoopMode.one);
      expect(LoopModeCodec.resolve({'loop_mode': 'all'}), LoopMode.all);
      expect(LoopModeCodec.resolve({'loop_mode': 'none'}), LoopMode.none);
    });

    test('canonical beats legacy when they disagree', () {
      expect(
        LoopModeCodec.resolve({'loop_mode': 'none', 'loop': true}),
        LoopMode.none,
      );
    });

    test('legacy fold: loop true=>all, false/absent=>none', () {
      expect(LoopModeCodec.resolve({'loop': true}), LoopMode.all);
      expect(LoopModeCodec.resolve({'loop': false}), LoopMode.none);
      expect(LoopModeCodec.resolve({}), LoopMode.none);
      expect(LoopModeCodec.resolve(null), LoopMode.none);
    });

    test('unknown string falls back to legacy fold, never throws', () {
      expect(LoopModeCodec.resolve({'loop_mode': 'bogus', 'loop': true}),
          LoopMode.all);
      expect(LoopModeCodec.resolve({'loop_mode': 'spin'}), LoopMode.none);
    });
  });

  group('legacy projection', () {
    test('legacyLoopBool: none=>false, all/one=>true', () {
      expect(LoopMode.none.legacyLoopBool, isFalse);
      expect(LoopMode.all.legacyLoopBool, isTrue);
      expect(LoopMode.one.legacyLoopBool, isTrue);
    });
  });

  group('ActivePlaylist.fromMap folds loop_mode', () {
    test('reads loop_mode', () {
      final pl = ActivePlaylist.fromMap({
        'playlist_id': 'p', 'group_id': 'g', 'sync': true,
        'loop_mode': 'one', 'items': const [],
      });
      expect(pl!.loopMode, LoopMode.one);
      expect(pl.loop, isTrue); // legacy accessor
    });

    test('legacy loop:true folds to all', () {
      final pl = ActivePlaylist.fromMap({
        'playlist_id': 'p', 'group_id': 'g', 'sync': true,
        'loop': true, 'items': const [],
      });
      expect(pl!.loopMode, LoopMode.all);
    });
  });

  group('Commands.playlist emits both fields', () {
    test('loop_mode canonical + loop legacy compat', () {
      final p = Commands.playlist(
        playlistId: 'p', groupId: 'g', sync: false,
        loopMode: LoopMode.one, items: const [],
      );
      expect(p['loop_mode'], 'one');
      expect(p['loop'], isTrue); // one degrades to wrap on old players
      final n = Commands.playlist(
        playlistId: 'p', groupId: 'g', sync: false,
        loopMode: LoopMode.none, items: const [],
      );
      expect(n['loop_mode'], 'none');
      expect(n['loop'], isFalse);
    });
  });
}
