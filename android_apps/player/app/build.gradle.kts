plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

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
        versionCode = 24
        versionName = "1.10.4"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // §6: on minSdk 19 the merged dex can exceed the 65k method limit
        // (exoplayer2 + appcompat + okhttp + coroutines). Pre-21 has no native
        // multidex, so enable the support-library loader (see PlayerApp).
        multiDexEnabled = true
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
            // CI has no production keystore. Sign release with the standard debug
            // key so the shipped release APK is actually installable (an unsigned
            // release APK cannot be sideloaded). A real keystore, when wired via
            // -P props, can override this.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        debug {
            isMinifyEnabled = false
        }
    }

    // §6.1: APK MUST carry a v1 (JAR) signature or it won't install on <7.0
    // ("应用未安装"). AGP enables v1 by default at minSdk 19, but pin it
    // explicitly on the debug key both build types sign with, so a future
    // minSdk bump or AGP default change can't silently drop v1.
    signingConfigs.getByName("debug") {
        enableV1Signing = true
        enableV2Signing = true
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
    testImplementation(libs.kotlinx.coroutines.test)
}
