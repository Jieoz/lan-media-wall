import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/ui/push_workflow.dart';

void main() {
  group('pushConfirmSummary — documents target/count/mode/cache/playback (§C)', () {
    test('replace + cache-only names target, count, replace, cache, no autoplay', () {
      final s = pushConfirmSummary(
        targetName: '大厅左屏',
        itemCount: 4,
        mode: PushMode.replace,
        playback: PushPlayback.cacheOnly,
      );
      expect(s, contains('大厅左屏'));
      expect(s, contains('4'));
      expect(s, contains('替换'));
      expect(s, contains('缓存'));
      // cache-only must NOT promise playback starts.
      expect(s.contains('缓存完成后自动播放'), isFalse);
    });

    test('replace + play-after-cache states playback starts after cache', () {
      final s = pushConfirmSummary(
        targetName: '大厅左屏',
        itemCount: 2,
        mode: PushMode.replace,
        playback: PushPlayback.playAfterCache,
      );
      expect(s, contains('缓存完成后'));
      expect(s, contains('播放'));
    });

    test('append mode is described as 追加 (merge), not 替换', () {
      final s = pushConfirmSummary(
        targetName: 'box-1',
        itemCount: 1,
        mode: PushMode.append,
        playback: PushPlayback.cacheOnly,
      );
      expect(s, contains('追加'));
      expect(s.contains('整列替换'), isFalse);
    });

    test('always states cached files are retained (non-destructive)', () {
      final s = pushConfirmSummary(
        targetName: 'box-1',
        itemCount: 3,
        mode: PushMode.replace,
        playback: PushPlayback.cacheOnly,
      );
      expect(s, contains('不会删除'));
    });
  });

  group('final push choices (§C)', () {
    test('the two explicit choices are exactly the required labels', () {
      expect(PushPlayback.cacheOnly.actionLabel, '仅下发并缓存');
      expect(PushPlayback.playAfterCache.actionLabel, '缓存完成后播放');
    });
  });

  group('sentAwaitingAck — truthful sent-not-done wording (§D)', () {
    test('wraps an action into a waiting-for-ACK phrase', () {
      final s = sentAwaitingAck('停止并清空');
      expect(s, contains('已发送'));
      expect(s, contains('等待设备确认'));
      // Must not claim the effect already happened.
      expect(s.contains('已停止'), isFalse);
      expect(s.contains('已清空'), isFalse);
    });
  });
}
