import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/protocol/messages.dart';

void main() {
  final item = MediaItem(
    itemId: 'a',
    type: 'video',
    name: 'A',
    url: 'http://example/a.mp4',
  );

  test('ordinary composition defaults to append', () {
    final payload = Commands.playlist(
      playlistId: 'pl',
      groupId: 'default',
      sync: false,
      loopMode: LoopMode.none,
      items: [item],
    );
    expect(payload['mode'], 'append');
  });

  test('explicit whole-list replacement remains available', () {
    final payload = Commands.playlist(
      playlistId: 'pl',
      groupId: 'default',
      sync: false,
      loopMode: LoopMode.none,
      items: [item],
      mode: 'replace',
    );
    expect(payload['mode'], 'replace');
  });
}
