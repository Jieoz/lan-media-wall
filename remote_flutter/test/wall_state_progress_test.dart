import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/messages.dart';
import 'package:remote_flutter/state/media_progress.dart';
import 'package:remote_flutter/state/wall_state.dart';

/// §6.4/E0004 WallState-level regressions for the media-push progress barrier.
///
/// These drive the REAL [WallState] ingestion path ([WallState.debugIngestWall]
/// → private `_onWall`) rather than re-simulating it against the bare machine,
/// so they prove the edge-triggered pushId adoption condition that lives in
/// `_onWall` itself — the exact place E0004 flagged as defective.
DeviceStatus _status(
  String id, {
  String group = 'lobby',
  bool online = true,
  String? playlistId,
  String? pushId,
  Map<String, String> cache = const {},
}) =>
    DeviceStatus(
      deviceId: id,
      groupId: group,
      state: 'playing',
      online: online,
      playlistId: playlistId,
      pushId: pushId,
      cache: cache,
    );

void main() {
  group('WallState job lifecycle isolation', () {
    test('startup ambient cache inventory is not displayed as a push job', () {
      final ws = WallState();
      addTearDown(ws.dispose);
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', cache: {'old': 'ready'}),
      ]));
      expect(ws.pushGenerationOf('d1'), 0);
      expect(ws.deviceProgress('d1'), isNull);
      expect(ws.batchProgress(['d1']).totalDevices, 0);
    });

    test('failed delivery does not create a ghost push generation', () {
      final ws = WallState();
      addTearDown(ws.dispose);
      ws.debugIngestWall(WallSnapshot(devices: [_status('d1')]));

      expect(
        () => ws.sendPlaylist(
          playlistId: 'PL',
          groupId: 'lobby',
          sync: true,
          loopMode: LoopMode.all,
          items: const [
            MediaItem(
              itemId: 'a',
              name: 'a.mp4',
              url: 'http://example/a.mp4',
              type: 'video',
            ),
          ],
          mode: 'replace',
          deviceId: 'd1',
        ),
        throwsStateError,
      );
      expect(ws.pushGenerationOf('d1'), 0);
      expect(ws.deviceProgress('d1'), isNull);
    });

    test('clear prevents later historical cache from resurrecting progress', () {
      final ws = WallState();
      addTearDown(ws.dispose);
      ws.debugBeginPushJob(['d1'], ['a'], pushId: 'p1');
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', pushId: 'p1', cache: {'a': 'ready'}),
      ]));
      expect(ws.deviceProgress('d1')!.isComplete, isTrue);

      ws.debugClearPushJob(['d1']);
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', pushId: 'p1', cache: {'a': 'ready'}),
      ]));

      expect(ws.pushGenerationOf('d1'), 0);
      expect(ws.deviceProgress('d1'), isNull);
    });
  });

  group('WallState push-job adoption (E0004 defect 1)', () {
    // Replacing a playlist with the SAME playlist_id must NOT release the
    // stale-ready barrier: playlist_id equality is already true before the new
    // command, so it is not an edge. Only the fresh per-replace push_id echoed
    // by the player is proof of adoption. Until then, an inherited `ready`
    // snapshot must not report 100.
    test('same playlist_id + inherited ready does not jump to 100 until the '
        'new push_id is echoed', () {
      final ws = WallState();
      addTearDown(ws.dispose);

      // Prior job (generation 1) completed: item "a" is ready under old push.
      ws.debugBeginPushJob(['d1'], ['a'], pushId: 'push-old');
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', pushId: 'push-old', cache: {'a': 'ready'}),
      ]));
      expect(ws.deviceProgress('d1')!.isComplete, isTrue,
          reason: 'old job genuinely finished');

      // New replace of the SAME playlist_id "PL" — fresh push_id, item "a" again.
      ws.debugBeginPushJob(['d1'], ['a'], pushId: 'push-new');

      // A pre-command / lingering snapshot still carries the OLD push_id and the
      // stale ready. playlist_id is unchanged ("PL"), so a playlist_id-based
      // check would wrongly confirm. push_id is still the old one → no adoption.
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', pushId: 'push-old', cache: {'a': 'ready'}),
      ]));
      final held = ws.deviceProgress('d1')!;
      expect(held.isComplete, isFalse,
          reason: 'inherited ready must be held until the new push is adopted');
      expect(held.percent, 0, reason: 'progress reset, not 100');

      // The device echoes the NEW push_id → genuine adoption. Now its ready is
      // trustworthy and the job completes.
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', pushId: 'push-new', cache: {'a': 'ready'}),
      ]));
      final done = ws.deviceProgress('d1')!;
      expect(done.isComplete, isTrue);
      expect(done.percent, 100);
    });

    test('legacy player (no push_id) — real download evidence releases the '
        'barrier via the downloading:<100 fallback', () {
      // Only a genuine legacy player that reports NO push_id at all may fall
      // back to the downloading:<100 adoption heuristic. A player that reports
      // a DIFFERENT push_id is handled by the foreign-frame test below.
      final ws = WallState();
      addTearDown(ws.dispose);
      ws.debugBeginPushJob(['d1'], ['a'], pushId: 'p1');
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', cache: {'a': 'ready'}),
      ]));
      // guarded: inherited stale ready ignored even from a legacy player.
      expect(ws.deviceProgress('d1')!.percent, 0);
      // the player is demonstrably re-fetching → guard releases, progress moves.
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', cache: {'a': 'downloading:30%'}),
      ]));
      expect(ws.deviceProgress('d1')!.percent, 30);
      expect(ws.deviceProgress('d1')!.isComplete, isFalse);
    });

    test('E0004 defect 1: a foreign push_id frame (downloading/error/ready) '
        'never crosses the barrier before the new push is adopted', () {
      // Old job push-old still in flight; controller issues a new replace
      // (push-new) for the same item. Late frames still stamped push-old must
      // NOT be admitted into the new job under any phase — not downloading
      // (the old fresh-evidence hole), not a later error, not a later ready.
      final ws = WallState();
      addTearDown(ws.dispose);
      ws.debugBeginPushJob(['d1'], ['a'], pushId: 'push-new');

      // 1) foreign downloading:30% — must be rejected, stays guarded at 0.
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', pushId: 'push-old', cache: {'a': 'downloading:30%'}),
      ]));
      expect(ws.deviceProgress('d1')!.percent, 0,
          reason: 'old download frame must not release the new job barrier');
      expect(ws.deviceProgress('d1')!.isComplete, isFalse);

      // 2) foreign error — must not fail the new job.
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', pushId: 'push-old', cache: {'a': 'error:disk full'}),
      ]));
      expect(ws.deviceProgress('d1')!.hasError, isFalse,
          reason: 'old error must not poison the new job');

      // 3) foreign ready — must not complete the new job.
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', pushId: 'push-old', cache: {'a': 'ready'}),
      ]));
      expect(ws.deviceProgress('d1')!.isComplete, isFalse,
          reason: 'old ready must not complete the new job');
      expect(ws.deviceProgress('d1')!.percent, 0);

      // Only the new push_id echo adopts the job; then its real ready completes.
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', pushId: 'push-new', cache: {'a': 'ready'}),
      ]));
      final done = ws.deviceProgress('d1')!;
      expect(done.isComplete, isTrue);
      expect(done.percent, 100);
    });
  });

  group('WallState interrupt is a strict failed terminal (E0002 risk 3)', () {
    test('an offline snapshot carrying a stale ready does NOT revive the '
        'interrupted job into success', () {
      // downloading:80% → disconnect (offline snapshot still carries the
      // pre-disconnect cache, and in the SAME frame that cache shows ready).
      // The job must stay interrupted/failed, never flip to 100/complete.
      final ws = WallState();
      addTearDown(ws.dispose);
      ws.debugBeginPushJob(['d1'], ['a'], pushId: 'p1');
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', pushId: 'p1', cache: {'a': 'downloading:80%'}),
      ]));
      // Offline snapshot whose lingering cache now shows the item as ready.
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', online: false, playlistId: 'PL', pushId: 'p1', cache: {'a': 'ready'}),
      ]));
      final job = ws.deviceProgress('d1')!;
      expect(job.hasError, isTrue, reason: 'still failed/interrupted');
      expect(job.isComplete, isFalse, reason: 'a dead job must not report success');
      expect(job.percent, 80, reason: 'frozen at last live percent');
    });

    test('a late ready arriving AFTER interruption (reconnect frame, same '
        'generation) does not resurrect the failed job', () {
      final ws = WallState();
      addTearDown(ws.dispose);
      ws.debugBeginPushJob(['d1'], ['a'], pushId: 'p1');
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', pushId: 'p1', cache: {'a': 'downloading:80%'}),
      ]));
      // disconnect → interrupted
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', online: false, playlistId: 'PL', pushId: 'p1', cache: {'a': 'downloading:80%'}),
      ]));
      expect(ws.deviceProgress('d1')!.hasError, isTrue);
      // reconnect, still same push_id/generation, cache now ready.
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', pushId: 'p1', cache: {'a': 'ready'}),
      ]));
      final job = ws.deviceProgress('d1')!;
      expect(job.isComplete, isFalse,
          reason: 'recovery must arrive as a new job/generation, not ambient ready');
      expect(job.hasError, isTrue);
    });
  });

  group('WallState expected-item isolation (E0004 defect 2)', () {
    // beginJob seeds [a]; an incoming status cache also carrying unrelated old
    // inventory {b_old} must not pollute total/mean/completion for this job.
    test('unrelated cache inventory is ignored; aggregation uses only expected '
        'items', () {
      final ws = WallState();
      addTearDown(ws.dispose);
      ws.debugBeginPushJob(['d1'], ['a'], pushId: 'p1');
      ws.debugIngestWall(WallSnapshot(devices: [
        // player reports its whole cache: the job item plus an old ready item.
        _status('d1', playlistId: 'PL', pushId: 'p1', cache: {
          'a': 'downloading:40%',
          'b_old': 'ready',
        }),
      ]));
      final job = ws.deviceProgress('d1')!;
      expect(job.totalItems, 1, reason: 'only the expected item "a" counts');
      expect(job.percent, 40, reason: 'mean over expected items only');
      expect(job.isComplete, isFalse);
      expect(ws.progress.progressFor('d1', 'b_old'), isNull,
          reason: 'unrelated inventory never entered the job');
    });
  });

  group('WallState interrupt on disconnect (E0002 risk 3)', () {
    test('a device going offline mid-job freezes progress as failed, not 100',
        () {
      final ws = WallState();
      addTearDown(ws.dispose);
      ws.debugBeginPushJob(['d1'], ['a'], pushId: 'p1');
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', playlistId: 'PL', pushId: 'p1', cache: {'a': 'downloading:80%'}),
      ]));
      ws.debugIngestWall(WallSnapshot(devices: [
        _status('d1', online: false, playlistId: 'PL', pushId: 'p1', cache: {'a': 'downloading:80%'}),
      ]));
      final job = ws.deviceProgress('d1')!;
      expect(job.hasError, isTrue);
      expect(job.isComplete, isFalse);
      expect(job.percent, 80, reason: 'frozen at last percent, not advanced');
    });
  });
}
