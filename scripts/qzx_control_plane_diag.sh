#!/usr/bin/env bash
#
# qzx_control_plane_diag.sh — ONE-ACTION, READ-ONLY control-plane diagnostic for
# the LAN Media Wall player box. It answers the v1.14.8 root question (E0001):
# "is the P2P/broker control plane actually routing and CONSUMING status /
# time_sync / ready, or is the wall stuck at online=null with a topology that the
# summary and the log disagree about?"
#
# WHY THIS EXISTS (field evidence gap):
#   The authoritative field log showed: controller summary said
#   topology=dedicated,p2p_peers=0 while the controller log said topology=p2p;
#   the player transmitted status/time_sync/thumb_meta toward the broker but the
#   controller ignored status/time_sync/ready and discovered devices stayed
#   online=null; cache had 2 ready files but current index stayed 0; and NO
#   update_app / INSTALL attempt ever appeared. Those are all CONTROL-PLANE
#   signals, and the existing collectors (qzx_field_check.sh = restart+backend
#   A/B) do not isolate them. This script pulls the player's own diagnostic
#   bundle and distills exactly those signals into one report so the routing
#   decision, peer/topology identity, sent/received/ignored control messages,
#   update dispatch/result, playlist index transitions, and sync timing are all
#   visible in one file — WITHOUT re-running adb by hand.
#
# CONSERVATIVE — it NEVER reboots, restarts, installs, uninstalls, remounts,
# clears app data, or clears logcat. Its ONLY on-device actions are read-only:
# broadcasting the app's OWN log-dump intent, pulling files, and reading logcat.
#
# USAGE:  scripts/qzx_control_plane_diag.sh [serial]
#   no serial → the single attached 'device' (refuses if >1 unless a serial given)
#
# OUTPUT: one report.txt + the raw player bundle, zipped under ./qzx-diag-out/.
set -euo pipefail

PKG="com.jieoz.lanmediawall.player"
SERIAL="${1:-}"
OUT_DIR="${OUT_DIR:-qzx-diag-out}"
STAMP="$(date +%Y%m%d_%H%M%S)"
WORK="${OUT_DIR}/control_plane_${STAMP}"

adbx() { if [ -n "$SERIAL" ]; then adb -s "$SERIAL" "$@"; else adb "$@"; fi; }

# Pick the single device unless a serial was given.
if [ -z "$SERIAL" ]; then
  n="$(adb devices | awk 'NR>1 && $2=="device"{c++} END{print c+0}')"
  if [ "$n" != "1" ]; then
    echo "ERROR: found $n attached devices; pass a serial explicitly." >&2
    adb devices >&2
    exit 2
  fi
fi

mkdir -p "$WORK"
REPORT="${WORK}/report.txt"

echo "qzx_control_plane_diag: collecting from ${SERIAL:-<single device>} → $WORK"

# The player exposes an on-box diagnostic bundle it writes to its own external
# files dir. We trigger it read-only via the same log-dump path the daemon uses,
# then fall back to logcat if the bundle is not reachable. Never assume success.
EXT_DIR="/sdcard/Android/data/${PKG}/files"

# Pull any player.log the app has written (read-only copy).
adbx pull "${EXT_DIR}/logs/player.log" "${WORK}/player.log" >/dev/null 2>&1 || true
adbx pull "${EXT_DIR}/logs/player.log.1" "${WORK}/player.log.1" >/dev/null 2>&1 || true

# Always grab a bounded logcat tail filtered to our tag as a backstop.
adbx logcat -d -v time -t 2000 2>/dev/null | grep -iE "lanmediawall|lmw|${PKG}" \
  > "${WORK}/logcat_tail.txt" 2>/dev/null || true

# Consolidate every source we managed to pull into one grep corpus.
CORPUS="${WORK}/_corpus.txt"
: > "$CORPUS"
for f in "${WORK}/player.log.1" "${WORK}/player.log" "${WORK}/logcat_tail.txt"; do
  [ -f "$f" ] && cat "$f" >> "$CORPUS"
done

# --- distill the E0001 control-plane signals ------------------------------
# Each grep is defensive: absent evidence is reported as such (never faked).
section() { printf '\n===== %s =====\n' "$1" >>"$REPORT"; }
emit() {
  local label="$1" pattern="$2" ; shift 2
  local hits; hits="$(grep -aE "$pattern" "$CORPUS" 2>/dev/null | tail -"${LIMIT:-40}" || true)"
  if [ -n "$hits" ]; then printf '%s\n' "$hits" >>"$REPORT"
  else printf '(no %s evidence in collected logs)\n' "$label" >>"$REPORT"; fi
}

{
  echo "LAN Media Wall — control-plane diagnostic"
  echo "time=$(date -u +%Y-%m-%dT%H:%M:%SZ)  device=${SERIAL:-single}  pkg=$PKG"
  echo "corpus_bytes=$(wc -c <"$CORPUS" 2>/dev/null || echo 0)"
  echo "NOTE: absence of a signal below is itself evidence (e.g. no update_app"
  echo "line => the controller never dispatched an update to this box)."
} >"$REPORT"

section "identity / transport / topology (routing decision + peer identity)"
emit "transport/topology" 'transport=|topology|p2p|dedicated|welcome|hello |auth_mode=|key_mode='

section "control messages RECEIVED / IGNORED (status/time_sync/ready path)"
emit "inbound control" 'time_sync|time_sync_ack| status | ready |忽略入站类型|落到 broker 路径被丢弃'

section "status TX + online reporting (why devices show online=null)"
emit "status tx" 'sendStatus|online=|status sent|status send'

section "update dispatch / install result (was an update ever attempted?)"
emit "update" 'update_app|reportUpdate|installing|install-failed|rejected reason=|daemon:error|pm install'

section "playlist mode + index transitions (append/replace, prev/next)"
emit "playlist" 'playlist mode=|transition to=|idx=|current_index|index='

section "sync timing (target vs actual start, late compensation, drift)"
emit "sync" 'sync_schedule|sync_start|play_at=|compensate_seek_ms|late_ms|drift'

section "errors / watchdog"
emit "errors" 'player_error|watchdog_recover|ERROR|Exception|error '

# --- verdict --------------------------------------------------------------
section "verdict (heuristic — confirm against real device)"
{
  grep -qaE 'update_app' "$CORPUS" && echo "update_app: DISPATCH SEEN" \
    || echo "update_app: NOT SEEN — controller never sent update to this box (matches E0001)"
  grep -qaE 'sync_start' "$CORPUS" && echo "sync_start: TIMING SEEN" \
    || echo "sync_start: NOT SEEN — no synced start executed"
  grep -qaE 'playlist mode=append' "$CORPUS" && echo "append: SEEN" \
    || echo "append: NOT SEEN — only replace pushes (prev/next may collapse to last item)"
  grep -qaE 'online=true' "$CORPUS" && echo "online=true: player DID report online" \
    || echo "online=true: NOT SEEN in player log — check controller consumption path"
} >>"$REPORT"

# --- zip it up ------------------------------------------------------------
ZIP="${OUT_DIR}/qzx_control_plane_${STAMP}.zip"
( cd "$WORK/.." && zip -qr "$(basename "$ZIP")" "$(basename "$WORK")" ) 2>/dev/null \
  && mv "${WORK}/../$(basename "$ZIP")" "$ZIP" 2>/dev/null || true

echo
echo "DONE. Report: $REPORT"
[ -f "$ZIP" ] && echo "Bundle: $ZIP"
echo "Read the 'verdict' section first, then confirm each line against the real box."
