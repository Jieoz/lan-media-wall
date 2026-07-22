package com.jieoz.lanmediawall.player

/** Only callbacks owned by the current transport generation may mutate state. */
internal fun ownsTransportGeneration(current: Long, callback: Long): Boolean =
    current == callback
