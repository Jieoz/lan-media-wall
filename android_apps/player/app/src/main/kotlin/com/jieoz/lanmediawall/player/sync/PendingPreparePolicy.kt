package com.jieoz.lanmediawall.player.sync

/**
 * Pure decision helper for the playlist/prepare race (§9.1 + §21).
 *
 * Controller ships `playlist` and `prepare` back-to-back. The player must not
 * silently drop a prepare whose push_id has not been adopted yet; park it and
 * retry once the matching playlist lands. Empty push_id is still a hard reject
 * (generation contract — see stateful-command-invalidation).
 */
object PendingPreparePolicy {
    enum class Decision { ADOPT_NOW, PARK, REJECT }

    data class Parked(
        val playlistId: String,
        val pushId: String,
        val prepareId: String?,
        val groupId: String?,
        val startIndex: Int,
        val seekMs: Long,
        val prefetchBarrier: Boolean,
        val barrierTimeoutMs: Long,
        /** Opaque handle so the service can re-enter hPrepare with the original payload. */
        val rawPayloadToken: Long,
    )

    fun decide(
        playlistId: String?,
        pushId: String?,
        resolvedPushId: String?,
        playlistFound: Boolean,
    ): Decision {
        if (playlistId.isNullOrEmpty() || pushId.isNullOrEmpty()) return Decision.REJECT
        if (playlistFound && resolvedPushId == pushId) return Decision.ADOPT_NOW
        // Playlist missing OR present under a different push_id → race window.
        return Decision.PARK
    }

    fun matches(parked: Parked, playlistId: String?, pushId: String?): Boolean {
        if (playlistId.isNullOrEmpty() || pushId.isNullOrEmpty()) return false
        return parked.playlistId == playlistId && parked.pushId == pushId
    }

    @Suppress("UNUSED_PARAMETER")
    fun replace(previous: Parked?, incoming: Parked): Parked = incoming

    fun clearIf(parked: Parked?, reasonPlaylistReplace: Boolean): Parked? =
        if (reasonPlaylistReplace) null else parked
}
