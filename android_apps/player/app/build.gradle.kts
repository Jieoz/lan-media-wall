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
        minSdk = 24
        targetSdk = 34
        versionCode = 13
        versionName = "1.3.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            // No shrinking: the player is a kiosk app, keep it simple + debuggable.
            isMinifyEnabled = false
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

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
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
    implementation(libs.androidx.security.crypto)

    implementation(libs.media3.exoplayer)
    implementation(libs.media3.ui)
    implementation(libs.media3.common)

    implementation(libs.okhttp)
    implementation(libs.kotlinx.coroutines.android)

    // §15 QR pairing: ZXing core (Apache-2.0) for decode/encode — pure Java,
    // unit-testable on the JVM. CameraX drives the live preview/analysis on
    // device (behind the PairingScanner interface; not exercised in CI).
    implementation(libs.zxing.core)
    implementation(libs.camera.camera2)
    implementation(libs.camera.lifecycle)
    implementation(libs.camera.view)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
