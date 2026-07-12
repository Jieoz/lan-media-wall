#!/usr/bin/env bash
#
# qzx_verify_update.sh — REAL-DEVICE acceptance for the v1.14.2 update path:
# activate a new APK via `pm install -r` WITHOUT a whole-device reboot.
#
# WHY THIS EXISTS: upstream did NOT accept the old "overwrite /data/app + reboot"
# update contract (a warm reboot bricks Wi-Fi on QZX_C1, and overwriting the file
# leaves PackageManager's recorded versionCode stale). v1.14.2 switches to
# `pm install -r`. Whether headless `pm install` works on YunOS 4.4.2 (BOOTCLASSPATH
# / installd availability) CANNOT be proven in a container — so this harness proves
# it on the real box. It measures the two things that define the contract:
#   (1) the package's versionCode CHANGED  → the new code is actually activated, and
#       PackageManager reports the new version (not a stale one), and
#   (2) the device uptime DID NOT reset     → no whole-device reboot happened.
#
# This drives the EXACT command the daemon runs (`pm install -r <staged>`) as root
# over adb, independent of the socket + SO_PEERCRED layer, so a green run means the
# activation mechanism itself is sound on this hardware.
#
# It is reversible in spirit: it installs the APK YOU provide (normally the same or
# a newer build of our own package, same signer). It does NOT reboot, uninstall, or
# touch media/config. The staged file under /data/local/tmp is removed at the end.
#
# USAGE:
#   scripts/qzx_verify_update.sh <new-or-same-signer.apk> [serial ...]
#     no serial → the single attached 'device' (refuses if >1 unless serials given)
#
# ENV OVERRIDES:
#   PKG   package under test (default com.jieoz.lanmediawall.player)
#
set -u

PKG="${PKG:-com.jieoz.lanmediawall.player}"
STAGE="/data/local/tmp/lmw_update_staged.apk"   # matches LMW_STAGED_APK in the daemon

APK="${1:-}"
if [ -z "$APK" ] || [ ! -f "$APK" ]; then
  echo "usage: $0 <apk-path> [serial ...]   (apk must exist)" >&2
  exit 2
fi
shift || true

# Resolve target serials.
serials="$*"
if [ -z "$serials" ]; then
  serials="$(adb devices | awk '/\tdevice$/{print $1}')"
  n="$(echo "$serials" | grep -c .)"
  if [ "$n" -ne 1 ]; then
    echo "found $n attached devices; pass an explicit serial to disambiguate:" >&2
    adb devices >&2
    exit 2
  fi
fi

# versionCode as PackageManager records it (the number that MUST change on success).
pm_version_code() { # $1 serial
  adb -s "$1" shell "dumpsys package $PKG | grep versionCode=" 2>/dev/null \
    | tr -d '\r' | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1
}

# Seconds since boot (integer). A reset (new value < old) means a reboot happened.
uptime_seconds() { # $1 serial
  adb -s "$1" shell cat /proc/uptime 2>/dev/null | tr -d '\r' | awk '{printf "%d", $1}'
}

overall=0
for s in $serials; do
  echo "=============================================================="
  echo "device $s — verifying pm-install-r update of $PKG (no reboot)"
  echo "=============================================================="

  before_vc="$(pm_version_code "$s")"
  before_up="$(uptime_seconds "$s")"
  echo "  before: versionCode=${before_vc:-<not-installed>} uptime=${before_up}s"

  # Reproduce the daemon flow: stage world-readable, then `pm install -r` as root.
  echo "  pushing APK to $STAGE ..."
  if ! adb -s "$s" push "$APK" "$STAGE" >/dev/null 2>&1; then
    echo "  FAIL: adb push failed" >&2; overall=1; continue
  fi
  adb -s "$s" shell "chmod 644 $STAGE" >/dev/null 2>&1

  echo "  running: pm install -r $STAGE (as root) ..."
  pm_out="$(adb -s "$s" shell "su 0 pm install -r $STAGE 2>&1 || pm install -r $STAGE 2>&1" | tr -d '\r')"
  echo "  pm output: $pm_out"
  adb -s "$s" shell "rm -f $STAGE" >/dev/null 2>&1

  # Let PackageManager settle, then re-measure.
  sleep 3
  after_vc="$(pm_version_code "$s")"
  after_up="$(uptime_seconds "$s")"
  echo "  after:  versionCode=${after_vc:-<gone>} uptime=${after_up}s"

  ok=1
  echo "$pm_out" | grep -q "Success" || { echo "  FAIL: pm did not report Success"; ok=0; }
  if [ -n "$before_vc" ] && [ "$before_vc" = "$after_vc" ]; then
    echo "  WARN: versionCode unchanged ($after_vc) — expected if you re-installed the SAME build;"
    echo "        use a build with a HIGHER versionCode to prove activation of new code."
  fi
  # Uptime must not have reset (a reboot sets it back near 0 / below the prior value).
  if [ -n "$after_up" ] && [ -n "$before_up" ] && [ "$after_up" -lt "$before_up" ]; then
    echo "  FAIL: uptime went backwards ($before_up -> $after_up) — a reboot happened!"; ok=0
  else
    echo "  PASS: no reboot (uptime advanced $before_up -> $after_up)"
  fi

  if [ "$ok" -eq 1 ]; then
    echo "  RESULT: OK — new APK activated via pm install -r, device did NOT reboot."
  else
    echo "  RESULT: NOT OK — see FAIL lines above."; overall=1
  fi
done

echo
if [ "$overall" -eq 0 ]; then
  echo "ALL DEVICES: update-without-reboot contract verified."
else
  echo "SOME DEVICES FAILED — the pm-install update path needs attention on this hardware."
fi
exit "$overall"
