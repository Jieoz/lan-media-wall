#!/system/bin/sh
# ===========================================================================
#  lmw_provision.sh — ON-BOX deployer/updater for the LAN-Media-Wall Player on
#  YunOS/AliOS 4.4.2 boxes (QZX_C1, fake-capacity flash, root adb).
#
#  Runs INSIDE the box (toybox sh). Push it once, then run the SAME single
#  command; it advances one phase per run via a phase file, surviving the one
#  restart it triggers. This avoids Windows adb multi-line-paste problems.
#
#  The version is read from the pushed APK itself — you never type a version
#  number. Whatever APK you push is what gets installed; the script prints the
#  resulting versionName so you can see what landed.
#
#  SETUP (from the PC, once — two single-line pushes; APK name can be anything):
#     adb push <whatever-name>.apk /data/local/tmp/lmw_player.apk
#     adb push lmw_provision.sh    /data/local/tmp/lmw_provision.sh
#
#  RUN this ONE command; after the box restarts, run the SAME line again until
#  it prints "PROVISION COMPLETE":
#     adb shell sh /data/local/tmp/lmw_provision.sh
#
#  (Or just use scripts/lmw_update.bat on the PC, which bridges the restart
#   and runs both phases for you as a single command.)
#
#  Flags (optional):
#     NOCLEAN  keep the bloat/mining/launcher packages (cleaning is ON default)
#     FORCE    clean reinstall (uninstall+wipe first) — for signature-mismatch
#              upgrades that would otherwise be rejected by KitKat
#
#  Undo everything: use lmw_restore.sh (re-enables all + removes player).
# ===========================================================================

PKG=com.jieoz.lanmediawall.player
# KitKat's `pm enable/disable` needs the FULLY-QUALIFIED component name;
# the pkg/.Comp shorthand silently no-ops on 4.4.
MAIN=$PKG/$PKG.MainActivity
APK_SRC=/data/local/tmp/lmw_player.apk
DST=/data/app/$PKG-1.apk
PHASE=/data/local/tmp/lmw_phase
BEFORE_FILE=/data/local/tmp/lmw_before_version

# Packages disabled by default (all reversible). Confirmed on QZX_C1:
#   youku.taitan.tv = stock HOME launcher (ALSO a PCDN host) — disabling it is
#                     what makes the box boot straight into the media wall
#                     instead of flashing the youku desktop first.
#   youku.cloud.dog = PCDN / mining watchdog (primary bleed stop)
#   the rest        = video bloat, not needed on a kiosk.
CLEANLIST="com.youku.taitan.tv com.youku.cloud.dog com.ktcp.tvvideo cn.miguvideo.migutv com.gitvvideo.qiaozhixin com.xhm.live"

DO_CLEAN=1
DO_FORCE=0
for a in "$@"; do
  [ "$a" = "NOCLEAN" ] && DO_CLEAN=0
  [ "$a" = "FORCE" ] && DO_FORCE=1
done

# Match the package line WITHOUT a trailing `$` anchor. YunOS/toybox `pm list`
# often emits a trailing CR (\r), so the old "package:<pkg>$" never matched even
# when the package WAS installed -> the script falsely reported "still not
# present" and drove an endless FORCE/restart loop. Leading-anchored, NO trailing
# anchor: exact enough and naturally CR-proof. No `tr`/`sed` needed — toybox on
# these boxes is stripped down (no which/sed/head), only grep is safe.
pkg_present() {
  pm list packages 2>/dev/null | grep -q "^package:$1"
}

pkg_version() {
  verline="$(dumpsys package "$1" 2>/dev/null | grep -m1 versionName)"
  ver="${verline#*versionName=}"
  ver="${ver%% *}"
  [ "$ver" = "$verline" ] && ver=""
  echo "$ver"
}

id | grep -q "uid=0" || { echo "ERROR: not root (uid!=0). This box needs root adb." >&2; exit 1; }

phase="$(cat "$PHASE" 2>/dev/null)"
[ -z "$phase" ] && phase=start

# ---------------------------------------------------------------------------
case "$phase" in
start)
  echo "[phase start] installing/updating $PKG ..."
  if [ ! -f "$APK_SRC" ]; then
    echo "ERROR: $APK_SRC missing. Push it first:" >&2
    echo "  adb push <player.apk> $APK_SRC" >&2
    exit 1
  fi

  before="$(pkg_version "$PKG")"
  echo "$before" > "$BEFORE_FILE"
  echo "  current installed versionName: ${before:-not-installed}"
  echo "  installing whatever version the pushed APK contains."

  # A signature mismatch on KitKat makes the boot scan reject the new APK AND
  # drop the old package. Detect that (apk in /data/app but pkg not registered),
  # or an explicit FORCE, and do a clean reinstall (uninstall + wipe data).
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

  # Remove stale dex for this package even on same-signature upgrades. KitKat's
  # boot scan normally handles this, but these YunOS boxes are brittle and fake
  # flash makes partial/stale state common.
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
    echo "  If this repeats, a signature mismatch is likely — rerun with FORCE:" >&2
    echo "    adb shell \"rm -f $PHASE\" && adb shell sh $0 FORCE" >&2
    echo start > "$PHASE"
    exit 1
  fi

  ver="$(pkg_version "$PKG")"
  before="$(cat "$BEFORE_FILE" 2>/dev/null)"
  echo "[phase installed] $PKG versionName=${ver:-?}"

  if [ -n "$before" ] && [ "$before" = "$ver" ]; then
    echo "NOTE: versionName is unchanged (${ver:-?})." >&2
    echo "  If you expected an upgrade, the pushed APK may be the same build as before." >&2
  fi

  # Prime autostart: lift out of Android's stopped-state so BOOT_COMPLETED is
  # delivered on every future boot -> box comes up into the media wall.
  am start -n "$MAIN" >/dev/null 2>&1 && echo "  autostart primed (am start)."

  if [ "$DO_CLEAN" = 1 ]; then
    echo "  disabling stock launcher + mining + bloat (reversible)..."
    for p in $CLEANLIST; do
      if pkg_present "$p"; then
        pm disable-user --user 0 "$p" >/dev/null 2>&1 || pm disable-user "$p" >/dev/null 2>&1
        echo "    disabled $p"
      fi
    done
    echo "  (undo any with: adb shell pm enable <pkg>; full undo: lmw_restore.sh)"
  fi

  # ---- Make the player the default HOME so the remote's 主页/HOME key works ----
  # After the stock youku launcher is disabled the system has NO default HOME
  # left, so pressing KEY_HOME resolves to nothing (confirmed on QZX_C1:
  # `cmd package resolve-activity -c android.intent.category.HOME` returned
  # empty). The player ships a HomeAlias with the HOME/DEFAULT/MAIN intent-filter
  # but it was never bound as the preferred HOME. Bind it now, with fallbacks
  # because KitKat/YunOS varies in which command exists.
  HOME_ALIAS=$PKG/$PKG.HomeAlias
  bound=0
  # (a) Newer surface: cmd package set-home-activity (present on some AliOS builds)
  if cmd package set-home-activity "$HOME_ALIAS" >/dev/null 2>&1; then
    bound=1
  fi
  # (b) Clear any stale preferred-app associations so the system re-resolves HOME
  #     to our now-only candidate instead of a remembered (disabled) launcher.
  if [ "$bound" = 0 ]; then
    pm clear-preferred-activities >/dev/null 2>&1 || pm clear com.android.settings >/dev/null 2>&1
  fi
  # (c) Fire a HOME intent once: with youku disabled, HomeAlias is the sole
  #     candidate, so the system settles it as the default without a chooser.
  am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1
  # (d) Verify what the system now resolves HOME to.
  home_now="$(cmd package resolve-activity -c android.intent.category.HOME 2>/dev/null | grep -m1 -o "$PKG")"
  if [ -n "$home_now" ] || [ "$bound" = 1 ]; then
    echo "  default HOME bound to the player (主页键将返回媒体墙)."
  else
    echo "  NOTE: could not confirm default HOME binding; the remote 主页键 may" >&2
    echo "        still need a one-time chooser press to 'always' select the wall." >&2
  fi

  rm -f "$PHASE" "$BEFORE_FILE" 2>/dev/null
  echo "PROVISION COMPLETE."
  echo "  Installed versionName=${ver:-?}. The box now boots straight into the media wall."
  ;;

*)
  echo "unknown phase '$phase'; resetting to start." >&2
  echo start > "$PHASE"
  ;;
esac
