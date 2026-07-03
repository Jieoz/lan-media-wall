# ProGuard/R8 规则 —— minSdk 19 kiosk release 构建**必须** shrink+DCE（见 app/
# build.gradle.kts release 注释）。目标：让 R8 真正裁掉 ExoPlayer/okhttp 未用代码，
# 把合并 dex 塌回单 dex，规避 4.4 安装期 dexopt/LinearAlloc 失败（"安装文件出错"）。
#
# 关键教训（本次修复的核心）：早先用
#     -keep class com.google.android.exoplayer2.** { *; }
#     -keep class okhttp3.** { *; }
# 全量保留整个包——这会**彻底废掉 DCE**：几千个从未被引用的类（ExoPlayer 的
# DASH/HLS/SmoothStreaming/RTSP/UI/cast、okhttp 的 tls/cache/ws 等）被强行保留进
# 主 dex，主 dex 撑爆 → 3-dex legacy-multidex → 8MB+ 主 dex 装不上 4.4。
#
# 正确做法：**不手动 keep 库的实现类**。ExoPlayer 2.x / okhttp 3.x 都自带
# consumer ProGuard 规则（随 aar 合并进本工程），已 keep 住各自反射入口；R8 会从
# 我们**实际引用的 4 个 ExoPlayer 类**（ExoPlayer/MediaItem/Player/PlaybackException，
# 见 media/PlayerController.kt）出发做可达性分析，未用类全部裁掉。库若有 R8 触碰不到
# 的反射点，consumer 规则已声明；我们只补 `-dontwarn` 压掉 optional 依赖的告警。

# --- 库告警静音（optional 传递依赖，运行期用不到；不影响可达性）---
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# ExoPlayer 2.x（media3 1.4 → com.google.android.exoplayer2.*）。
# 不再 `-keep` 整个包：交给 aar 自带 consumer 规则 + R8 可达性裁剪。仅静音告警，
# 让 R8 能安全丢弃 DASH/HLS/RTSP/cast 等我们从不引用的子模块。
-dontwarn com.google.android.exoplayer2.**

# okhttp 3.12（最后一条 <21 分支）+ 可选 TLS provider。okhttp 自带 consumer 规则；
# 这里只 `-dontwarn`（不 `-keep`），R8 即可裁掉 cache/ws/tls 未用路径。
-dontwarn okhttp3.**
-dontwarn okio.**

# ZXing core（被控端纯 Java 二维码**生成**）。反射按名加载 format/decoder，窄 keep：
# 只保留其枚举与入口，仍允许裁掉未用的 decoder。生成路径实际只用 QRCodeWriter +
# BarcodeFormat + EncodeHintType，但 zxing 内部按枚举名反射，保守 keep 整个包最稳
# 且体量很小（~500KB 纯算法类，非膨胀源）——不与 4.4 dex 目标冲突。
-keep class com.google.zxing.** { *; }
-dontwarn com.google.zxing.**

# --- App 入口点（经 Manifest 反射实例化，必须 keep）---
-keep class com.jieoz.lanmediawall.player.PlayerApp { *; }
-keep class com.jieoz.lanmediawall.player.PlayerService { *; }
-keep class com.jieoz.lanmediawall.player.MainActivity { *; }
-keep class com.jieoz.lanmediawall.player.SettingsActivity { *; }
-keep class com.jieoz.lanmediawall.player.boot.BootReceiver { *; }
-keep class com.jieoz.lanmediawall.player.admin.PlayerDeviceAdminReceiver { *; }
# activity-alias `.HomeAlias` 的 targetActivity 是 MainActivity（已 keep）；alias 本身
# 无独立类，PackageManager.setComponentEnabledSetting 按组件名切换，无需额外 keep。

# 从 XML layout 反射构造的自定义 View（带 (Context, AttributeSet) 构造器）必须 keep。
-keepclasseswithmembers class * {
    public <init>(android.content.Context, android.util.AttributeSet);
}
