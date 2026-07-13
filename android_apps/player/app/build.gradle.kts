import java.io.FileInputStream
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

// §根因B: 稳定 release 签名。CI 从 GitHub Actions Secret 解码固定 keystore,写出
// key.properties(指向 $RUNNER_TEMP 的 keystore,绝不进仓库)。本文件读取它;存在
// 则 release 用**固定证书**签名——同一指纹跨版本一致,覆盖安装(§23 远程 update_app)
// 不再 INSTALL_FAILED_UPDATE_INCOMPATIBLE、不必卸载重装。无 secret(如 fork PR)时
// 优雅降级到 debug 签名,出可安装的 APK,构建绝不失败。
// key.properties 与 keystore 都不入库(见 .gitignore),明文凭据只活在 CI runner 内。
val keystorePropsFile: File = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        FileInputStream(keystorePropsFile).use { load(it) }
    }
}
val hasReleaseKeystore: Boolean =
    keystoreProps.getProperty("storeFile")?.let { file(it).exists() } ?: false

// Release version single source of truth: reuse remote_flutter/pubspec.yaml
// (`version: X.Y.Z+N`) so player/controller/tag never drift again.
val repoRoot: File = rootProject.projectDir.parentFile.parentFile
val releaseVersionLine: String? = repoRoot.resolve("remote_flutter/pubspec.yaml")
    .takeIf { it.exists() }
    ?.readLines()
    ?.firstOrNull { it.trimStart().startsWith("version:") }
    ?.substringAfter("version:")
    ?.trim()
val releaseVersionName: String = releaseVersionLine
    ?.substringBefore("+")
    ?.takeIf { it.isNotBlank() }
    ?: "1.11.0"
val releaseVersionCode: Int = releaseVersionLine
    ?.substringAfter("+", "")
    ?.toIntOrNull()
    ?: 28

android {
    namespace = "com.jieoz.lanmediawall.player"
    // SDK 34 platform is not in this build image; compile against 35 which is
    // present. targetSdk stays at 34 per the project spec (runtime behavior).
    compileSdk = 35

    defaultConfig {
        applicationId = "com.jieoz.lanmediawall.player"
        // §6: minSdk 24 -> 19 (Android 4.4.2). Fixes INSTALL_FAILED_OLDER_SDK on
        // the target 1688 外贸盒. targetSdk stays high for modern-OS behavior.
        minSdk = 19
        targetSdk = 34
        versionCode = releaseVersionCode
        versionName = releaseVersionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // §6: on minSdk 19 the merged dex can exceed the 65k method limit
        // (exoplayer2 + appcompat + okhttp + coroutines). Pre-21 has no native
        // multidex, so enable the support-library loader (see PlayerApp).
        multiDexEnabled = true
    }

    // §6.1: APK MUST carry a v1 (JAR) signature or it won't install on <7.0
    // ("应用未安装"). AGP enables v1 by default at minSdk 19, but pin it
    // explicitly on the debug key both build types sign with, so a future
    // minSdk bump or AGP default change can't silently drop v1.
    // NOTE: declared BEFORE buildTypes so release.signingConfig can resolve the
    // "release" config below (Kotlin DSL blocks are evaluated top-to-bottom).
    signingConfigs {
        getByName("debug") {
            enableV1Signing = true
            enableV2Signing = true
        }
        // §根因B: 固定 release 证书。仅当 CI 解码出 key.properties 且 keystore 文件
        // 存在时才配置(否则 storeFile 为 null,AGP 会在无 release 构建时也报错)。
        // v1+v2 都开:minSdk 19 必须 v1(JAR 签名)否则 <7.0 装不上(§6.1);v2 给
        // 现代系统更快校验。凭据全部来自 key.properties(CI 从 Secret 写),不硬编码。
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            // §6.2: R8 shrink+DCE is REQUIRED on this minSdk-19 kiosk build.
            // Without it the un-minified app spills past the 64K method limit
            // into a 3-dex legacy-multidex APK whose 8.4MB primary dex fails
            // install-time dexopt on cheap 4.4 外贸盒 (INSTALL_FAILED_DEXOPT ->
            // "安装文件出错"). Shrinking collapses it to a single small dex,
            // which installs cleanly AND removes the pre-21 MultiDex.install()
            // dependency. resource shrinking off (keeps it simple).
            isMinifyEnabled = true
            // §根因B: 有固定 keystore(CI 解码出 key.properties) → 用 release 固定证书
            // 签名,指纹跨版本一致 → 覆盖升级 OK。无 keystore(fork PR / 本地) → 降级
            // 到 debug 签名,APK 仍可 sideload,构建不失败。
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        debug {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // §6/§6.1: desugar java.time/stream so they don't VerifyError on API 19.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        viewBinding = true
        buildConfig = true
    }

    // Kotlin sources live under src/main/kotlin (not the default src/main/java).
    sourceSets["main"].kotlin.srcDir("src/main/kotlin")
    sourceSets["test"].kotlin.srcDir("src/test/kotlin")

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.activity.ktx)
    implementation(libs.androidx.lifecycle.service)
    // §6: pre-21 multidex loader (minSdk 19 has no native multidex).
    implementation(libs.androidx.multidex)

    // §6 播放内核: media3 1.4 -> ExoPlayer 2.19.1 (com.google.android.exoplayer2.*).
    // Umbrella artifact bundles core + ui; we only use the core player + a
    // TextureView surface (no PlayerView), so ui is unused but harmless.
    implementation(libs.exoplayer)

    implementation(libs.okhttp)
    implementation(libs.kotlinx.coroutines.android)

    // §15 pairing:被控端只**生成**二维码(显示本机 IP/device_id/group 供手机扫)。
    // ZXing core 是纯 Java、兼容 4.4;摄像头扫码整套(CameraX)已按 §1 删除。
    implementation(libs.zxing.core)

    // §6/§6.1: java.time/stream backport for API 19.
    coreLibraryDesugaring(libs.desugar.jdk.libs)

    testImplementation(libs.junit)
    testImplementation(libs.mockwebserver)
    testImplementation(libs.kotlinx.coroutines.test)
}
