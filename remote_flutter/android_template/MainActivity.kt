package com.example.remote_flutter

import android.os.Bundle
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

    // Some Android/vendor combinations hand FlutterActivity a saved route before
    // shouldRestoreAndSaveState() is consulted. Null it at the Activity boundary
    // so a true relaunch always starts from Dart's canonical home shell.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(null)
    }
}
