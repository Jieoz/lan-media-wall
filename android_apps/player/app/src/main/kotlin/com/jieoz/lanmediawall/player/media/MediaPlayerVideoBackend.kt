package com.jieoz.lanmediawall.player.media

import android.content.Context
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.SurfaceHolder
import android.view.SurfaceView
import java.io.File

/**
 * §backend-ab: the NATIVE `android.media.MediaPlayer` video kernel — a first-class
 * alternative to ExoPlayer for the QZX_C1 / HiSilicon / YunOS 4.4.2 boxes.
 *
 * WHY native MediaPlayer: on these boxes MediaPlayer drives the OEM's own
 * Stagefright/AwesomePlayer + OMX pipeline — the exact path the vendor firmware is
 * tuned for. ExoPlayer's generic codec plumbing (even hardware-only) has dropped
 * frames / black-screened on this legacy HiSilicon silicon; the native player can
 * succeed where it stalls. We offer BOTH and A/B them (see [BackendSelector]).
 *
 * State machine (Android MediaPlayer states): we track a small [State] so every
 * call is legal for the player's current state — calling getCurrentPosition() in
 * Error/Idle, or start() before onPrepared, throws IllegalStateException on 4.4.
 * We never let that crash playback; illegal transitions are dropped + logged.
 *
 * Synced start (§9.2): [loadPaused] prepares and stays paused, seeking to the
 * requested offset. If the caller invokes [play] before onPrepared fires, we latch
 * [startWhenPrepared] and start the instant preparation completes — so play_at is
 * honored without a false "started" ack. A single-item loop uses setLooping(true);
 * a non-looping clip fires [onEnded] via onCompletion so the service advances.
 *
 * Threading: all methods run on the app MAIN thread (facade marshals); listeners
 * are delivered on the main thread. No blocking.
 *
 * HONEST diagnostics limits vs ExoPlayer (recorded, never faked):
 *  - decoder NAME is not exposed by MediaPlayer → [lastVideoDecoderName] stays null.
 *  - dropped-frame count has no callback → BackendMetrics reports `dropped_frames=n/a`.
 *  - first-frame is proxied by MEDIA_INFO_VIDEO_RENDERING_START (API 17+); on older
 *    behavior we fall back to onPrepared+start as the "pixels can appear" instant.
 */
class MediaPlayerVideoBackend(context: Context) : VideoBackend {

    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())

    override val backend = PlayerBackend.MEDIAPLAYER
    override val metrics = BackendMetrics()

    /** MediaPlayer never exposes the chosen decoder name. */
    override val lastVideoDecoderName: String? = null

    override var logSink: ((String) -> Unit)? = null
    override var onError: ((String) -> Unit)? = null
    override var onEnded: (() -> Unit)? = null

    private fun log(msg: String) { logSink?.invoke(msg) }

    private enum class State { IDLE, PREPARING, PREPARED, STARTED, PAUSED, COMPLETED, ERROR }

    @Volatile private var player: MediaPlayer? = null
    @Volatile private var surfaceView: SurfaceView? = null
    @Volatile private var surfaceHolder: SurfaceHolder? = null
    @Volatile private var surfaceValid = false

    @Volatile private var state = State.IDLE
    @Volatile private var lastError: String? = null

    /** requested seek to apply once prepared (synced-start / resume offset). */
    @Volatile private var pendingSeekMs: Long = 0
    /** caller asked to play before prepare finished → start on prepared. */
    @Volatile private var startWhenPrepared = false
    @Volatile private var preparedSeekInProgress = false
    /** current item should loop (single-item playlist). */
    @Volatile private var looping = false
    /** last volume set by the facade (0..1), re-applied after (re)prepare. */
    @Volatile private var volume: Float = 1f
    /** known media duration (cached; getDuration is illegal in some states). */
    @Volatile private var knownDurationMs: Long = 0

    private var loadStartedMs = 0L
    @Volatile private var firstFrameSeen = false

    override fun init() {
        // MediaPlayer is created per-load (setDataSource requires the Idle state
        // and reset() is the clean way to reuse). Nothing global to build here;
        // just note the kernel is selected. Metrics deliberately leaves
        // dropped-frames disabled → reported as n/a (the platform can't measure it).
        runOnMain { log("init done backend=${backend.id} surface=SurfaceView note=mediaplayer_lazy") }
    }

    // --- surface lifecycle ------------------------------------------------
    private val holderCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) {
            surfaceValid = true
            log("surface created")
            // (re)bind display now that we have a live surface.
            player?.let { safeSetDisplay(it, holder) }
        }

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            surfaceValid = true
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            surfaceValid = false
            log("surface destroyed")
            // detach the dead surface so the player doesn't render into a freed buffer.
            try { player?.setDisplay(null) } catch (_: Throwable) {}
        }
    }

    override fun attachSurface(view: SurfaceView) {
        runOnMain {
            if (surfaceView === view) return@runOnMain
            surfaceHolder?.removeCallback(holderCallback)
            surfaceView = view
            val holder = view.holder
            surfaceHolder = holder
            holder.addCallback(holderCallback)
            // holder.surface may already be valid (Activity re-attach).
            surfaceValid = holder.surface?.isValid == true
            if (surfaceValid) player?.let { safeSetDisplay(it, holder) }
        }
    }

    override fun detachSurface() {
        runOnMain {
            surfaceHolder?.removeCallback(holderCallback)
            try { player?.setDisplay(null) } catch (_: Throwable) {}
            surfaceHolder = null
            surfaceView = null
            surfaceValid = false
        }
    }

    private fun safeSetDisplay(mp: MediaPlayer, holder: SurfaceHolder) {
        try {
            if (holder.surface?.isValid == true) mp.setDisplay(holder)
        } catch (t: Throwable) {
            log("set_display_fail ${t.javaClass.simpleName}:${t.message}")
        }
    }

    // --- load -------------------------------------------------------------
    override fun loadPaused(uri: String, seekMs: Long, loop: Boolean) {
        runOnMain { doLoad(uri, seekMs, loop, autoStart = false) }
    }

    override fun loadAndPlay(uri: String, seekMs: Long, loop: Boolean) {
        runOnMain { doLoad(uri, seekMs, loop, autoStart = true) }
    }

    private fun doLoad(uri: String, seekMs: Long, loop: Boolean, autoStart: Boolean) {
        val tag = if (autoStart) "loadAndPlay" else "loadPaused"
        log("$tag uri=${describeUri(uri)} seekMs=$seekMs loop=$loop backend=${backend.id}")
        // Retire the old instance and its latched callbacks before installing the
        // state for this load. releasePlayer() intentionally clears old start intent.
        releasePlayer()
        lastError = null
        pendingSeekMs = seekMs.coerceAtLeast(0)
        startWhenPrepared = autoStart
        preparedSeekInProgress = false
        looping = loop
        firstFrameSeen = false
        knownDurationMs = 0
        metrics.onLoad()
        metrics.onNewItem()

        // fresh player each load: reset() from Error is unreliable on 4.4, and a
        // clean instance sidesteps stale listener/state carry-over.
        val mp = MediaPlayer()
        player = mp
        state = State.PREPARING
        loadStartedMs = SystemClock.elapsedRealtime()

        mp.setOnPreparedListener { onPrepared(it) }
        mp.setOnCompletionListener { onCompletion() }
        mp.setOnErrorListener { _, what, extra -> onErrorCb(what, extra) }
        mp.setOnInfoListener { _, what, extra -> onInfo(what, extra) }
        mp.setOnVideoSizeChangedListener { _, w, h ->
            metrics.onVideoSize(w, h)
            log("video_size ${w}x${h}")
        }
        mp.setOnSeekCompleteListener {
            if (player !== mp) return@setOnSeekCompleteListener
            val completesPreparedSeek = preparedSeekInProgress
            preparedSeekInProgress = false
            log("seek_complete position_ms=${safePosition()}")
            if (completesPreparedSeek && startWhenPrepared) doStart()
        }

        try {
            mp.setDataSource(appContext, resolveUri(uri))
        } catch (t: Throwable) {
            failLoad("setDataSource", t)
            return
        }
        // bind the surface if we already have a live one; else holderCallback binds it.
        surfaceHolder?.let { if (surfaceValid) safeSetDisplay(mp, it) }
        applyVolume(mp)
        try {
            mp.setLooping(loop)
            mp.prepareAsync() // async: never block the main thread on network/decoder open
        } catch (t: Throwable) {
            failLoad("prepareAsync", t)
        }
    }

    private fun resolveUri(uri: String): Uri {
        return if (uri.startsWith("http://") || uri.startsWith("https://") || uri.startsWith("content://")) {
            Uri.parse(uri)
        } else {
            Uri.fromFile(File(uri.removePrefix("file://")))
        }
    }

    private fun onPrepared(mp: MediaPlayer) {
        if (player !== mp) return // stale
        state = State.PREPARED
        knownDurationMs = try { mp.duration.toLong().coerceAtLeast(0) } catch (_: Throwable) { 0 }
        metrics.onPrepared(SystemClock.elapsedRealtime() - loadStartedMs)
        log("prepared duration_ms=$knownDurationMs seek_pending=$pendingSeekMs start=$startWhenPrepared")
        applyVolume(mp)
        if (pendingSeekMs > 0) {
            try {
                preparedSeekInProgress = true
                mp.seekTo(pendingSeekMs.toInt())
            } catch (t: Throwable) {
                preparedSeekInProgress = false
                log("seek_fail ${t.javaClass.simpleName}")
            }
        }
        if (startWhenPrepared && !preparedSeekInProgress) {
            doStart()
        } else {
            // Prime a still first frame while paused: a seekTo (even to current pos)
            // pushes one decoded frame to the surface on most HiSilicon builds, so a
            // synced-start box shows the opening frame instead of black until play_at.
            if (pendingSeekMs == 0L) {
                try { mp.seekTo(0) } catch (_: Throwable) {}
            }
        }
    }

    private fun onCompletion() {
        // setLooping(true) restarts internally and does NOT fire onCompletion, so
        // reaching here means a non-looping clip ended → advance the playlist.
        if (looping) return
        state = State.COMPLETED
        metrics.onCompletion()
        log("completion position_ms=${safePosition()}")
        onEnded?.invoke()
    }

    private fun onErrorCb(what: Int, extra: Int): Boolean {
        state = State.ERROR
        val code = "mp_error what=$what extra=$extra"
        lastError = code
        metrics.onError(code)
        log("error $code")
        onError?.invoke(code)
        return true // handled: suppress the default error dialog path
    }

    private fun onInfo(what: Int, extra: Int): Boolean {
        when (what) {
            MediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START -> { // API 17+; first real frame
                if (!firstFrameSeen) {
                    firstFrameSeen = true
                    metrics.onFirstFrame(SystemClock.elapsedRealtime() - loadStartedMs)
                    log("first_frame rendered position_ms=${safePosition()}")
                }
            }
            MediaPlayer.MEDIA_INFO_BUFFERING_START -> {
                if (firstFrameSeen) metrics.onStall()
                log("buffering_start position_ms=${safePosition()}")
            }
            MediaPlayer.MEDIA_INFO_BUFFERING_END -> log("buffering_end position_ms=${safePosition()}")
            MediaPlayer.MEDIA_INFO_VIDEO_TRACK_LAGGING -> log("video_track_lagging position_ms=${safePosition()}")
            else -> { /* uninteresting info code */ }
        }
        return false
    }

    private fun failLoad(stage: String, t: Throwable) {
        state = State.ERROR
        val code = "mp_$stage:${t.javaClass.simpleName}"
        lastError = code
        metrics.onError(code)
        log("error stage=$stage type=${t.javaClass.simpleName} msg=${t.message}")
        onError?.invoke(code)
    }

    // --- transport controls ----------------------------------------------
    override fun play() = runOnMain {
        when (state) {
            State.PREPARING -> { startWhenPrepared = true } // start on prepared
            State.PREPARED, State.PAUSED, State.STARTED, State.COMPLETED -> {
                startWhenPrepared = true
                if (!preparedSeekInProgress) doStart()
            }
            else -> log("play ignored state=$state")
        }
    }

    private fun doStart() {
        val mp = player ?: return
        try {
            if (state == State.COMPLETED) mp.seekTo(0)
            mp.start()
            state = State.STARTED
            log("started position_ms=${safePosition()}")
        } catch (t: Throwable) {
            failLoad("start", t)
        }
    }

    override fun pause() = runOnMain {
        startWhenPrepared = false // a pause before prepared cancels the auto-start
        val mp = player ?: return@runOnMain
        if (state == State.STARTED) {
            try { mp.pause(); state = State.PAUSED; log("paused position_ms=${safePosition()}") }
            catch (t: Throwable) { log("pause_fail ${t.javaClass.simpleName}") }
        }
    }

    override fun stop() = runOnMain {
        startWhenPrepared = false
        releasePlayer()
        state = State.IDLE
        log("stopped")
    }

    override fun seekTo(ms: Long) = runOnMain {
        val target = ms.coerceAtLeast(0)
        val mp = player
        if (mp != null && state in setOf(State.PREPARED, State.STARTED, State.PAUSED, State.COMPLETED)) {
            try { mp.seekTo(target.toInt()) } catch (t: Throwable) { log("seek_fail ${t.javaClass.simpleName}") }
        } else {
            pendingSeekMs = target // apply on prepared
        }
    }

    override fun setVolume(volume0to1: Float) = runOnMain {
        volume = volume0to1.coerceIn(0f, 1f)
        player?.let { applyVolume(it) }
    }

    private fun applyVolume(mp: MediaPlayer) {
        try { mp.setVolume(volume, volume) } catch (t: Throwable) { log("volume_fail ${t.javaClass.simpleName}") }
    }

    override fun snapshot(): VideoSnapshot = blockingOnMain(snapshotFallback()) {
        val mp = player
        val hasMedia = mp != null && state != State.IDLE && state != State.ERROR
        val pos = if (hasMedia) safePosition() else 0
        val dur = if (knownDurationMs > 0) knownDurationMs else 0
        val isPlaying = state == State.STARTED && (try { mp?.isPlaying == true } catch (_: Throwable) { false })
        VideoSnapshot(
            positionMs = pos,
            durationMs = dur,
            isPlaying = isPlaying,
            state = state.name.lowercase(),
            hasMedia = hasMedia,
            error = lastError,
        )
    }

    private fun snapshotFallback() = VideoSnapshot(
        0, knownDurationMs.coerceAtLeast(0), false, "snapshot_timeout",
        state != State.IDLE && state != State.ERROR, lastError,
    )

    private fun safePosition(): Long {
        return try {
            val mp = player ?: return 0
            if (state in setOf(State.PREPARED, State.STARTED, State.PAUSED, State.COMPLETED))
                mp.currentPosition.toLong().coerceAtLeast(0) else 0
        } catch (_: Throwable) { 0 }
    }

    override fun release() = runOnMain {
        detachSurfaceInternal()
        releasePlayer()
        state = State.IDLE
    }

    private fun detachSurfaceInternal() {
        surfaceHolder?.removeCallback(holderCallback)
        surfaceHolder = null
        surfaceView = null
        surfaceValid = false
    }

    private fun releasePlayer() {
        preparedSeekInProgress = false
        startWhenPrepared = false
        val mp = player ?: return
        player = null
        try { mp.setOnPreparedListener(null) } catch (_: Throwable) {}
        try { mp.setOnCompletionListener(null) } catch (_: Throwable) {}
        try { mp.setOnErrorListener(null) } catch (_: Throwable) {}
        try { mp.setOnInfoListener(null) } catch (_: Throwable) {}
        try { mp.reset() } catch (_: Throwable) {}
        try { mp.release() } catch (_: Throwable) {}
    }

    private fun describeUri(uri: String): String {
        return try {
            if (uri.startsWith("http://") || uri.startsWith("https://")) {
                "REMOTE_URL($uri)"
            } else {
                val f = File(uri.removePrefix("file://"))
                "local(${f.name},exists=${f.exists()},size=${if (f.exists()) f.length() else -1})"
            }
        } catch (e: Exception) {
            "uri($uri)"
        }
    }

    // --- threading helper -------------------------------------------------
    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block()
        else mainHandler.post(block)
    }

    private fun <T> blockingOnMain(fallback: T, block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = java.util.concurrent.CountDownLatch(1)
        var result: Any? = null
        mainHandler.post { try { result = block() } finally { latch.countDown() } }
        if (!latch.await(2, java.util.concurrent.TimeUnit.SECONDS)) return fallback
        @Suppress("UNCHECKED_CAST")
        return result as T
    }
}
