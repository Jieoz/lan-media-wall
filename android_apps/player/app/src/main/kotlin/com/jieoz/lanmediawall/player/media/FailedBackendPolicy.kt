package com.jieoz.lanmediawall.player.media

/**
 * How to quiet the video kernel before the image layer takes the screen.
 *
 * Extracted as a pure function because the call site ([PlayerController.showImage])
 * needs real Android views and cannot be unit tested, while the decision itself is
 * exactly where a field defect lived.
 */
enum class BackendQuietAction {
    /** Normal path: keep the instance, just stop playback. */
    PAUSE,

    /** Failed path: tear the instance down so its dead surface stops covering the image. */
    STOP,
}

/**
 * Decide how to quiet [errorCode] before showing an image.
 *
 * `pause()` is a documented no-op unless the player is STARTED, so quieting a
 * failed instance with `pause()` leaves it holding the surface above the image
 * layer. A backend carrying an error is therefore torn down instead.
 *
 * SCOPE — this was introduced in v1.19.5 as the suspected cause of the field black
 * screen (device and-c937df0cdb). The v1.19.5 field log disproved that: the kernel
 * had gone entirely silent (no `stopped`, no subsequent `loadAndPlay`), which no
 * pause/stop choice can explain. The real cause was a main-thread stall in
 * `setDataSource` — see [RemoteLoadPolicy]. This rule is still correct on its own
 * terms and is kept, but it is not what fixed the black screen.
 */
fun backendQuietAction(errorCode: String?): BackendQuietAction =
    if (errorCode.isNullOrBlank()) BackendQuietAction.PAUSE else BackendQuietAction.STOP
