# Default ProGuard rules. Release build does not minify (kiosk app), so these
# are intentionally minimal. Keep Media3 + OkHttp happy if shrinking is enabled.
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-keep class androidx.media3.** { *; }
