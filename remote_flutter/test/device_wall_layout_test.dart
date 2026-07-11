import 'package:flutter_test/flutter_test.dart';
import 'package:remote_flutter/ui/device_wall_layout.dart';

void main() {
  test('wide device pane keeps action buttons as labelled controls', () {
    expect(DeviceWallLayout.actionColumns(360), 1);
    expect(DeviceWallLayout.compactActions(360), isFalse);
  });

  test('very narrow phone may use compact actions without affecting landscape', () {
    expect(DeviceWallLayout.actionColumns(280), 1);
    expect(DeviceWallLayout.compactActions(280), isTrue);
  });
}