import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_wall/protocol/messages.dart';
import 'package:lan_media_wall/protocol/models.dart';

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
      loop: false,
      items: [item],
    );
    expect(payload['mode'], 'append');
  });

  test('explicit whole-list replacement remains available', () {
    final payload = Commands.playlist(
      playlistId: 'pl',
      groupId: 'default',
      sync: false,
      loop: false,
      items: [item],
      mode: 'replace',
    );
    expect(payload['mode'], 'replace');
  });
}
