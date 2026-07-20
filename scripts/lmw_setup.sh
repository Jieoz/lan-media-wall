#!/system/bin/sh
# ===========================================================================
#  lmw_setup.sh — ONE ON-BOX script that does EVERYTHING for a LAN-Media-Wall
#  kiosk on YunOS/AliOS 4.4.2 (QZX_C1, Hi3798MV300, root adb):
#     1. install / upgrade the media-wall player (from the pushed APK)
#     2. install + start the root DAEMON (lmw_root_daemon) and a cold-boot hook,
#        then verify it over its own local-socket PROBE protocol
#     3. prime autostart (stopped-state lift)
#     4. DISABLE EVERYTHING except the media wall + the OS essentials it needs
#     5. make the player the default HOME so the box boots straight into it
#
#  It replaces the old lmw_provision.sh + separate lmw_clean.sh: one command,
#  one reboot bridged by the PC bat.
#
#  Runs INSIDE the box (toybox sh). Because installing an APK forces a reboot
#  (which kills the running shell), it is a TWO-PHASE state machine: run the
#  SAME command, it advances one phase per run via /data/local/tmp/lmw_phase,
#  until it prints "SETUP COMPLETE". The PC bat (lmw_setup.bat) bridges the
#  reboot for you so from your PC it is a single command.
#
#  FLAGS (optional):
#     FORCE     clean reinstall (uninstall+wipe first) — for signature-mismatch
#               upgrades KitKat would otherwise reject
#     NOCLEAN   install/upgrade only, do NOT disable other apps
#     KEEPDEBUG keep the file manager + remote helper (com.xiaobaifile.tv,
#               com.wukongtv.wkhelper, com.explorer) for debugging
#     NOUNINST  disable everything but do NOT uninstall /data junk (default
#               DOES uninstall user-installed junk from /data/app)
#
#  toybox-safe: only grep/ls/cat/pm/am/dumpsys/getprop/cp/chmod/chown/rm/sync
#  — no sed/head/which/printf/tr. Package matching uses a LEADING ^package:
#  anchor only (YunOS emits a trailing CR; a trailing $ anchor never matches).
# ===========================================================================

PKG=com.jieoz.lanmediawall.player
MAIN=$PKG/$PKG.MainActivity
APK_SRC=/data/local/tmp/lmw_player.apk
DST=/data/app/$PKG-1.apk
PHASE=/data/local/tmp/lmw_phase
BEFORE_FILE=/data/local/tmp/lmw_before_version
# Root DAEMON (replaces the old setuid lmw_root_helper — a setuid bit is IGNORED
# under zygote no_new_privs on these boxes, so the only design that works is a
# process started AS root that stays root and exposes a restricted local socket).
DAEMON_SRC=/data/local/tmp/lmw_root_daemon.new
DAEMON_DST=/system/xbin/lmw_root_daemon
DAEMON_BACKUP=/system/xbin/lmw_root_daemon.setup-backup
# Root-owned file holding the single authorized Player uid (SO_PEERCRED check).
# Matches LMW_UID_FILE in lmw_root_daemon.c.
DAEMON_UID=/data/local/tmp/lmw_root_daemon.uid
# Cold-boot hook: preferred ROM-supported init.d, else install-recovery.sh iff
# the ROM demonstrably runs it. Matches names documented in QZX-KIOSK-TOOLS.md.
INITD_DIR=/system/etc/init.d
INITD_HOOK=/system/etc/init.d/99lmwdaemon
RECOVERY_HOOK=/system/etc/install-recovery.sh
COMPLETE=/data/local/tmp/lmw_setup_complete

# ---------------------------------------------------------------------------
# CLEANUP TARGET POLICY  —  "box is ONLY a media wall"
# ---------------------------------------------------------------------------
# Strategy: disable EVERY third-party + non-essential OEM app. We build the
# kill list dynamically from `pm list packages` MINUS a hard whitelist of OS
# essentials + the player. This way NEW junk on future boxes is caught too,
# without ever touching a package that would brick the box.
#
# HARD WHITELIST — never disabled/uninstalled (bricks the box or breaks the
# media wall itself). Everything NOT in here gets disabled.
WHITELIST="$PKG \
android \
com.android.systemui \
com.android.settings \
com.cos.settings \
com.android.packageinstaller \
com.android.shell \
com.android.defcontainer \
com.android.inputdevices \
com.hisilicon.android.inputmethod.remote \
com.android.providers.media \
com.android.providers.settings \
com.android.providers.downloads \
com.android.providers.downloads.ui \
com.android.externalstorage \
com.android.sharedstoragebackup \
com.android.keychain \
com.android.certinstaller \
com.android.backupconfirm \
com.android.location.fused \
com.android.pacprocessor \
com.android.proxyhandler \
com.android.bluetooth \
com.hisilicon.android.hiRMService \
com.android.provision \
com.android.tv.factorytest \
com.svox.pico"
# NOTE: com.youku.taitan.tv (stock youku launcher) is intentionally NOT in the
# whitelist — it is disabled, and the player's MainActivity (which declares
# category.HOME, v1.13.7+) becomes the sole HOME candidate instead.
# com.svox.pico (TTS) kept to avoid any TTS-dependent boot hiccup; harmless.

# Packages that live in /data/app and can actually be uninstalled (else disable).
# Built dynamically too: anything under /data/app that isn't the player.

# ---- parse flags ----------------------------------------------------------
DO_CLEAN=1; DO_FORCE=0; DO_UNINST=1; KEEP_DEBUG=0
for a in "$@"; do
  [ "$a" = "NOCLEAN" ]   && DO_CLEAN=0
  [ "$a" = "FORCE" ]     && DO_FORCE=1
  [ "$a" = "NOUNINST" ]  && DO_UNINST=0
  [ "$a" = "KEEPDEBUG" ] && KEEP_DEBUG=1
done

# Extra whitelist entries when KEEPDEBUG requested.
if [ "$KEEP_DEBUG" = 1 ]; then
  WHITELIST="$WHITELIST com.xiaobaifile.tv com.wukongtv.wkhelper com.explorer"
fi

# ---- helpers --------------------------------------------------------------
pkg_present() { pm list packages 2>/dev/null | grep -q "^package:$1"; }
in_list() { for x in $2; do [ "$x" = "$1" ] && return 0; done; return 1; }

pkg_version() {
  verline="$(dumpsys package "$1" 2>/dev/null | grep -m1 versionName)"
  ver="${verline#*versionName=}"; ver="${ver%% *}"
  [ "$ver" = "$verline" ] && ver=""
  echo "$ver"
}
pkg_uid() {
  uidline="$(dumpsys package "$1" 2>/dev/null | grep -m1 userId=)"
  uid="${uidline#*userId=}"; uid="${uid%% *}"
  [ "$uid" = "$uidline" ] && uid=""
  echo "$uid"
}

has_owner_group() {
  expected_owner="$1"; expected_group="$2"; shift 2
  previous=""
  for field in "$@"; do
    [ "$previous" = "$expected_owner" ] && [ "$field" = "$expected_group" ] && return 0
    previous="$field"
  done
  return 1
}

# Install the root daemon binary + the root-owned authorized-uid file, install a
# ROM-supported cold-boot hook, START the daemon now, and VERIFY it over its own
# PROBE protocol. Returns non-zero (and leaves no completion marker) on any failure.
install_daemon() {
  uid="$(pkg_uid "$PKG")"
  if [ -z "$uid" ]; then
    echo "  ERROR: package uid not found; cannot provision root daemon." >&2
    return 1
  fi
  if [ ! -f "$DAEMON_SRC" ]; then
    echo "  ERROR: $DAEMON_SRC missing; root daemon not installed (the bat pushes it)." >&2
    return 1
  fi
  # Execute/probe the uploaded candidate on this ROM before touching the live path.
  # The isolated socket cannot collide with @lmw_root_daemon.
  candidate_socket="lmw_setup_candidate_$$"
  chmod 0755 "$DAEMON_SRC" || { echo "  ERROR: daemon candidate chmod failed" >&2; return 1; }
  "$DAEMON_SRC" -candidate-probe "$candidate_socket" >/dev/null 2>&1 &
  candidate_pid=$!
  sleep 1
  candidate_out="$("$DAEMON_SRC" -probe-socket "$candidate_socket" 2>&1)"; candidate_rc=$?
  wait "$candidate_pid" 2>/dev/null
  echo "  daemon candidate probe: $candidate_out"
  if [ "$candidate_rc" != 0 ]; then
    echo "  ERROR: uploaded daemon candidate failed execution/protocol proof." >&2
    return 1
  fi
  mount -o remount,rw /system 2>/dev/null || mount -o rw,remount /system 2>/dev/null || {
    echo "  ERROR: cannot remount /system read-write for root daemon." >&2
    return 1
  }
  # Binary: plain root-owned executable — NO setuid bit (it is started as root,
  # never elevated by exec). system:system 0755 is enough to run + be readable.
  daemon_stage="$DAEMON_DST.installing"
  rm -f "$daemon_stage" "$DAEMON_BACKUP"
  cp "$DAEMON_SRC" "$daemon_stage" || { echo "  ERROR: daemon copy failed" >&2; return 1; }
  if [ -f "$DAEMON_DST" ]; then
    mv "$DAEMON_DST" "$DAEMON_BACKUP" || { echo "  ERROR: daemon backup failed" >&2; return 1; }
  fi
  mv "$daemon_stage" "$DAEMON_DST" || {
    [ -f "$DAEMON_BACKUP" ] && mv "$DAEMON_BACKUP" "$DAEMON_DST"
    echo "  ERROR: daemon install failed; rollback attempted" >&2
    return 1
  }
  chown 0:0 "$DAEMON_DST" 2>/dev/null || chown root:root "$DAEMON_DST" 2>/dev/null || {
    echo "  ERROR: daemon chown root:root failed" >&2; return 1; }
  chmod 0755 "$DAEMON_DST" || { echo "  ERROR: daemon chmod 0755 failed" >&2; return 1; }

  # Authorized-uid file: ROOT-owned, world-readable, app-UNwritable. The daemon
  # reads the single allowed Player uid from here and checks it against SO_PEERCRED.
  echo "$uid" > "$DAEMON_UID" || { echo "  ERROR: daemon uid file write failed" >&2; return 1; }
  chown 0:0 "$DAEMON_UID" 2>/dev/null || chown root:root "$DAEMON_UID" 2>/dev/null || {
    echo "  ERROR: daemon uid file chown root:root failed" >&2; return 1; }
  chmod 644 "$DAEMON_UID" || { echo "  ERROR: daemon uid file chmod 644 failed" >&2; return 1; }
  uid_numeric="$(ls -ln "$DAEMON_UID" 2>/dev/null)"
  set -- $uid_numeric
  has_owner_group 0 0 "$@" && [ "$(cat "$DAEMON_UID" 2>/dev/null)" = "$uid" ] || {
    echo "  ERROR: daemon uid file validation failed (must be root:root): ${uid_numeric:-unknown}" >&2
    rm -f "$DAEMON_DST" "$DAEMON_UID"
    return 1
  }

  install_boot_hook   # best-effort cold-boot persistence (see function)
  mount -o remount,ro /system 2>/dev/null || mount -o ro,remount /system 2>/dev/null || true

  stop_daemon
  start_daemon
  # VERIFY over the real protocol: the daemon's own -probe client connects to the
  # abstract socket, sends PROBE, and exits 0 only on "ready ... daemon_euid=0".
  # This is a true protocol probe, not a pgrep.
  probe_out="$("$DAEMON_DST" -probe 2>&1)"; probe_rc=$?
  echo "  daemon probe: $probe_out"
  if [ "$probe_rc" != 0 ]; then
    echo "  ERROR: root daemon did not answer a valid PROBE (rc=$probe_rc); rolling back." >&2
    stop_daemon
    mount -o remount,rw /system 2>/dev/null || mount -o rw,remount /system 2>/dev/null || true
    rm -f "$DAEMON_DST"
    if [ -f "$DAEMON_BACKUP" ]; then
      mv "$DAEMON_BACKUP" "$DAEMON_DST" && chmod 0755 "$DAEMON_DST" && start_daemon
    fi
    mount -o remount,ro /system 2>/dev/null || mount -o ro,remount /system 2>/dev/null || true
    echo "         remote restart/update is NOT available; not writing completion." >&2
    return 1
  fi
  mount -o remount,rw /system 2>/dev/null || mount -o rw,remount /system 2>/dev/null || true
  rm -f "$DAEMON_BACKUP"
  mount -o remount,ro /system 2>/dev/null || mount -o ro,remount /system 2>/dev/null || true
  echo "  root daemon running + verified for uid=$uid (socket @lmw_root_daemon)."
}

stop_daemon() {
  for pid in $(pidof lmw_root_daemon 2>/dev/null); do kill "$pid" 2>/dev/null; done
  sleep 1
}

# Start the daemon as root NOW (double-forks + detaches itself).
start_daemon() {
  pgrep -f "$DAEMON_DST" >/dev/null 2>&1 && {
    echo "  daemon already running; leaving it."; return 0; }
  "$DAEMON_DST" 2>/dev/null
  # give it a beat to bind the abstract socket before we probe
  sleep 1
}

# Records how cold-boot persistence was (or was not) wired, so the final summary
# can HONESTLY separate "daemon verified THIS boot" from "cold-boot persistence
# proven". One of: initd | recovery-created | recovery-appended | none.
BOOT_HOOK_STATE=none
BOOT_HOOK_PATH=""

# Scan the ROM's OWN init scripts for a service line that executes an
# install-recovery.sh, and echo the referenced script path (empty if none).
# This is the on-device EVIDENCE that the ROM runs that path as root at boot —
# AOSP ships `service flash_recovery /system/etc/install-recovery.sh` (class
# main, oneshot). toybox-safe: grep + word-splitting only (no sed/awk/head).
find_recovery_service_path() {
  for rc in /init.rc /init.*.rc /system/etc/init/*.rc; do
    [ -f "$rc" ] || continue
    line="$(grep -m1 install-recovery.sh "$rc" 2>/dev/null)"
    [ -z "$line" ] && continue
    # Skip commented lines (leading '#').
    case "$line" in \#*) continue;; esac
    for tok in $line; do
      case "$tok" in
        /*install-recovery.sh) echo "$tok"; return 0;;
      esac
    done
  done
  return 1
}

# Is the /system/etc/init.d dir demonstrably executed at boot? (some init*.rc
# run-parts it). Only then is dropping a script there real persistence.
initd_is_wired() {
  for rc in /init.rc /init.*.rc /system/etc/init/*.rc; do
    [ -f "$rc" ] || continue
    grep -q "run-parts" "$rc" 2>/dev/null && grep -q "init\.d" "$rc" 2>/dev/null && return 0
  done
  return 1
}

# Cold-boot persistence — the honest hard part on QZX_C1. This ROM ships NO
# /system/etc/init.d and NO install-recovery.sh, so there is no turnkey hook. We
# install one ONLY where the ROM's OWN init*.rc demonstrably wires it (real
# on-device evidence), NEVER by fabricating an init.rc edit:
#   (P1) init.d present AND an init*.rc run-parts it            -> drop 99lmwdaemon
#   (P2) an init*.rc runs an install-recovery.sh path (absent)  -> CREATE that
#        script; the ROM already execs it as root at boot, so populating it is a
#        real, ROM-sanctioned hook (reversible: lmw_restore.sh removes it)
#   (P3) a pre-existing install-recovery.sh                     -> append (idempotent)
# If none of these hold we DO NOT claim persistence. We set BOOT_HOOK_STATE so
# the summary tells the operator the truth and names the real-device step.
install_boot_hook() {
  # (P1) init.d — only if the ROM actually run-parts it.
  if [ -d "$INITD_DIR" ] && initd_is_wired; then
    {
      echo "#!/system/bin/sh"
      echo "# lan-media-wall root daemon cold-boot start (installed by lmw_setup.sh)."
      echo "[ -x $DAEMON_DST ] && $DAEMON_DST"
    } > "$INITD_HOOK" 2>/dev/null && chmod 0755 "$INITD_HOOK" 2>/dev/null && {
      chown 0:0 "$INITD_HOOK" 2>/dev/null || chown root:root "$INITD_HOOK" 2>/dev/null
      BOOT_HOOK_STATE=initd; BOOT_HOOK_PATH="$INITD_HOOK"
      echo "  cold-boot hook installed: $INITD_HOOK (ROM init.d, run-parts-wired)."
      return 0
    }
  fi

  # (P2)/(P3) install-recovery.sh — prefer the path the ROM's init*.rc names.
  rec="$(find_recovery_service_path)"
  [ -z "$rec" ] && rec="$RECOVERY_HOOK"   # fall back to the AOSP-canonical path
  start_line="[ -x $DAEMON_DST ] && $DAEMON_DST &"

  if [ -f "$rec" ]; then
    # (P3) exists → append idempotently, preserving any real recovery-flash logic.
    if grep -q "$DAEMON_DST" "$rec" 2>/dev/null; then
      BOOT_HOOK_STATE=recovery-appended; BOOT_HOOK_PATH="$rec"
      echo "  cold-boot hook already present in $rec."
    elif echo "$start_line" >> "$rec" 2>/dev/null; then
      BOOT_HOOK_STATE=recovery-appended; BOOT_HOOK_PATH="$rec"
      echo "  cold-boot hook appended to existing $rec."
    else
      echo "  WARN: could not append to $rec; cold-boot persistence unset." >&2
    fi
    return 0
  fi

  if [ -n "$(find_recovery_service_path)" ]; then
    # (P2) the ROM runs this path but the script is ABSENT → create it. The
    # daemon start runs in the FOREGROUND here (the service is oneshot and we are
    # already root); no '&' so the oneshot completes deterministically.
    if {
         echo "#!/system/bin/sh"
         echo "# install-recovery.sh created by lmw_setup.sh: the ROM's init service"
         echo "# execs this path at boot as root, so it is our cold-boot daemon start."
         echo "[ -x $DAEMON_DST ] && $DAEMON_DST"
       } > "$rec" 2>/dev/null && chmod 0755 "$rec" 2>/dev/null; then
      chown 0:0 "$rec" 2>/dev/null || chown root:root "$rec" 2>/dev/null
      BOOT_HOOK_STATE=recovery-created; BOOT_HOOK_PATH="$rec"
      echo "  cold-boot hook CREATED at ROM-referenced $rec (init service execs it as root)."
      return 0
    fi
    echo "  WARN: init*.rc references $rec but creating it failed; persistence unset." >&2
    return 0
  fi

  # No ROM-supported mechanism found — DO NOT fabricate persistence.
  BOOT_HOOK_STATE=none
  echo "  WARN: no ROM-supported boot hook found (no run-parts init.d, no init*.rc" >&2
  echo "        install-recovery service). COLD-BOOT PERSISTENCE IS NOT WIRED." >&2
  echo "        The daemon is started + verified for THIS boot; on cold boot it will" >&2
  echo "        NOT auto-start until a ROM-supported root hook is added (real-device step)." >&2
}

# Disable (or uninstall) every installed package not in the whitelist.
run_cleanup() {
  echo "  disabling every app except the media wall + OS essentials..."
  n_dis=0; n_uni=0; n_guard=0
  for line in $(pm list packages 2>/dev/null); do
    p="${line#package:}"   # word-split already stripped any trailing CR
    if in_list "$p" "$WHITELIST"; then
      n_guard=$((n_guard+1)); continue
    fi
    # Is it a user-installed /data/app package? (uninstallable)
    is_data=0
    pm list packages -f 2>/dev/null | grep -q "^package:/data/app/.*=$p\$" && is_data=1
    if [ "$DO_UNINST" = 1 ] && [ "$is_data" = 1 ]; then
      if pm uninstall "$p" >/dev/null 2>&1; then
        echo "    [UNINSTALLED] $p"; n_uni=$((n_uni+1)); continue
      fi
    fi
    out="$(pm disable-user --user 0 "$p" 2>&1)"
    echo "$out" | grep -qi "disabled" || out="$(pm disable-user "$p" 2>&1)"
    if echo "$out" | grep -qi "disabled"; then
      echo "    [disabled] $p"; n_dis=$((n_dis+1))
    else
      echo "    [skip] $p (could not disable: $out)"
    fi
  done
  echo "  cleanup summary: disabled=$n_dis uninstalled=$n_uni guarded(kept)=$n_guard"
}

# Bind the player as default HOME. v1.13.7+: the HOME intent-filter lives on
# a REAL Activity (MainActivity), not an activity-alias — the KitKat/YunOS
# PackageManager DOES register a real Activity as an implicit HOME candidate
# (it refused to do so for an activity-alias, which broke every prior attempt).
# With the OEM desktop (youku SLauncher) disabled, MainActivity is the sole
# CATEGORY_HOME target, so the system settles on it. This function just clears
# any stale preferred-launcher association and nudges HOME to resolve.
bind_home() {
  # 4.4 has no `cmd package set-home-activity` / `resolve-activity`; clearing
  # preferred activities + firing a HOME intent is the portable path here.
  pm clear-preferred-activities >/dev/null 2>&1
  am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1
  # Verify via dumpsys: is our package the resolved HOME / on top of the HOME stack?
  if dumpsys activity activities 2>/dev/null | grep -m1 -E "Hist|mResumedActivity|Home" | grep -q "$PKG"; then
    echo "  default HOME = media wall (resolved on the HOME stack)."
    return
  fi
  # Second check: does an implicit HOME intent now resolve to us at all?
  if am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>&1 \
       | grep -q "$PKG"; then
    echo "  default HOME = media wall (implicit HOME resolves to player)."
    return
  fi
  echo "  NOTE: could not confirm default HOME from shell; press the remote HOME" >&2
  echo "        key once — MainActivity now declares category.HOME, so with the" >&2
  echo "        OEM desktop disabled the box should land on the wall." >&2
}

# ---------------------------------------------------------------------------
id | grep -q "uid=0" || { echo "ERROR: not root (uid!=0). This box needs root adb." >&2; exit 1; }

phase="$(cat "$PHASE" 2>/dev/null)"
[ -z "$phase" ] && phase=start

case "$phase" in
start)
  echo "[phase 1/2: install] installing/updating $PKG ..."
  if [ ! -f "$APK_SRC" ]; then
    echo "ERROR: $APK_SRC missing. Push the player APK first (the bat does this)." >&2
    exit 1
  fi
  before="$(pkg_version "$PKG")"
  echo "$before" > "$BEFORE_FILE"
  echo "  current installed versionName: ${before:-not-installed}"

  stale_apk=0
  ls /data/app/$PKG*.apk >/dev/null 2>&1 && stale_apk=1
  if [ "$DO_FORCE" = 1 ] || { [ "$stale_apk" = 1 ] && ! pkg_present "$PKG"; }; then
    echo "  clean reinstall (signature change / FORCE): removing old package + data..."
    pm uninstall "$PKG" >/dev/null 2>&1
    pm uninstall -k "$PKG" >/dev/null 2>&1
    rm -rf /data/data/$PKG 2>/dev/null
    rm -f /data/app/$PKG*.apk 2>/dev/null
  elif pkg_present "$PKG"; then
    echo "  same-signature upgrade -> overwriting in place."
    rm -f /data/app/$PKG*.apk 2>/dev/null
  else
    echo "  fresh install."
    rm -f /data/app/$PKG*.apk 2>/dev/null
  fi
  rm -f /data/dalvik-cache/*$PKG* 2>/dev/null

  cp "$APK_SRC" "$DST" || { echo "ERROR: copy to /data/app failed" >&2; exit 1; }
  chmod 644 "$DST"
  chown system:system "$DST"
  echo "  APK placed at $DST"
  echo installed > "$PHASE"
  echo "  restarting to let the boot scan adopt the package..."
  echo ">>> after the box comes back, RUN THE SAME COMMAND AGAIN <<<"
  sync; reboot
  ;;

installed)
  if ! pkg_present "$PKG"; then
    echo "ERROR: $PKG still not present after restart." >&2
    echo "  First verify with:  pm list packages | grep -i lanmediawall" >&2
    echo "  If genuinely missing, a signature mismatch is likely — rerun with FORCE:" >&2
    echo "    rm -f $PHASE ; sh $0 FORCE" >&2
    echo start > "$PHASE"
    exit 1
  fi
  ver="$(pkg_version "$PKG")"
  before="$(cat "$BEFORE_FILE" 2>/dev/null)"
  echo "[phase 2/2: configure] $PKG versionName=${ver:-?}"
  if [ -n "$before" ] && [ "$before" = "$ver" ]; then
    echo "  NOTE: versionName unchanged (${ver:-?}); pushed APK may be the same build." >&2
  fi

  # Install + start + PROBE-verify the root daemon (replaces the old setuid helper).
  install_daemon || { echo "ERROR: root daemon provisioning/probe failed; remote restart/update unavailable." >&2; exit 1; }

  # Prime autostart (stopped-state lift) so BOOT_COMPLETED fires on future boots.
  am start -n "$MAIN" >/dev/null 2>&1 && echo "  autostart primed (am start)."

  # Disable everything else.
  if [ "$DO_CLEAN" = 1 ]; then
    echo "  === CLEANUP: make this box a media-wall-only kiosk ==="
    run_cleanup
  else
    echo "  NOCLEAN: skipping app disable/uninstall."
  fi

  # Make the media wall the default HOME (only meaningful after youku disabled).
  if [ "$DO_CLEAN" = 1 ]; then
    bind_home
  fi

  rm -f "$PHASE" "$BEFORE_FILE" 2>/dev/null
  echo complete > "$COMPLETE" || { echo "ERROR: setup completion marker write failed" >&2; exit 1; }
  echo
  echo "############################################################"
  echo "#  SETUP COMPLETE. Player versionName=${ver:-?}."
  echo "#  The box now boots straight into the media wall and every"
  echo "#  other app is disabled. Undo cleanup: lmw_restore.sh"
  echo "#"
  echo "#  root daemon: STARTED + PROBE-VERIFIED for THIS boot (remote"
  echo "#               restart/update are live now)."
  case "$BOOT_HOOK_STATE" in
    initd|recovery-created|recovery-appended)
      echo "#  cold-boot:   hook installed via $BOOT_HOOK_STATE"
      echo "#               ($BOOT_HOOK_PATH)."
      echo "#               NOT YET PROVEN — real-device acceptance gate: reboot the"
      echo "#               box, then run 'lmw_root_daemon -probe' and confirm it"
      echo "#               still returns 'ready ... daemon_euid=0'." ;;
    *)
      echo "#  cold-boot:   NOT WIRED — no ROM-supported hook on this ROM. The daemon"
      echo "#               will NOT auto-start after a power cycle until a root boot"
      echo "#               hook is added. Remote restart/update work until then." ;;
  esac
  echo "############################################################"
  ;;

*)
  echo "unknown phase '$phase'; resetting to start." >&2
  echo start > "$PHASE"
  ;;
esac
