package com.example.remote_flutter

import io.flutter.embedding.android.FlutterActivity

/**
 * Never restore Flutter's Android instance/navigation state after process death.
 *
 * This makes a genuine cold restart enter Dart's ResponsiveShell home instead of
 * resurrecting a previously open settings dialog. A normal foreground/background
 * transition does not recreate the Activity, so its live dialog remains intact.
 */
class MainActivity : FlutterActivity() {
    override fun shouldRestoreAndSaveState(): Boolean = false
}
