package com.jieoz.lanmediawall.player

import androidx.multidex.MultiDexApplication

/**
 * Application entry point. Kept minimal — the real lifecycle lives in
 * [PlayerService]. Exists so we have a stable Application context for early
 * settings reads and as the manifest android:name anchor.
 *
 * §6.2: extends MultiDexApplication so that IF the method count ever
 * spills past the 64K Dalvik limit again on minSdk 19 (pre-native-
 * multidex), the secondary dexes are installed at startup. With R8
 * shrinking on (see build.gradle.kts) the app is a single dex today,
 * but this keeps the pre-21 loader wired as a safety net.
 */
class PlayerApp : MultiDexApplication() {
    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    companion object {
        @Volatile
        lateinit var instance: PlayerApp
            private set
    }
}
