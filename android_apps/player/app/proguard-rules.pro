# Default ProGuard rules. Release build does not minify (kiosk app), so these
# are intentionally minimal. Keep Media3 + OkHttp happy if shrinking is enabled.
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# §6.2: the player uses ExoPlayer 2.x (com.google.android.exoplayer2.*), NOT
# media3 — keep the correct package so R8 shrinking can't strip the core.
-keep class com.google.android.exoplayer2.** { *; }
-dontwarn com.google.android.exoplayer2.**

# okhttp 3.12 (last <21 branch) + optional TLS providers: silence + keep.
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }

# ZXing core (pure-Java QR generation on the controlled side).
-keep class com.google.zxing.** { *; }

# App entry points reached via manifest (Application / Service / receivers /
# activities / activity-alias / DeviceAdminReceiver) must survive shrinking.
-keep class com.jieoz.lanmediawall.player.PlayerApp { *; }
-keep class com.jieoz.lanmediawall.player.PlayerService { *; }
-keep class com.jieoz.lanmediawall.player.MainActivity { *; }
-keep class com.jieoz.lanmediawall.player.SettingsActivity { *; }
-keep class com.jieoz.lanmediawall.player.boot.BootReceiver { *; }
-keep class com.jieoz.lanmediawall.player.admin.PlayerDeviceAdminReceiver { *; }

# Keep any View with a (Context, AttributeSet) ctor used from XML layouts.
-keepclasseswithmembers class * {
    public <init>(android.content.Context, android.util.AttributeSet);
}
