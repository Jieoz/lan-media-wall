package com.jieoz.lanmediawall.player

/**
 * Pure, Android-free matcher for the hidden kiosk-exit backdoor triggers (§debug
 * backdoor). Extracted so the timing/sequence logic is unit-testable on the JVM
 * — [MainActivity] feeds it real touch/key events, this decides when to prompt
 * for the PIN.
 *
 * Two independent channels so both touch boxes and remote-only boxes can escape:
 *  - **Tap channel**: N quick taps in the screen's top-left hot-zone within a
 *    sliding window (default 7 taps / 3s). The Activity gates *where* the tap
 *    landed; this only counts *when* they arrive.
 *  - **Key channel**: a D-pad sequence (default UP, UP, DOWN, DOWN). A gap
 *    longer than the timeout, or a key not matching the next expected step,
 *    resets the progress (a fresh matching key restarts at step 1).
 *
 * Both channels reset their own progress after a successful match so the next
 * attempt starts clean.
 */
class ExitGestureDetector(
    private val tapCountRequired: Int = 7,
    private val tapWindowMs: Long = 3_000,
    private val keySequence: IntArray = intArrayOf(
        KEYCODE_DPAD_UP, KEYCODE_DPAD_UP, KEYCODE_DPAD_DOWN, KEYCODE_DPAD_DOWN,
    ),
    private val keyTimeoutMs: Long = 3_000,
) {
    private val tapTimes = ArrayDeque<Long>()
    private var keyProgress = 0
    private var lastKeyMs = 0L

    /** Record a hot-zone tap at [nowMs]; true when the window holds enough. */
    fun onHotZoneTap(nowMs: Long): Boolean {
        tapTimes.addLast(nowMs)
        // drop taps outside the sliding window
        while (tapTimes.isNotEmpty() && nowMs - tapTimes.first() > tapWindowMs) {
            tapTimes.removeFirst()
        }
        if (tapTimes.size >= tapCountRequired) {
            tapTimes.clear()
            return true
        }
        return false
    }

    /** Feed a key code at [nowMs]; true when the full sequence just completed. */
    fun onKey(keyCode: Int, nowMs: Long): Boolean {
        // timeout since the last accepted step → start over
        if (keyProgress > 0 && nowMs - lastKeyMs > keyTimeoutMs) {
            keyProgress = 0
        }
        if (keyCode == keySequence[keyProgress]) {
            keyProgress++
            lastKeyMs = nowMs
            if (keyProgress >= keySequence.size) {
                keyProgress = 0
                return true
            }
        } else {
            // mismatched key: restart, but honour it as a possible new step-1.
            keyProgress = if (keyCode == keySequence[0]) {
                lastKeyMs = nowMs
                1
            } else {
                0
            }
        }
        return false
    }

    /** Test/utility: forget any in-progress taps and key steps. */
    fun reset() {
        tapTimes.clear()
        keyProgress = 0
        lastKeyMs = 0L
    }

    companion object {
        // Mirror android.view.KeyEvent constants so this stays Android-free.
        const val KEYCODE_DPAD_UP = 19
        const val KEYCODE_DPAD_DOWN = 20
    }
}
