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
 * Field defect (v1.19.4, device and-c937df0cdb): music was loaded from a stale
 * controller URL (`http://10.10.8.161:40571/...`, a controller that no longer
 * exists), MediaPlayer reported `mp_error what=1`, and the backend latched ERROR.
 * Switching 音乐 → 图片 then called `pause()`, which is a documented no-op unless
 * the player is STARTED — so the failed instance kept its surface on top and the
 * operator saw a black screen. The watchdog could not clear it either: it calls
 * `resumeLast()`, which lands back on the same `pause()`.
 *
 * A backend carrying an error must therefore be stopped, not paused.
 */
fun backendQuietAction(errorCode: String?): BackendQuietAction =
    if (errorCode.isNullOrBlank()) BackendQuietAction.PAUSE else BackendQuietAction.STOP
