#!/usr/bin/env bash
#
# qzx_field_check.sh — ONE-ACTION real-device field check for QZX_C1 / YunOS 4.4.2:
#
#   (A) RESTART PROOF: prove the app-only restart (RESTART_APP) actually brings the
#       Player back AUTOMATICALLY within a bounded timeout. The v1.14.3 field failure
#       was that force-stop landed but the relaunch did not reliably take, leaving a
#       black kiosk until a manual explicit `am start`. This drives the REAL daemon
#       worker via the AUTHORIZED root path (`<daemon> -restart`, which runs the same
#       verify-and-retry state machine the socket RESTART_APP forks) and then polls
#       for the Player process to reappear, timing it. It also pulls the daemon's
#       persistent restart evidence log.
#
#   (B) BACKEND A/B: run both video kernels (ExoPlayer vs native MediaPlayer) on the
#       SAME box + SAME media (the box replays its last pushed item via resume_last)
#       for >= PLAY_SECONDS each, collecting player.log/logcat/meminfo/gfxinfo/media
#       evidence, then a per-kernel summary (dropped-frame totals/rate where the log
#       supports it, first-frame/prepare/stall/error/GC, and an explicit
#       playback-never-started failure).
#
# Produces ONE zip + a concise report.txt.
#
# CONSERVATIVE — it NEVER reboots, uninstalls, remounts, clears app data, clears
# logcat, or deletes broadly. Its ONLY device writes are the documented A/B override
# file (/data/local/tmp/lmw_video_backend) and restarting our OWN app — both reverted
# at the end, including on error/interrupt.
#
# WHY the daemon `-restart` path (not a re-implemented shell chain): the daemon socket
# authorizes by SO_PEERCRED against the Player uid, so adb/root cannot impersonate the
# app over the socket. To exercise the ACTUAL daemon restart worker (not a fake), the
# daemon exposes a root-only `-restart` CLI that runs the same state machine inline and
# exits 0/1 — reachable only by a caller that is already root, exactly like `-probe`.
# Production socket auth is NOT weakened. If the daemon binary is not found, the script
# falls back to a clearly-labeled manual controller-UI restart checkpoint.
#
# USAGE:  scripts/qzx_field_check.sh [serial]
#   no serial → the single attached 'device' (refuses if >1 unless a serial is given)
#
# ENV OVERRIDES:
#   PKG              package (default com.jieoz.lanmediawall.player)
#   PLAY_SECONDS     seconds each kernel plays before pulling logs (default 60)
#   RESTART_TIMEOUT  seconds to wait for the Player to auto-return (default 30)
#   KERNELS          kernels to A/B (default "exoplayer mediaplayer")
#   DAEMON           on-box daemon path (default /system/xbin/lmw_root_daemon)
#   OUT              output dir (default ./qzx_field_<serial>_<UTCstamp>)
#   SKIP_AB=1        restart proof only; SKIP_RESTART=1  A/B only
#
# NOT run in CI (no hardware). Lint with: shellcheck scripts/qzx_field_check.sh

set -uo pipefail

PKG="${PKG:-com.jieoz.lanmediawall.player}"
PLAY_SECONDS="${PLAY_SECONDS:-60}"
RESTART_TIMEOUT="${RESTART_TIMEOUT:-30}"
KERNELS="${KERNELS:-exoplayer mediaplayer}"
DAEMON="${DAEMON:-/system/xbin/lmw_root_daemon}"
OVERRIDE="/data/local/tmp/lmw_video_backend"
RESTART_LOG="/data/local/tmp/lmw_restart.log"
COMPONENT="$PKG/$PKG.MainActivity"
LOG_REL="files/logs/player.log"
STAMP="$(date -u +%Y%m%d_%H%M%SZ)"

log()  { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "$1" "$2"; }
info() { log "INFO" "$*"; }
warn() { log "WARN" "$*" >&2; }
err()  { log "FAIL" "$*" >&2; }
usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '/^!/d'; exit "${1:-0}"; }
case "${1:-}" in -h|--help) usage 0 ;; esac

command -v adb >/dev/null 2>&1 || { err "adb not on PATH"; exit 1; }

# ---- device selection: exactly one, or an explicit serial -------------------
SERIAL="${1:-}"
if [ -z "$SERIAL" ]; then
  mapfile -t _devs < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
  if [ "${#_devs[@]}" -eq 0 ]; then err "no attached 'device' found"; adb devices >&2; exit 1; fi
  if [ "${#_devs[@]}" -gt 1 ]; then
    err "more than one device; pass an explicit serial:"; adb devices >&2; exit 2
  fi
  SERIAL="${_devs[0]}"
fi
OUT="${OUT:-./qzx_field_${SERIAL}_${STAMP}}"

adbd()  { adb -s "$SERIAL" "$@"; }
ash()   { adb -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }

ensure_root() {
  adbd root >/dev/null 2>&1 || true
  adbd wait-for-device
  [ "$(ash id -u)" = "0" ]
}

# Run a shell command as root on-box: adbd is already root after `adb root` on these
# boxes; otherwise route through `su 0`. Used ONLY for our own daemon/app control.
asroot() { # $*: command
  if [ "$(ash id -u)" = "0" ]; then ash "$*"; else ash "su 0 $*"; fi
}

player_pid() { ash "ps | grep -w $PKG | grep -v grep | awk '{print \$2}' | head -1"; }
uptime_s()   { ash cat /proc/uptime | awk '{printf "%d", $1}'; }
version_name(){ ash "dumpsys package $PKG | grep -m1 versionName" | sed -n 's/.*versionName=//p'; }
version_code(){ ash "dumpsys package $PKG | grep -m1 versionCode" | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p'; }
resumed_activity(){
  ash "dumpsys activity activities | grep -m1 -i 'mResumedActivity\|ResumedActivity'" \
    || ash "dumpsys window windows | grep -m1 -i mCurrentFocus"
}
wifi_state(){
  echo "interface=$(ash getprop wifi.interface)"
  echo "wpa_supplicant=$(ash getprop init.svc.wpa_supplicant)"
  echo "dhcp_wlan0=$(ash getprop dhcp.wlan0.ipaddress)"
  ash "ip addr show wlan0 2>/dev/null || ifconfig wlan0 2>/dev/null" | sed -n '1,6p'
}
daemon_probe(){ asroot "$DAEMON -probe"; }
daemon_present(){ [ "$(ash "[ -x $DAEMON ] && echo yes")" = "yes" ]; }

# ---- cleanup: always restore the override + relaunch, even on error/Ctrl-C ---
CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return; CLEANED=1
  info "restoring: removing A/B override + relaunching configured kernel"
  ash "rm -f $OVERRIDE" >/dev/null 2>&1 || true
  asroot "$DAEMON -restart" >/dev/null 2>&1 \
    || ash "am start -n $COMPONENT -f 0x10200000" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# ---- (A) RESTART PROOF -------------------------------------------------------
restart_proof() {
  local dir="$OUT/restart" ; mkdir -p "$dir"
  info "=== (A) restart proof (timeout ${RESTART_TIMEOUT}s) ==="
  {
    echo "before_uptime_s=$(uptime_s)"
    echo "before_player_pid=$(player_pid)"
    echo "before_versionName=$(version_name) versionCode=$(version_code)"
    echo "before_resumed=$(resumed_activity)"
    echo "--- wifi before ---"; wifi_state
    echo "--- daemon probe ---"; daemon_probe
  } > "$dir/before.txt" 2>&1

  local before_pid; before_pid="$(player_pid)"
  local trigger="unavailable" daemon_rc=""
  if daemon_present; then
    info "triggering RESTART via authorized daemon worker ($DAEMON -restart)"
    trigger="daemon"
    # The daemon's -restart runs the SAME verify-and-retry worker the socket
    # RESTART_APP forks, and its EXIT CODE is the two-signal full-recovery verdict
    # (0 == process up AND activity resumed). Unreportable activity fails closed.
    asroot "$DAEMON -restart" > "$dir/restart_trigger.txt" 2>&1; daemon_rc=$?
    echo "daemon_exit=$daemon_rc" >> "$dir/restart_trigger.txt"
  else
    warn "daemon binary not found at $DAEMON — cannot drive the real worker over ADB."
    warn "Restart proof is FAIL/INCONCLUSIVE; no manual action can substitute for worker evidence."
    echo "FAIL: daemon absent; real RESTART_APP worker was not executed" > "$dir/restart_trigger.txt"
  fi

  # Poll for the Player PROCESS to return within the bounded timeout (a NEW pid).
  local t=0 back_pid="" process_up=0
  while [ "$t" -lt "$RESTART_TIMEOUT" ]; do
    back_pid="$(player_pid)"
    if [ -n "$back_pid" ] && [ "$back_pid" != "$before_pid" ]; then process_up=1; break; fi
    sleep 2; t=$((t+2))
  done

  # SECOND signal (E0001): is OUR activity actually frontmost, or is the process up
  # behind the launcher (black kiosk)? Evaluate the resumed/focus line, do not just
  # capture it. Tri-state: yes / no / unsupported (box can't report it).
  local resumed_line act
  resumed_line="$(resumed_activity)"
  if echo "$resumed_line" | grep -q "$PKG/"; then act="yes"
  elif [ -n "$resumed_line" ]; then act="no"
  else act="unsupported"; fi

  # Full recovery = process up AND activity resumed. Unsupported evidence is
  # inconclusive/failure, never a process-only pass.
  # The daemon's own exit code is authoritative when it drove the restart; the
  # harness signals are an independent cross-check recorded alongside.
  local recovered=0
  if [ "$trigger" = "daemon" ] && [ "$daemon_rc" = "0" ] &&
     [ "$process_up" = "1" ] && [ "$act" = "yes" ]; then
    recovered=1
  fi

  {
    echo "trigger=$trigger daemon_exit=${daemon_rc:-n/a}"
    echo "before_player_pid=$before_pid"
    echo "after_player_pid=$back_pid"
    echo "process_up_within_${RESTART_TIMEOUT}s=$process_up elapsed_s=$t"
    echo "activity_resumed=$act (yes=our component frontmost, no=other app frontmost, unsupported=box can't report)"
    echo "resumed_line: $resumed_line"
    echo "fully_recovered=$recovered"
    echo "after_uptime_s=$(uptime_s)   (must NOT reset — a reset means a reboot happened)"
    echo "--- wifi after ---"; wifi_state
  } > "$dir/after.txt" 2>&1

  # Pull the daemon's persistent restart evidence log (bounded; may not exist yet).
  ash "cat $RESTART_LOG"      > "$dir/lmw_restart.log"   2>/dev/null || true
  ash "cat ${RESTART_LOG}.1"  > "$dir/lmw_restart.log.1" 2>/dev/null || true
  adbd shell "logcat -d -v time -t 400" 2>/dev/null | tr -d '\r' > "$dir/logcat_tail.txt" || true

  # PASS requires BOTH signals — a process that came back behind the launcher is a
  # PARTIAL failure (the field bug), never a PASS. Process-only is never full recovery.
  if [ "$trigger" = "unavailable" ]; then
    RESTART_RESULT="FAIL/INCONCLUSIVE: daemon absent; real RESTART_APP worker was not executed."
    err "$RESTART_RESULT"
  elif [ "$daemon_rc" != "0" ]; then
    RESTART_RESULT="FAIL: daemon restart worker exited $daemon_rc; later process/activity state cannot overwrite that failure."
    err "$RESTART_RESULT"
  elif [ "$recovered" = "1" ]; then
    RESTART_RESULT="PASS: Player fully recovered in ${t}s — process up (pid $before_pid -> $back_pid) AND our activity resumed, no manual start."
    info "$RESTART_RESULT"
  elif [ "$process_up" = "1" ]; then
    RESTART_RESULT="PARTIAL/FAIL: process returned (pid $before_pid -> $back_pid) but our activity is NOT frontmost (activity_resumed=$act) — kiosk likely black. See restart/lmw_restart.log."
    err "$RESTART_RESULT"
  else
    RESTART_RESULT="FAIL: Player process did NOT auto-return within ${RESTART_TIMEOUT}s (trigger=$trigger). See restart/lmw_restart.log."
    err "$RESTART_RESULT"
  fi
}

# ---- (B) BACKEND A/B ---------------------------------------------------------
pull_player_log() { # $1 dest
  ash "cat /data/data/$PKG/$LOG_REL"      > "$1"     || true
  [ -s "$1" ] || ash "run-as $PKG cat $LOG_REL" > "$1" || true
  ash "cat /data/data/$PKG/${LOG_REL}.1"  > "${1}.1" 2>/dev/null || true
}

run_kernel() { # $1 kernel  $2 dir
  local kernel="$1" dir="$2" ; mkdir -p "$dir"
  info "--- kernel: $kernel (play ${PLAY_SECONDS}s) ---"
  if ! ash "echo $kernel > $OVERRIDE" >/dev/null 2>&1; then
    warn "could not write $OVERRIDE (needs root); skipping $kernel"
    echo "OVERRIDE-WRITE-FAILED" > "$dir/ERROR.txt"; return 1
  fi
  ash "cat $OVERRIDE" > "$dir/override_readback.txt"
  # restart via the real daemon worker (falls back to explicit am start).
  asroot "$DAEMON -restart" >/dev/null 2>&1 \
    || { ash "am force-stop $PKG"; sleep 1; ash "am start -n $COMPONENT -f 0x10200000"; } >/dev/null 2>&1 || true
  sleep "$PLAY_SECONDS"
  pull_player_log "$dir/player.log"
  adbd shell "logcat -d -v time -t 800" 2>/dev/null | tr -d '\r' > "$dir/logcat_tail.txt" || true
  ash "dumpsys meminfo $PKG"            > "$dir/meminfo.txt"  || true
  ash "dumpsys gfxinfo $PKG"            > "$dir/gfxinfo.txt"  || true
  ash "dumpsys media.player"            > "$dir/media_player.txt" 2>/dev/null || true
  ash "ls -l /data/data/$PKG/files/logs"> "$dir/logs_ls.txt"  || true
  info "collected -> $dir"
}

# Summarize one kernel from its pulled player.log. Emits KEY=VALUE lines so the
# report is greppable; parses the authoritative `backend_metrics=...` line the app
# logs (BackendMetrics.summary) for dropped_frames / stalls / errors / first_frame,
# and derives an Exo dropped-frame RATE from the per-event `dropped_frames count=..`
# lines when present. MediaPlayer reports dropped_frames=n/a (NOT 0). If the log
# shows no first frame AND no prepared/ready, it is flagged PLAYBACK-NEVER-STARTED.
summarize_kernel() { # $1 dir  $2 kernel  -> writes to stdout
  local dir="$1" kernel="$2" logf="$1/player.log"
  echo "[$kernel]"
  if [ ! -s "$logf" ]; then echo "  player_log=absent (could not pull)"; return; fi
  # last authoritative metrics line the app emitted.
  local metrics; metrics="$(grep 'backend_metrics=' "$logf" | tail -1)"
  local ff_lines prep_lines drop_events drop_total frames_total gc first_err
  ff_lines="$(grep -c 'first_frame rendered' "$logf")"
  prep_lines="$(grep -c 'prepared\|state READY\|onPrepared' "$logf")"
  drop_events="$(grep -c 'dropped_frames count=' "$logf")"
  # sum ExoPlayer per-event dropped counts + elapsed frames if present.
  drop_total="$(grep 'dropped_frames count=' "$logf" | sed -n 's/.*count=\([0-9]*\).*/\1/p' | awk '{s+=$1} END{print s+0}')"
  frames_total="$(grep 'dropped_frames count=' "$logf" | sed -n 's/.*elapsed_ms=\([0-9]*\).*/\1/p' | awk '{s+=$1} END{print s+0}')"
  gc="$(grep -c 'GC_\|dalvikvm.*GC\|Background.*concurrent.*GC' "$logf")"
  first_err="$(grep -m1 -i 'error \|exception' "$logf" | cut -c1-100)"

  echo "  first_frame_events=$ff_lines prepared_events=$prep_lines stall_gc_lines=$gc"
  if [ -n "$metrics" ]; then
    echo "  metrics: $(echo "$metrics" | sed 's/.*backend_metrics=//')"
    local mdrop; mdrop="$(echo "$metrics" | sed -n 's/.*dropped_frames=\([^ ]*\).*/\1/p')"
    if [ "$mdrop" = "n/a" ]; then
      echo "  dropped_frames=n/a (kernel has no dropped-frame callback — NOT zero)"
    else
      echo "  dropped_frames_total=${mdrop:-?} (from backend_metrics)"
    fi
  else
    echo "  metrics: (no backend_metrics line — older build or never logged)"
  fi
  if [ "$drop_events" -gt 0 ]; then
    echo "  dropped_frame_report_events=$drop_events summed_dropped=$drop_total"
  fi
  [ -n "$first_err" ] && echo "  first_error: $first_err"
  # playback-never-started detector.
  if [ "$ff_lines" -eq 0 ] && [ "$prep_lines" -eq 0 ]; then
    echo "  PLAYBACK-NEVER-STARTED: no first_frame and no prepared/ready in log — A/B for"
    echo "    this kernel is INCONCLUSIVE (check that the box has a resume_last item)."
  fi
}

# ---- main --------------------------------------------------------------------
mkdir -p "$OUT"
info "device $SERIAL — field check → $OUT"
ensure_root || warn "device not rooted — override write / private-log pull / daemon -restart may fail"
{
  echo "serial=$SERIAL stamp=$STAMP"
  echo "model=$(ash getprop ro.product.model) release=$(ash getprop ro.build.version.release)"
  echo "versionName=$(version_name) versionCode=$(version_code)"
  echo "daemon=$DAEMON present=$(daemon_present && echo yes || echo no)"
} > "$OUT/device.txt" 2>&1

RESTART_RESULT="skipped"
[ "${SKIP_RESTART:-0}" = "1" ] || restart_proof

if [ "${SKIP_AB:-0}" != "1" ]; then
  info "=== (B) backend A/B (kernels: $KERNELS) ==="
  for k in $KERNELS; do run_kernel "$k" "$OUT/$k"; done
fi

# cleanup (restore) runs via trap on EXIT.

# ---- report.txt + zip --------------------------------------------------------
{
  echo "==================== QZX FIELD CHECK REPORT ===================="
  echo "serial=$SERIAL  stamp=$STAMP  pkg=$PKG"
  echo
  echo "(A) RESTART PROOF"
  echo "  $RESTART_RESULT"
  echo "  evidence: restart/before.txt restart/after.txt restart/lmw_restart.log restart/logcat_tail.txt"
  echo "  NOTE: after_uptime must be >= before_uptime — a reset would mean a REBOOT (Wi-Fi risk)."
  echo
  echo "(B) BACKEND A/B (same box + same resume_last media; >= ${PLAY_SECONDS}s each)"
  if [ "${SKIP_AB:-0}" = "1" ]; then echo "  skipped (SKIP_AB=1)"; else
    for k in $KERNELS; do summarize_kernel "$OUT/$k" "$k"; done
    echo
    echo "  Compare between kernels: first_frame latency, stalls, dropped_frames"
    echo "  (Exo real number vs MediaPlayer n/a), errors, GC pressure. resume_last"
    echo "  ASSUMPTION is explicit above; a PLAYBACK-NEVER-STARTED flag = inconclusive."
  fi
  echo "==============================================================="
} | tee "$OUT/report.txt"

ZIP="${OUT}.zip"
if command -v zip >/dev/null 2>&1; then
  ( cd "$(dirname "$OUT")" && zip -qr "$(basename "$ZIP")" "$(basename "$OUT")" ) && info "zip → $ZIP"
else
  warn "zip not on PATH — send the folder $OUT instead"
fi
info "DONE. report: $OUT/report.txt"
