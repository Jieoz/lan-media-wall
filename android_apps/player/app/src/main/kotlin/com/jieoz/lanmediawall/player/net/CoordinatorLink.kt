package com.jieoz.lanmediawall.player.net

/**
 * The player's link to whatever is coordinating it — protocol_spec §14.
 *
 * In modes A/B the coordinator is a broker and the player is a WS **client**
 * ([BrokerClient]); in mode C (p2p, §14.3) there is no broker and the player is
 * a WS **server** ([P2pServer]) that the controller dials into. Both speak the
 * same envelope protocol (§2) and run the same §8 time_sync handshake — the
 * controller plays the broker's clock-master role in p2p (§14.3). PlayerService
 * drives both through this one interface so the playback / status / handshake
 * logic is identical regardless of topology.
 *
 * `to` addressing stays "broker" in both modes: in p2p the connected controller
 * *is* the broker role, so the same outbound frames work unchanged.
 */
interface CoordinatorLink {
    /** True when there is a live peer (broker connected, or a controller dialed
     *  into the p2p server). Gates status/thumbnail sends. */
    val isConnected: Boolean

    /** Begin operating (client connect loop, or server accept loop). */
    fun start()

    /**
     * Build, sign (per the active [AuthMode]), and send an envelope. Returns the
     * msg_id, or null if there is no peer to send to.
     */
    fun send(type: String, payload: Json, to: String = "broker"): String?

    /** Send a raw binary frame (thumbnail JPEG follows a thumb_meta text, §6.4). */
    fun sendBinary(data: ByteArray): Boolean

    /** The auth mode currently in force (the coordinator is authoritative, §13). */
    val authMode: AuthMode

    /** Stop and release all resources. */
    fun stop()
}
