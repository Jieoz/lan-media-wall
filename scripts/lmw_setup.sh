#!/system/bin/sh
# ===========================================================================
#  lmw_setup.sh — ONE ON-BOX script that does EVERYTHING for a LAN-Media-Wall
#  kiosk on YunOS/AliOS 4.4.2 (QZX_C1, Hi3798MV300, root adb):
#     1. install / upgrade the media-wall player (from the pushed APK)
#     2. arm the in-app push-update root helper
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
HELPER_SRC=/data/local/tmp/lmw_root_helper.new
HELPER_DST=/data/local/tmp/lmw_root_helper
HELPER_UID=/data/local/tmp/lmw_root_helper.uid

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

install_helper() {
  uid="$(pkg_uid "$PKG")"
  if [ -z "$uid" ]; then
    echo "  NOTE: package uid not found; cannot arm in-app push-update helper yet." >&2
    return 0
  fi
  if [ ! -f "$HELPER_SRC" ]; then
    echo "  NOTE: $HELPER_SRC missing; push-update helper not armed." >&2
    return 0
  fi
  cp "$HELPER_SRC" "$HELPER_DST" || { echo "  WARN: helper copy failed" >&2; return 0; }
  chown 0:$uid "$HELPER_DST" 2>/dev/null || chown root:$uid "$HELPER_DST" 2>/dev/null || {
    echo "  WARN: helper chown root:$uid failed" >&2; return 0; }
  chmod 6750 "$HELPER_DST" || { echo "  WARN: helper chmod 6750 failed" >&2; return 0; }
  echo "$uid" > "$HELPER_UID"
  chown 0:0 "$HELPER_UID" 2>/dev/null || chown root:root "$HELPER_UID" 2>/dev/null
  chmod 644 "$HELPER_UID"
  helper_mode="$(ls -l "$HELPER_DST" 2>/dev/null)"
  echo "$helper_mode" | grep -q '^-rwsr-s---' || {
    echo "  ERROR: filesystem stripped helper setuid/setgid bits: $helper_mode" >&2
    rm -f "$HELPER_DST" "$HELPER_UID"
    return 1
  }
  echo "  in-app push-update helper armed for uid=$uid."
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

  # Arm push-update helper.
  install_helper || { echo "ERROR: root helper provisioning failed; remote restart/update unavailable." >&2; exit 1; }

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
  echo
  echo "############################################################"
  echo "#  SETUP COMPLETE. Player versionName=${ver:-?}."
  echo "#  The box now boots straight into the media wall and every"
  echo "#  other app is disabled. Undo cleanup: lmw_restore.sh"
  echo "############################################################"
  ;;

*)
  echo "unknown phase '$phase'; resetting to start." >&2
  echo start > "$PHASE"
  ;;
esac
