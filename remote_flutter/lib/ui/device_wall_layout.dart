/// Pure responsive decisions for the device-wall action area.
class DeviceWallLayout {
  const DeviceWallLayout._();

  static bool compactActions(double width) => width < 300;

  /// The 360dp landscape rail must retain labelled controls rather than a
  /// squeezed row that degrades into circular-looking icon buttons.
  static int actionColumns(double width) => 1;
}
