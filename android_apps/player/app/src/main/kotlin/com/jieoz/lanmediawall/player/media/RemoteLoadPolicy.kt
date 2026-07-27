package com.jieoz.lanmediawall.player.media

/**
 * Where a media load is allowed to open its data source.
 *
 * FIELD ROOT CAUSE (v1.19.5, and-c937df0cdb): `MediaPlayer.setDataSource(ctx, uri)`
 * performs the DNS + TCP connect for an http(s) URI **synchronously, on the calling
 * thread**. [MediaPlayerVideoBackend] marshals every call onto the app MAIN thread,
 * so a music item whose URL pointed at a controller that no longer exists
 * (`http://10.10.8.161:40571/...`, the controller had moved to 10.10.8.45) parked
 * the main thread on a TCP connect until the kernel gave up.
 *
 * Everything the player does is posted to that same thread, so the whole video
 * kernel went silent: 音乐→图片 produced no `stopped`, the following mode switch
 * produced no `loadAndPlay`, and 20+ `watchdog_recover` ticks accomplished nothing
 * because the watchdog also needs the main thread. The screen simply froze — the
 * field symptom reported as "音乐切回图片黑屏".
 *
 * `prepareAsync()` was already chosen to keep network work off the main thread; the
 * gap was that opening the data source is network work too.
 */
object RemoteLoadPolicy {

    /**
     * How long a remote open may take before the load is failed.
     *
     * A dead LAN host is the case that matters: an unreachable address can hang for
     * tens of seconds on TCP retransmits. Playback must not wait that long — failing
     * fast lets the service mark the item and advance to the next one. Local files
     * are not subject to this (they never hit the network).
     */
    const val REMOTE_OPEN_TIMEOUT_MS = 6_000L

    /**
     * True when opening [uri] can block on the network and therefore must not run on
     * the main thread. Local paths / file: URIs open from disk and stay inline: they
     * cannot stall, and keeping them synchronous preserves the existing ordering
     * guarantees for the common case.
     */
    fun needsOffMainThreadOpen(uri: String): Boolean {
        val u = uri.trim()
        return u.startsWith("http://", ignoreCase = true) ||
            u.startsWith("https://", ignoreCase = true) ||
            u.startsWith("rtsp://", ignoreCase = true)
    }
}
