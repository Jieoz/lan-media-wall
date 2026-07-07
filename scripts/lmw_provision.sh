#!/system/bin/sh
# ===========================================================================
#  lmw_provision.sh — ON-BOX deployer/updater for the LAN-Media-Wall Player on
#  YunOS/AliOS 4.4.2 boxes (QZX_C1, fake-capacity flash, root adb).
#
#  Runs INSIDE the box (toybox sh). Push it once, then run the SAME single
#  command; it advances one phase per run via a phase file, surviving the one
#  reboot it triggers. This avoids Windows adb multi-line-paste problems.
#
#  SETUP (from the PC, once — two single-line pushes):
#     adb push LANMediaWall-v1.11.2-Player-Android.apk /data/local/tmp/lmw_player.apk
#     adb push lmw_provision.sh /data/local/tmp/lmw_provision.sh
#
#  RUN this ONE command; after the box reboots, run the SAME line again until
#  it prints "PROVISION COMPLETE":
#     adb shell sh /data/local/tmp/lmw_provision.sh VERSION=1.11.2
#
#  Flags (optional):
#     VERSION=x.y.z  fail if installed package versionName is not x.y.z
#     NOCLEAN        keep the bloat/mining/launcher packages (cleaning is ON default)
#     FORCE          clean reinstall (uninstall+wipe first) — for signature-mismatch
#                    upgrades that would otherwise be rejected by KitKat
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
EXPECT_FILE=/data/local/tmp/lmw_expected_version
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
EXPECT_VERSION=""
for a in "$@"; do
  [ "$a" = "NOCLEAN" ] && DO_CLEAN=0
  [ "$a" = "FORCE" ] && DO_FORCE=1
  case "$a" in
    VERSION=*) EXPECT_VERSION="${a#VERSION=}" ;;
    EXPECT=*) EXPECT_VERSION="${a#EXPECT=}" ;;
  esac
done

# Match the package line WITHOUT a trailing `$` anchor. YunOS/toybox `pm list`
# often emits a trailing CR (\r), so the old "package:<pkg>$" never matched even
# when the package WAS installed -> the script falsely reported "still not
# present" and drove an endless FORCE/reboot loop. Leading-anchored, NO trailing
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
  if [ -n "$EXPECT_VERSION" ]; then
    echo "$EXPECT_VERSION" > "$EXPECT_FILE"
    echo "  expected versionName after reboot: $EXPECT_VERSION"
  else
    rm -f "$EXPECT_FILE" 2>/dev/null
    echo "  no expected version set; pass VERSION=x.y.z to make upgrade verification strict."
  fi
  echo "  current installed versionName: ${before:-not-installed}"

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
  echo "  rebooting to let the boot scan adopt the package..."
  echo ">>> after the box comes back, RUN THE SAME COMMAND AGAIN <<<"
  sync; reboot
  ;;

installed)
  if ! pkg_present "$PKG"; then
    echo "ERROR: $PKG still not present after reboot." >&2
    echo "  If this repeats, a signature mismatch is likely — rerun with FORCE:" >&2
    echo "    adb shell \"rm -f $PHASE\" && adb shell sh $0 FORCE VERSION=${EXPECT_VERSION:-x.y.z}" >&2
    echo start > "$PHASE"
    exit 1
  fi

  ver="$(pkg_version "$PKG")"
  before="$(cat "$BEFORE_FILE" 2>/dev/null)"
  expected="$(cat "$EXPECT_FILE" 2>/dev/null)"
  echo "[phase installed] $PKG versionName=${ver:-?}"

  if [ -n "$expected" ] && [ "$ver" != "$expected" ]; then
    echo "ERROR: installed versionName mismatch." >&2
    echo "  expected: $expected" >&2
    echo "  actual:   ${ver:-?}" >&2
    echo "  This usually means the pushed APK itself has the wrong internal version," >&2
    echo "  or the boot scan rejected it. Re-push the correct APK, then rerun:" >&2
    echo "    adb push LANMediaWall-v$expected-Player-Android.apk $APK_SRC" >&2
    echo "    adb shell \"rm -f $PHASE\"" >&2
    echo "    adb shell sh $0 VERSION=$expected" >&2
    echo start > "$PHASE"
    exit 1
  fi

  if [ -z "$expected" ] && [ -n "$before" ] && [ "$before" = "$ver" ]; then
    echo "WARNING: versionName did not change (${ver:-?})." >&2
    echo "  If this was meant to be an upgrade, rerun with VERSION=x.y.z so the script can fail loudly." >&2
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

  rm -f "$PHASE" "$EXPECT_FILE" "$BEFORE_FILE" 2>/dev/null
  echo "PROVISION COMPLETE."
  echo "  The box now boots straight into the media wall. Reboot to verify:"
  echo "    adb reboot"
  ;;

*)
  echo "unknown phase '$phase'; resetting to start." >&2
  echo start > "$PHASE"
  ;;
esac
