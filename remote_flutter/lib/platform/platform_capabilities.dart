/// Platform capability flags for the shared controller codebase.
///
/// The SAME Dart code ships as the Android/iOS remote and the Windows desktop
/// controller. The only user-visible divergence is the QR / camera scan-to-add
/// feature (HARD requirement: the Windows controller must NOT contain or expose
/// camera scanning). This is a capability branch, not a forked codebase.
///
/// Enforcement is two-layered:
///  1. Compile-time: the Windows CI build passes
///     `--dart-define=LMW_DISABLE_SCANNER=true`, which flips [scanToAddSupported]
///     off unconditionally.
///  2. Runtime: even without the define, only Android/iOS report the capability,
///     so a desktop build never constructs the camera scanner widget (the
///     `mobile_scanner` runtime path is never taken).
library;

import 'package:flutter/foundation.dart';

/// Compile-time kill switch. Windows controller CI sets this true so the
/// scanner UI and its runtime are absent from that artifact.
const bool _disableScannerDefine =
    bool.fromEnvironment('LMW_DISABLE_SCANNER', defaultValue: false);

/// Compile-time kill switch for QR *display*. The Windows controller must not
/// only be unable to scan a QR (camera), it must not generate or show one
/// either (HARD requirement: "no QR" on Windows). CI sets this true so the
/// invite screen renders the copyable pairing URI only, never a `QrImageView`.
const bool _disableQrDisplayDefine =
    bool.fromEnvironment('LMW_DISABLE_QR', defaultValue: false);

/// Product/display name, overridable per artifact via
/// `--dart-define=LMW_PRODUCT_NAME=...` (the Windows controller uses a distinct
/// identity from the mobile remote and from the Windows Player).
const String controllerProductName = String.fromEnvironment(
  'LMW_PRODUCT_NAME',
  defaultValue: 'LAN Media Wall 遥控端',
);

/// Whether camera QR scan-to-add is available on this platform/build.
/// Android/iOS: yes. Windows/desktop/web or when the kill switch is set: no.
bool get scanToAddSupported {
  if (_disableScannerDefine) return false;
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

/// Whether this build may *display* a pairing QR code. Mobile remotes show a QR
/// so a TV box can be pointed at it; the Windows controller must not (no camera
/// on either side of that flow, and the "no QR" requirement is explicit). When
/// QR display is off, the invite UI falls back to the copyable `lmw://` URI.
bool get qrInviteDisplaySupported {
  if (_disableQrDisplayDefine) return false;
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}
