package com.jieoz.lanmediawall.player

import android.app.Application

/**
 * Application entry point. Kept minimal — the real lifecycle lives in
 * [PlayerService]. Exists so we have a stable Application context for early
 * settings reads and as the manifest android:name anchor.
 */
class PlayerApp : Application() {
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
