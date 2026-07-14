import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/state/media_progress.dart';

/// §6.4 shared progress state machine (E0001) contract tests. These are the
/// RED-first coverage for the invariants: monotonic 0..100, reset-per-job,
/// device+item+generation keying, no NaN/backwards/jumps, never 100 before the
/// `ready` handshake, stale/out-of-order/concurrent-fanout handling.
void main() {
  group('parseCacheValue', () {
    test('parses the wire forms', () {
      expect(parseCacheValue('ready').phase, ProgressPhase.ready);
      expect(parseCacheValue('ready').percent, 100);
      expect(parseCacheValue('downloading:45%').phase, ProgressPhase.downloading);
      expect(parseCacheValue('downloading:45%').percent, 45);
      expect(parseCacheValue('verifying').phase, ProgressPhase.verifying);
      // Android emits `retrying` on a transient stall — in-flight, not an error.
      expect(parseCacheValue('retrying').phase, ProgressPhase.downloading);
      expect(parseCacheValue('error:sha256-mismatch').phase, ProgressPhase.error);
      expect(parseCacheValue('error:sha256-mismatch').detail, 'sha256-mismatch');
      expect(parseCacheValue('pending').phase, ProgressPhase.pending);
    });

    test('unknown/malformed degrades to pending, never throws', () {
      expect(parseCacheValue('garbage').phase, ProgressPhase.pending);
      expect(parseCacheValue('').percent, 0);
      expect(parseCacheValue('downloading:').percent, 0);
    });

    test('clamps out-of-range percents', () {
      expect(parseCacheValue('downloading:250%').percent, 100);
      expect(parseCacheValue('downloading:-5%').percent, 0);
    });
  });

  group('single-item multi-chunk', () {
    test('percent rises monotonically and caps <100 until ready', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'downloading:10%'}, 1);
      expect(m.progressFor('d1', 'a')!.percent, 10);
      m.ingestDeviceCache('d1', {'a': 'downloading:60%'}, 1);
      expect(m.progressFor('d1', 'a')!.percent, 60);
      // producer sent downloading:100% (a real defect the machine must mask)
      m.ingestDeviceCache('d1', {'a': 'downloading:100%'}, 1);
      expect(m.progressFor('d1', 'a')!.percent, 99,
          reason: 'never 100 before ready handshake');
      m.ingestDeviceCache('d1', {'a': 'verifying'}, 1);
      expect(m.progressFor('d1', 'a')!.percent, 99);
      expect(m.progressFor('d1', 'a')!.phase, ProgressPhase.verifying);
      m.ingestDeviceCache('d1', {'a': 'ready'}, 1);
      expect(m.progressFor('d1', 'a')!.percent, 100);
      expect(m.progressFor('d1', 'a')!.isReady, isTrue);
    });
  });

  group('cached/instant completion', () {
    test('a fresh ready with no prior downloading is exactly 100/ready', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'ready'}, 1);
      final r = m.progressFor('d1', 'a')!;
      expect(r.percent, 100);
      expect(r.isReady, isTrue);
    });
  });

  group('out-of-order / backwards', () {
    test('a lower percent in the same generation does not regress', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'downloading:80%'}, 1);
      m.ingestDeviceCache('d1', {'a': 'downloading:30%'}, 1); // reordered/resumed
      expect(m.progressFor('d1', 'a')!.percent, 80);
    });

    test('retrying holds the last percent, never regresses or errors', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'downloading:70%'}, 1);
      m.ingestDeviceCache('d1', {'a': 'retrying'}, 1);
      final r = m.progressFor('d1', 'a')!;
      expect(r.phase, ProgressPhase.downloading);
      expect(r.percent, 70, reason: 'a stall must not drop the bar back to 0');
      expect(r.isError, isFalse);
    });

    test('ready is sticky: a later downloading frame cannot un-ready', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'ready'}, 1);
      m.ingestDeviceCache('d1', {'a': 'downloading:50%'}, 1);
      expect(m.progressFor('d1', 'a')!.isReady, isTrue);
      expect(m.progressFor('d1', 'a')!.percent, 100);
    });
  });

  group('reset per job (generation)', () {
    test('a new generation resets the item to the fresh value', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'ready'}, 1);
      expect(m.progressFor('d1', 'a')!.percent, 100);
      // new push job for the same item → progress restarts
      m.ingestDeviceCache('d1', {'a': 'downloading:5%'}, 2);
      final r = m.progressFor('d1', 'a')!;
      expect(r.generation, 2);
      expect(r.percent, 5);
      expect(r.isReady, isFalse);
    });
  });

  group('stale generation', () {
    test('a frame older than the record is dropped', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'downloading:40%'}, 2);
      // a lingering frame from the superseded job 1 arrives late
      final changed = m.ingestDeviceCache('d1', {'a': 'downloading:90%'}, 1);
      expect(changed, isFalse);
      expect(m.progressFor('d1', 'a')!.generation, 2);
      expect(m.progressFor('d1', 'a')!.percent, 40);
    });
  });

  group('unknown content length', () {
    test('downloading:0% (unknown total) is a valid non-negative floor', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'downloading:0%'}, 1);
      expect(m.progressFor('d1', 'a')!.percent, 0);
      expect(m.progressFor('d1', 'a')!.phase, ProgressPhase.downloading);
      m.ingestDeviceCache('d1', {'a': 'ready'}, 1);
      expect(m.progressFor('d1', 'a')!.percent, 100);
    });
  });

  group('failure / error', () {
    test('error phase is recorded with reason and percent floors to 0-safe', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'downloading:50%'}, 1);
      m.ingestDeviceCache('d1', {'a': 'error:sha256-mismatch'}, 1);
      final r = m.progressFor('d1', 'a')!;
      expect(r.phase, ProgressPhase.error);
      expect(r.detail, 'sha256-mismatch');
      expect(r.percent, lessThan(100));
    });
  });

  group('concurrent fan-out + batch aggregation', () {
    test('per-device job mean and batch mean, complete only when all ready', () {
      final m = MediaProgressMachine();
      // device d1: 2 items, one ready one mid-download
      m.ingestDeviceCache('d1', {'a': 'ready', 'b': 'downloading:50%'}, 7);
      // device d2: 2 items both downloading
      m.ingestDeviceCache('d2', {'a': 'downloading:20%', 'b': 'downloading:40%'}, 7);

      final j1 = m.deviceJob('d1', 7)!;
      expect(j1.percent, (100 + 50) ~/ 2); // 75
      expect(j1.readyItems, 1);
      expect(j1.isComplete, isFalse);

      final batch = m.batchProgress(['d1', 'd2'], (_) => 7);
      expect(batch.totalDevices, 2);
      expect(batch.completeDevices, 0);
      // mean(75, 30) = 52.5 → 53
      expect(batch.percent, 53);

      // finish everything
      m.ingestDeviceCache('d1', {'a': 'ready', 'b': 'ready'}, 7);
      m.ingestDeviceCache('d2', {'a': 'ready', 'b': 'ready'}, 7);
      final batch2 = m.batchProgress(['d1', 'd2'], (_) => 7);
      expect(batch2.percent, 100);
      expect(batch2.completeDevices, 2);
    });

    test('mixed generations across devices do not cross-contaminate', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'downloading:90%'}, 5);
      m.ingestDeviceCache('d2', {'a': 'downloading:10%'}, 9);
      // batch asks each device for its own generation
      final batch = m.batchProgress(['d1', 'd2'], (id) => id == 'd1' ? 5 : 9);
      expect(batch.percent, (90 + 10) ~/ 2); // 50
      // querying d1 with d2's generation yields nothing for d1
      expect(m.deviceJob('d1', 9), isNull);
    });
  });

  group('disconnect / forget', () {
    test('forgetDevice drops its records and bumps revision', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'downloading:50%'}, 1);
      final rev = m.revision;
      m.forgetDevice('d1');
      expect(m.progressFor('d1', 'a'), isNull);
      expect(m.revision, greaterThan(rev));
    });
  });

  // E0002 risk 1: a fresh job must NOT let a pre-command wall snapshot that
  // still carries the OLD `ready` instantly report 100 before the new job runs.
  group('new-job stale-ready barrier (E0002 risk 1)', () {
    test('inherited ready under a new generation stays reset until fresh evidence', () {
      final m = MediaProgressMachine();
      // job 1 completed: item a is ready (100).
      m.ingestDeviceCache('d1', {'a': 'ready'}, 1);
      expect(m.progressFor('d1', 'a')!.percent, 100);

      // a fresh push job starts for the SAME item (generation bumps to 2) and
      // seeds the guard because the prior record was ready.
      m.beginJob('d1', 2, ['a']);
      expect(m.progressFor('d1', 'a')!.percent, 0);
      expect(m.progressFor('d1', 'a')!.phase, ProgressPhase.pending);

      // the very next wall snapshot is STALE: the player has not received the
      // new job yet, so it still reports the OLD `ready`. Ingest under gen 2.
      m.ingestDeviceCache('d1', {'a': 'ready'}, 2);
      final held = m.progressFor('d1', 'a')!;
      expect(held.percent, 0, reason: 'stale ready must not report 100');
      expect(held.isReady, isFalse);
      expect(m.deviceJob('d1', 2)!.isComplete, isFalse);

      // fresh-job evidence arrives: the player is now genuinely downloading.
      m.ingestDeviceCache('d1', {'a': 'downloading:30%'}, 2);
      expect(m.progressFor('d1', 'a')!.percent, 30);
      m.ingestDeviceCache('d1', {'a': 'ready'}, 2);
      expect(m.progressFor('d1', 'a')!.percent, 100);
      expect(m.progressFor('d1', 'a')!.isReady, isTrue);
    });

    test('confirmJobStarted releases the guard for a cached-instant re-push', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'ready'}, 1);
      m.beginJob('d1', 2, ['a']);
      // stale ready held — the cached player re-affirms ready with NO
      // intervening downloading frame, so only an explicit adoption ack frees it.
      m.ingestDeviceCache('d1', {'a': 'ready'}, 2);
      expect(m.progressFor('d1', 'a')!.percent, 0);
      // WallState calls this only after the device echoes the exact push_id.
      expect(m.confirmJobStarted('d1', 2), isTrue);
      m.ingestDeviceCache('d1', {'a': 'ready'}, 2);
      expect(m.progressFor('d1', 'a')!.percent, 100);
      expect(m.progressFor('d1', 'a')!.isReady, isTrue);
    });

    test('a brand-new item is guarded until exact job adoption', () {
      final m = MediaProgressMachine();
      // Controller memory may be fresh while the player's ambient cache is old.
      m.beginJob('d1', 1, ['a']);
      m.ingestDeviceCache('d1', {'a': 'ready'}, 1);
      expect(m.progressFor('d1', 'a')!.percent, 0);
      expect(m.confirmJobStarted('d1', 1), isTrue);
      m.ingestDeviceCache('d1', {'a': 'ready'}, 1);
      expect(m.progressFor('d1', 'a')!.percent, 100);
    });

    test('beginJob prunes items no longer in the active job (bounded history)', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'ready', 'b': 'ready'}, 1);
      m.beginJob('d1', 2, ['a']); // b dropped from the playlist
      expect(m.progressFor('d1', 'b'), isNull);
      expect(m.progressFor('d1', 'a'), isNotNull);
    });

    test('unrelated cache inventory cannot join an explicit push job', () {
      final m = MediaProgressMachine();
      m.beginJob('d1', 1, ['wanted']);
      m.ingestDeviceCache('d1', {
        'wanted': 'downloading:40%',
        'old-ready': 'ready',
        'old-error': 'error:stale',
      }, 1);
      expect(m.progressFor('d1', 'old-ready'), isNull);
      expect(m.progressFor('d1', 'old-error'), isNull);
      final job = m.deviceJob('d1', 1)!;
      expect(job.totalItems, 1);
      expect(job.percent, 40);
      expect(job.hasError, isFalse);
    });
  });

  // E0002 risk 3: a job that fails / disconnects mid-flight must not present a
  // high percent as ongoing success.
  group('interrupt / cancel (E0002 risk 3)', () {
    test('interruptDevice freezes in-flight items as failed, not live progress', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'downloading:90%', 'b': 'ready'}, 1);
      final changed = m.interruptDevice('d1', 1, reason: 'disconnected');
      expect(changed, isTrue);
      final a = m.progressFor('d1', 'a')!;
      expect(a.phase, ProgressPhase.interrupted);
      expect(a.percent, 90, reason: 'frozen at last percent');
      expect(a.isError, isTrue);
      // ready item is left truthfully done.
      expect(m.progressFor('d1', 'b')!.isReady, isTrue);
      final job = m.deviceJob('d1', 1)!;
      expect(job.hasError, isTrue);
      expect(job.isComplete, isFalse,
          reason: 'a job with an interrupted item is never complete');
    });

    test('an ambient frame cannot resurrect an interrupted item into progress', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'downloading:90%'}, 1);
      m.interruptDevice('d1', 1);
      m.ingestDeviceCache('d1', {'a': 'downloading:95%'}, 1);
      expect(m.progressFor('d1', 'a')!.phase, ProgressPhase.interrupted);
      expect(m.progressFor('d1', 'a')!.percent, 90);
    });

    test('resetDevice drops all records for a cancelled (empty-replace) job', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'downloading:50%'}, 1);
      m.resetDevice('d1');
      expect(m.progressFor('d1', 'a'), isNull);
    });
  });

  group('update-storm coalescing (revision)', () {
    test('a no-op ingest does not bump revision', () {
      final m = MediaProgressMachine();
      m.ingestDeviceCache('d1', {'a': 'downloading:50%'}, 1);
      final rev = m.revision;
      // identical frame again → no state change → no revision bump → no notify
      final changed = m.ingestDeviceCache('d1', {'a': 'downloading:50%'}, 1);
      expect(changed, isFalse);
      expect(m.revision, rev);
    });
  });
}
