import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/net/media_upload.dart';
import 'package:remote_flutter/protocol/messages.dart';

/// 批量上传的三条硬性质:**保序**、**并发受限**、**单个失败不影响其余**。
/// 这三条都是可被"优化"掉的,所以每条都有直接断言。
void main() {
  MediaItem item(String name) => MediaItem(
        itemId: name,
        type: 'audio',
        name: name,
        url: 'http://x/$name',
      );

  group('runBoundedBatch', () {
    test('保序:结果按输入下标归位,与完成先后无关', () async {
      // 故意让后面的任务先完成 —— 若按完成顺序收集,曲序就被网速打乱了。
      final completers = [
        Completer<String>(),
        Completer<String>(),
        Completer<String>(),
      ];
      final future = runBoundedBatch<String>(
        count: 3,
        maxConcurrent: 3,
        task: (i) => completers[i].future,
      );
      // 逆序完成。
      completers[2].complete('c');
      completers[1].complete('b');
      completers[0].complete('a');
      final out = await future;
      expect(out.map((o) => o.value).toList(), ['a', 'b', 'c']);
      expect(out.map((o) => o.index).toList(), [0, 1, 2]);
    });

    test('并发受限:同时在跑的任务数不超过 maxConcurrent', () async {
      var active = 0;
      var peak = 0;
      final out = await runBoundedBatch<int>(
        count: 12,
        maxConcurrent: 4,
        task: (i) async {
          active++;
          if (active > peak) peak = active;
          // 让出事件循环,给其他 lane 机会重叠进来。
          await Future<void>.delayed(Duration.zero);
          active--;
          return i;
        },
      );
      expect(out.length, 12);
      expect(peak, lessThanOrEqualTo(4));
      // 并发确实发生了(否则说明退化成串行,优化没生效)。
      expect(peak, greaterThan(1));
    });

    test('单个失败不取消其余,失败信息随结果返回', () async {
      final out = await runBoundedBatch<int>(
        count: 5,
        maxConcurrent: 2,
        task: (i) async {
          if (i == 1 || i == 3) throw StateError('boom $i');
          return i;
        },
      );
      expect(out.length, 5);
      expect(out[0].ok, isTrue);
      expect(out[1].ok, isFalse);
      expect(out[1].error, isA<StateError>());
      expect(out[2].ok, isTrue);
      expect(out[3].ok, isFalse);
      expect(out[4].ok, isTrue);
      // 关键:失败之后的任务照样跑完了(旧的串行实现会在 i==1 处中断)。
      expect(out.where((o) => o.ok).map((o) => o.value).toList(), [0, 2, 4]);
    });

    test('lane 数不超过任务数,空批次直接返回', () async {
      var started = 0;
      final out = await runBoundedBatch<int>(
        count: 2,
        maxConcurrent: 16,
        task: (i) async {
          started++;
          return i;
        },
      );
      expect(out.length, 2);
      expect(started, 2);
      expect(await runBoundedBatch<int>(
              count: 0, maxConcurrent: 4, task: (i) async => i),
          isEmpty);
    });

    test('参数非法直接抛,不静默兜底', () {
      expect(
          () => runBoundedBatch<int>(
              count: 1, maxConcurrent: 0, task: (i) async => i),
          throwsArgumentError);
      expect(
          () => runBoundedBatch<int>(
              count: -1, maxConcurrent: 1, task: (i) async => i),
          throwsArgumentError);
    });
  });

  group('scanAudioFolder', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('scan_audio_');
    });

    tearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    Future<void> touch(String rel) async {
      final f = File('${root.path}${Platform.pathSeparator}$rel');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(const [0]);
    }

    test('递归收集音频并按路径排序(排序=播放顺序)', () async {
      await touch('03 c.mp3');
      await touch('01 a.mp3');
      await touch('02 b.flac');
      final found = await scanAudioFolder(root);
      expect(found.map((f) => f.name).toList(),
          ['01 a.mp3', '02 b.flac', '03 c.mp3']);
    });

    test('跳过非音频文件与无扩展名文件', () async {
      await touch('song.mp3');
      await touch('cover.jpg');
      await touch('notes.txt');
      await touch('README');
      final found = await scanAudioFolder(root);
      expect(found.map((f) => f.name).toList(), ['song.mp3']);
    });

    test('递归进子目录', () async {
      await touch('a.mp3');
      await touch('disc2${Platform.pathSeparator}b.mp3');
      final found = await scanAudioFolder(root);
      expect(found.length, 2);
      expect(found.map((f) => f.name).toSet(), {'a.mp3', 'b.mp3'});
    });

    test('扩展名大小写不敏感', () async {
      await touch('LOUD.MP3');
      await touch('Quiet.FlAc');
      final found = await scanAudioFolder(root);
      expect(found.length, 2);
    });

    test('maxFiles 截断,不把巨大目录全读进来', () async {
      for (var i = 0; i < 10; i++) {
        await touch('t$i.mp3');
      }
      final found = await scanAudioFolder(root, maxFiles: 4);
      expect(found.length, 4);
    });

    test('空目录返回空,不抛', () async {
      expect(await scanAudioFolder(root), isEmpty);
    });

    test('name 只取文件名,path 保留完整路径', () async {
      await touch('sub${Platform.pathSeparator}track.mp3');
      final found = await scanAudioFolder(root);
      expect(found.single.name, 'track.mp3');
      expect(found.single.path, contains('sub'));
      expect(File(found.single.path).existsSync(), isTrue);
    });
  });

  group('BatchProgress', () {
    test('总量未知时不假造百分比', () {
      final p = BatchProgress(2);
      expect(p.percent, isNull);
      p.report(0, 0, 0); // size 未知
      expect(p.percent, isNull);
    });

    test('按已知总量聚合,完成时补齐该文件字节', () {
      final p = BatchProgress(2);
      p.report(0, 50, 100);
      p.report(1, 0, 100);
      expect(p.percent, 25); // 50 / 200
      p.complete(0);
      expect(p.doneCount, 1);
      expect(p.percent, 50); // 100 / 200
    });

    test('百分比封顶 100', () {
      final p = BatchProgress(1);
      p.report(0, 999, 100);
      expect(p.percent, 100);
    });
  });

  group('uploadFilesInBatch', () {
    test('成功项保持用户挑选顺序,失败项只记名字', () async {
      final files = [
        (path: '/a.mp3', name: 'a.mp3'),
        (path: '/b.mp3', name: 'b.mp3'),
        (path: '/c.mp3', name: 'c.mp3'),
      ];
      final result = await uploadFilesInBatch(
        files: files,
        maxConcurrent: 3,
        upload: (f, onProgress) async {
          if (f.name == 'b.mp3') throw StateError('nope');
          // 让 c 比 a 先完成,验证保序不依赖完成先后。
          if (f.name == 'a.mp3') {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          onProgress(10, 10);
          return item(f.name);
        },
      );
      expect(result.items.map((i) => i.name).toList(), ['a.mp3', 'c.mp3']);
      expect(result.failedNames, ['b.mp3']);
      expect(result.okCount, 2);
      expect(result.allOk, isFalse);
    });

    test('全成功时文案带上后缀', () async {
      final result = await uploadFilesInBatch(
        files: [(path: '/a.mp3', name: 'a.mp3')],
        upload: (f, onProgress) async => item(f.name),
      );
      expect(result.allOk, isTrue);
      expect(result.describe(okSuffix: '；保存后才会下发到设备'),
          '已上传 1 个文件；保存后才会下发到设备');
    });

    test('部分失败的文案列出前三个并汇总总数', () async {
      final files = [
        for (var i = 0; i < 5; i++) (path: '/f$i', name: 'f$i.mp3'),
      ];
      final result = await uploadFilesInBatch(
        files: files,
        upload: (f, onProgress) async => throw StateError('all fail'),
      );
      expect(result.okCount, 0);
      final text = result.describe();
      expect(text, contains('失败 f0.mp3、f1.mp3、f2.mp3'));
      expect(text, contains('等 5 个'));
    });

    test('进度回调把聚合状态吐给 UI', () async {
      final seen = <String>[];
      await uploadFilesInBatch(
        files: [
          (path: '/a', name: 'a.mp3'),
          (path: '/b', name: 'b.mp3'),
        ],
        maxConcurrent: 1,
        onStatus: seen.add,
        upload: (f, onProgress) async {
          onProgress(100, 100);
          return item(f.name);
        },
      );
      expect(seen, isNotEmpty);
      expect(seen.last, contains('2/2'));
      // 状态串是给人看的中文,不含裸 JSON/异常。
      expect(seen.every((s) => s.startsWith('上传 ')), isTrue);
    });

    test('空列表不触发任何上传', () async {
      var called = 0;
      final result = await uploadFilesInBatch(
        files: const [],
        upload: (f, onProgress) async {
          called++;
          return item(f.name);
        },
      );
      expect(called, 0);
      expect(result.items, isEmpty);
      expect(result.allOk, isTrue);
    });
  });
}
