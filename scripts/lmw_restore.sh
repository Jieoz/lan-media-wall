#!/system/bin/sh
# ===========================================================================
#  lmw_restore.sh — UNDO everything lmw_provision.sh did, on YunOS/AliOS 4.4.2
#  boxes (QZX_C1). Brings the box back to its as-received state so you can
#  re-verify a deployment from scratch.
#
#  What it does:
#    1. re-enable every package lmw_provision may have disabled (youku stock
#       launcher + PCDN/mining watchdog + video bloat)
#    2. uninstall the LAN-Media-Wall player + wipe its data and /data/app copy
#    3. clear the provisioner phase file
#    4. reboot so the restored stock launcher takes over again
#
#  Run (single line):
#     adb push lmw_restore.sh /data/local/tmp/lmw_restore.sh
#     adb shell sh /data/local/tmp/lmw_restore.sh
#
#  Safe: only re-enables packages and removes OUR app. Touches nothing in
#  /system. Requires root adb (uid=0), which these boxes have.
# ===========================================================================

PKG=com.jieoz.lanmediawall.player
PHASE=/data/local/tmp/lmw_phase

# Everything the provisioner might have disabled. youku.taitan.tv is the stock
# HOME launcher — re-enabling it restores the original desktop.
RESTORE_LIST="com.youku.taitan.tv com.youku.cloud.dog com.ktcp.tvvideo cn.miguvideo.migutv com.gitvvideo.qiaozhixin com.xhm.live"

id | grep -q "uid=0" || { echo "ERROR: not root (uid!=0)." >&2; exit 1; }

echo "[restore] re-enabling packages the provisioner may have disabled..."
for p in $RESTORE_LIST; do
  if pm list packages 2>/dev/null | grep -q "package:$p\$"; then
    pm enable "$p" >/dev/null 2>&1 && echo "    enabled $p" || echo "    (already enabled) $p"
  fi
done

echo "[restore] disabling player HomeAlias (so it stops claiming HOME)..."
pm disable "$PKG/$PKG.HomeAlias" >/dev/null 2>&1

echo "[restore] uninstalling player + wiping its data..."
pm uninstall "$PKG" >/dev/null 2>&1
rm -rf /data/data/$PKG 2>/dev/null
rm -f /data/app/$PKG*.apk 2>/dev/null
rm -f /data/dalvik-cache/*$PKG* 2>/dev/null

echo "[restore] clearing provisioner phase file..."
rm -f "$PHASE" 2>/dev/null

echo "[restore] verifying..."
if pm list packages 2>/dev/null | grep -q "package:$PKG\$"; then
  echo "  WARN: $PKG still present (may need a reboot to fully clear)." >&2
else
  echo "  player removed."
fi
echo "  still-disabled packages (should be empty):"
pm list packages -d 2>/dev/null | sed 's/^/    /'

echo "[restore] rebooting so the stock launcher takes back over..."
sync; reboot
