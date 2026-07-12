#!/system/bin/sh
# ===========================================================================
#  lmw_restore.sh — UNDO lmw_setup.sh's cleanup. Re-enables EVERY package that
#  is currently in the DISABLED / disabled-user state, restoring the box to a
#  normal (non-kiosk) launcher. Does NOT reinstall packages that were
#  uninstalled from /data (UNINSTALL/default mode) — those must be re-sideloaded
#  or the box reflashed.
#
#  Runs INSIDE the box (toybox sh). Push with:  adb push lmw_restore.sh /data/local/tmp/
#  then: adb shell "sh /data/local/tmp/lmw_restore.sh"
#
#  toybox-safe: only grep/pm/cmd/am/echo.
# ===========================================================================
id | grep -q "uid=0" || { echo "ERROR: not root (uid!=0)." >&2; exit 1; }

echo "re-enabling every disabled package..."
n=0
# pm list packages -d = disabled packages only (leading ^package: anchor; the
# word-split on the for-loop strips YunOS's trailing CR).
for line in $(pm list packages -d 2>/dev/null); do
  p="${line#package:}"
  out="$(pm enable "$p" 2>&1)"
  if echo "$out" | grep -qi "enabled"; then
    echo "  [enabled] $p"; n=$((n+1))
  else
    echo "  [skip] $p ($out)"
  fi
done
echo "re-enabled $n package(s)."

# Remove the cold-boot daemon hooks lmw_setup.sh may have installed (reversible).
# The init.d hook is our own file → delete it. install-recovery.sh may be either
# ours (created) or a pre-existing ROM file we appended a line to; delete only if
# it is ONLY our created hook, otherwise strip nothing destructive and just warn.
INITD_HOOK=/system/etc/init.d/99lmwdaemon
RECOVERY_HOOK=/system/etc/install-recovery.sh
DAEMON_DST=/system/xbin/lmw_root_daemon
mount -o remount,rw /system 2>/dev/null || mount -o rw,remount /system 2>/dev/null
if [ -f "$INITD_HOOK" ]; then
  rm -f "$INITD_HOOK" 2>/dev/null && echo "  removed cold-boot hook $INITD_HOOK."
fi
if [ -f "$RECOVERY_HOOK" ] && grep -q "created by lmw_setup.sh" "$RECOVERY_HOOK" 2>/dev/null; then
  rm -f "$RECOVERY_HOOK" 2>/dev/null && echo "  removed lmw-created $RECOVERY_HOOK."
elif [ -f "$RECOVERY_HOOK" ] && grep -q "$DAEMON_DST" "$RECOVERY_HOOK" 2>/dev/null; then
  echo "  NOTE: $RECOVERY_HOOK is a pre-existing ROM file with an appended lmw line;"
  echo "        left in place to avoid clobbering ROM recovery logic. Edit by hand if needed."
fi
mount -o remount,ro /system 2>/dev/null || mount -o ro,remount /system 2>/dev/null || true

# Let the system settle HOME again: clear the forced kiosk HOME so the stock
# launcher (if re-enabled) can win the HOME resolver again.
pm clear-preferred-activities >/dev/null 2>&1
echo
echo "RESTORE COMPLETE. Reboot the box (adb reboot) so the stock launcher returns."
echo "NOTE: packages UNINSTALLED from /data are NOT restored here — re-sideload"
echo "      them or reflash if you need them back."
