#!/usr/bin/env bash
#
# qzx_ab_backend.sh — ONE-ACTION A/B of the two video kernels (ExoPlayer vs native
# android.media.MediaPlayer, §backend-ab) on the SAME QZX_C1 box + SAME media
# sample, collecting all evidence into one local folder.
#
# WHY THIS EXISTS: the QZX_C1 / Hi3798MV300 / YunOS 4.4.2 boxes have dropped frames
# / black-screened under the hardware-only ExoPlayer path. v1.14.2 adds a native
# MediaPlayer kernel so we can compare them ON THE REAL BOX. Jay should not have to
# type a dozen adb commands per kernel — this drives both, restarts the app between
# them, waits for the box's own resume_last playback, and pulls the exported
# player.log + a diagnostic bundle + a logcat tail for EACH kernel automatically.
#
# WHAT IT DOES, per kernel (exoplayer, then mediaplayer):
#   1. writes the kernel-override file /data/local/tmp/lmw_video_backend  <-- the
#      ONLY device write (a documented test affordance the app reads at startup;
#      it beats the Settings choice so we don't touch saved config — BackendSelector).
#   2. force-stops + relaunches the kiosk (MainActivity) so it rebuilds the player
#      with that kernel; the box's resume_last replays the last pushed item.
#   3. waits PLAY_SECONDS while it plays.
#   4. pulls the exported player.log (+ rotated .1), a live logcat tail, and the
#      on-box files list into  OUT/<serial>/<kernel>/ .
# Finally it REMOVES the override file and relaunches so the box returns to its
# configured/auto kernel, and prints a side-by-side summary grepped from the logs
# (backend line, prepare/first-frame ms, stalls, dropped frames, errors).
#
# It is READ-ONLY except: (a) the one override file, (b) force-stop/relaunch of our
# own app — both required for the test and both reverted at the end. It never
# installs, uninstalls, reboots, or touches media/config.
#
# USAGE:
#   scripts/qzx_ab_backend.sh [serial ...]
#     no serial  → every attached 'device'
#     serials    → only those boxes
#
# ENV OVERRIDES:
#   PKG            package (default com.jieoz.lanmediawall.player)
#   PLAY_SECONDS   seconds to let each kernel play before pulling logs (default 40)
#   OUT            output dir (default ./qzx_ab_<UTCstamp>)
#   KERNELS        space list to test (default "exoplayer mediaplayer")
#
# REQUIREMENTS: adb on PATH; boxes allow `adb root` (these do by default) so the
#   override file + private player.log are reachable. Without root it still tries
#   `run-as` for the log; the override needs a root-writable /data/local/tmp.
#
# NOTE: not run in CI (no hardware in the container). Lint with:
#   shellcheck scripts/qzx_ab_backend.sh

set -uo pipefail

PKG="${PKG:-com.jieoz.lanmediawall.player}"
PLAY_SECONDS="${PLAY_SECONDS:-40}"
KERNELS="${KERNELS:-exoplayer mediaplayer}"
OVERRIDE="/data/local/tmp/lmw_video_backend"
MAIN="$PKG/$PKG.MainActivity"
LOG_REL="files/logs/player.log"
STAMP="$(date -u +%Y%m%d_%H%M%SZ)"
OUT="${OUT:-./qzx_ab_${STAMP}}"

log()  { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "$1" "$2"; }
info() { log "INFO" "$*"; }
warn() { log "WARN" "$*" >&2; }
err()  { log "FAIL" "$*" >&2; }

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '/^!/d'; exit "${1:-0}"; }
case "${1:-}" in -h|--help) usage 0 ;; esac

command -v adb >/dev/null 2>&1 || { err "adb not on PATH"; exit 1; }

if [ $# -gt 0 ]; then
  DEVICES=("$@")
else
  mapfile -t DEVICES < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
fi
[ "${#DEVICES[@]}" -gt 0 ] || { err "no target devices"; exit 1; }

adbd() { adb -s "$1" "${@:2}"; }

ensure_root() {
  adbd "$1" root >/dev/null 2>&1 || true
  adbd "$1" wait-for-device
  [ "$(adbd "$1" shell id -u 2>/dev/null | tr -d '\r')" = "0" ]
}

# Pull the app-private player.log: direct cat when root, else run-as (debuggable).
pull_player_log() {
  local s="$1" dest="$2"
  adbd "$s" shell "cat /data/data/$PKG/$LOG_REL" 2>/dev/null | tr -d '\r' > "$dest" || true
  if [ ! -s "$dest" ]; then
    adbd "$s" shell "run-as $PKG cat $LOG_REL" 2>/dev/null | tr -d '\r' > "$dest" || true
  fi
  adbd "$s" shell "cat /data/data/$PKG/${LOG_REL}.1" 2>/dev/null | tr -d '\r' > "${dest}.1" || true
}

run_kernel() {
  local s="$1" kernel="$2" dir="$3"
  mkdir -p "$dir"
  info "[$s] === kernel: $kernel ==="
  # 1) select the kernel via the override file (the only device write).
  if ! adbd "$s" shell "echo $kernel > $OVERRIDE" >/dev/null 2>&1; then
    warn "[$s] could not write $OVERRIDE (needs root); skipping $kernel"
    echo "OVERRIDE-WRITE-FAILED" > "$dir/ERROR.txt"
    return 1
  fi
  adbd "$s" shell "cat $OVERRIDE" 2>/dev/null | tr -d '\r' > "$dir/override_readback.txt"
  # 2) restart the kiosk so it rebuilds the player with this kernel.
  adbd "$s" shell "am force-stop $PKG" >/dev/null 2>&1 || true
  sleep 2
  adbd "$s" shell "am start -n $MAIN" >/dev/null 2>&1 || \
    adbd "$s" shell "am start -a android.intent.action.MAIN -c android.intent.category.HOME" >/dev/null 2>&1 || true
  # 3) let it play (box replays last task via resume_last).
  info "[$s]   playing ${PLAY_SECONDS}s on $kernel ..."
  sleep "$PLAY_SECONDS"
  # 4) collect evidence.
  pull_player_log "$s" "$dir/player.log"
  adbd "$s" shell "logcat -d -v time -t 600" 2>/dev/null | tr -d '\r' > "$dir/logcat_tail.txt" || true
  adbd "$s" shell "ls -l /data/data/$PKG/files/logs" 2>/dev/null | tr -d '\r' > "$dir/logs_ls.txt" || true
  adbd "$s" shell "dumpsys meminfo $PKG" 2>/dev/null | tr -d '\r' > "$dir/meminfo.txt" || true
  info "[$s]   collected → $dir"
}

# Grep the comparable numbers out of a pulled player.log for the summary table.
summarize_kernel() {
  local dir="$1" kernel="$2"
  local logf="$dir/player.log"
  if [ ! -s "$logf" ]; then printf '  %-12s (no player.log pulled)\n' "$kernel"; return; fi
  # last backend metrics line the app logged, plus decisive events.
  local ff prep stalls dropped errfirst
  ff="$(grep -c 'first_frame rendered' "$logf" 2>/dev/null || echo 0)"
  prep="$(grep -c 'prepared\|state READY' "$logf" 2>/dev/null || echo 0)"
  stalls="$(grep -c 'buffering_start\|state BUFFERING' "$logf" 2>/dev/null || echo 0)"
  dropped="$(grep -c 'dropped_frames' "$logf" 2>/dev/null || echo 0)"
  errfirst="$(grep -m1 'error ' "$logf" 2>/dev/null | cut -c1-80)"
  printf '  %-12s first_frames=%s prepares=%s buffering_events=%s dropped_lines=%s\n' \
    "$kernel" "$ff" "$prep" "$stalls" "$dropped"
  [ -n "$errfirst" ] && printf '                 first_error: %s\n' "$errfirst"
}

overall=0
for s in "${DEVICES[@]}"; do
  info "[$s] starting A/B (kernels: $KERNELS)"
  if ! ensure_root "$s"; then
    warn "[$s] not rooted — override write / private-log pull may fail"
  fi
  sdir="$OUT/$s"
  mkdir -p "$sdir"
  adbd "$s" shell "getprop ro.product.model; getprop ro.build.version.release" 2>/dev/null \
    | tr -d '\r' > "$sdir/device.txt" || true
  for k in $KERNELS; do
    run_kernel "$s" "$k" "$sdir/$k" || overall=1
  done
  # revert: remove the override so the box returns to its configured/auto kernel.
  adbd "$s" shell "rm -f $OVERRIDE" >/dev/null 2>&1 || true
  adbd "$s" shell "am force-stop $PKG" >/dev/null 2>&1 || true
  sleep 1
  adbd "$s" shell "am start -n $MAIN" >/dev/null 2>&1 || true
  info "[$s] override removed; box restored to configured kernel"
done

echo
echo "================ QZX A/B BACKEND SUMMARY ================"
echo "output: $OUT"
for s in "${DEVICES[@]}"; do
  echo "device $s:"
  for k in $KERNELS; do summarize_kernel "$OUT/$s/$k" "$k"; done
done
echo "  full evidence per kernel under the paths above (player.log, logcat_tail,"
echo "  meminfo, override_readback). Compare first_frame latency, buffering/stall"
echo "  events, dropped_frames and any 'error' lines between the two kernels."
echo "========================================================"
exit "$overall"
