#!/system/bin/sh
# ===========================================================================
#  lmw_audit.sh — READ-ONLY inventory of a YunOS/AliOS box before cleanup.
#
#  Does NOT disable, uninstall, or change anything. Just reports:
#    - device / android / storage / memory facts
#    - which package is the current HOME launcher  (NEVER disable this)
#    - whether the LAN-Media-Wall player is installed + its version
#    - every 3rd-party package, auto-tagged KEEP / BLOAT / MINER? / UNKNOWN
#    - every package's install path (/system vs /data) so we see what's OEM
#    - running processes + known miner/PCDN signatures
#
#  Run ONE line from the PC:
#     adb shell sh /data/local/tmp/lmw_audit.sh
#  (or use lmw_audit.bat, which pushes this and saves the report to a file)
#
#  toybox-safe: uses only grep/ls/cat/pm/am/dumpsys/getprop/ps — no sed/head/which.
#  pm-list matching uses a LEADING ^package: anchor only (YunOS emits trailing CR,
#  a trailing $ anchor would never match).
# ===========================================================================

PLAYER=com.jieoz.lanmediawall.player

# Known-bad signatures seen on QZX_C1 (advisory tags only; final decision is yours).
# NOTE: com.youku.taitan.tv is BOTH a PCDN host AND, on some boxes, the HOME
#       launcher. The HOME detection below OVERRIDES the bloat tag so you are
#       never told to disable the live launcher.
MINER_PKGS="com.youku.cloud.dog"
BLOAT_PKGS="com.youku.taitan.tv com.ktcp.tvvideo cn.miguvideo.migutv com.gitvvideo.qiaozhixin com.xhm.live com.cibn.tv com.hunantv.market com.elinkway.tvlive"
# System packages that must never be touched.
CRITICAL="android com.android.systemui com.android.settings com.android.phone com.android.inputmethod com.android.keychain com.android.providers com.android.launcher"

echo "############################################################"
echo "#  LMW BOX AUDIT (read-only)"
echo "############################################################"

echo
echo "===== [1] DEVICE / OS ====="
echo "model      : $(getprop ro.product.model)"
echo "device     : $(getprop ro.product.device)"
echo "brand      : $(getprop ro.product.brand)"
echo "android    : $(getprop ro.build.version.release) (sdk $(getprop ro.build.version.sdk))"
echo "yunos      : $(getprop ro.yunos.version)"
echo "fingerprint: $(getprop ro.build.fingerprint)"
echo "serial     : $(getprop ro.serialno)"

echo
echo "===== [2] STORAGE (df /data — likely FAKE on these boxes) ====="
df /data 2>/dev/null
echo "(if total looks huge e.g. 100G+, it is fake-capacity flash — do NOT trust it)"

echo
echo "===== [3] MEMORY ====="
cat /proc/meminfo 2>/dev/null | grep -m1 MemTotal

echo
echo "===== [4] CURRENT HOME LAUNCHER  (>>> NEVER DISABLE THIS <<<) ====="
HOME_PKG=""
# (a) modern surface
HOME_RES="$(cmd package resolve-activity -c android.intent.category.HOME 2>/dev/null | grep -m1 packageName)"
if [ -n "$HOME_RES" ]; then
  HOME_PKG="${HOME_RES#*packageName=}"
  HOME_PKG="${HOME_PKG%% *}"
fi
# (b) 4.4 fallback: scan activity stack for the HOME activity type
if [ -z "$HOME_PKG" ]; then
  HL="$(dumpsys activity 2>/dev/null | grep -m1 -iE 'mHomeProcess|Home_Activity|HOME_ACTIVITY_TYPE|baseActivity.*(Launcher|Home)')"
  echo "  (resolve-activity unavailable; raw activity hint below)"
  echo "  $HL"
fi
if [ -n "$HOME_PKG" ]; then
  echo "  HOME launcher = $HOME_PKG   <-- keep enabled or the box boots to a black screen"
else
  echo "  HOME launcher = (could not resolve automatically; inspect [7] launcher-ish pkgs)"
fi

echo
echo "===== [5] LAN-MEDIA-WALL PLAYER ====="
if pm list packages 2>/dev/null | grep -q "^package:$PLAYER"; then
  verline="$(dumpsys package "$PLAYER" 2>/dev/null | grep -m1 versionName)"
  ver="${verline#*versionName=}"; ver="${ver%% *}"
  echo "  installed: YES  versionName=${ver:-?}"
else
  echo "  installed: NO"
fi

echo
echo "===== [6] RUNNING PROCESSES — miner/PCDN signatures ====="
PS="$(ps 2>/dev/null; ps -A 2>/dev/null)"
HIT="$(echo "$PS" | grep -iE 'jaguar|pcdn|xcdn|jtvcore|miner|xmrig|cloud.dog|taitan')"
if [ -n "$HIT" ]; then
  echo "$HIT"
else
  echo "  (no obvious miner/PCDN process names in ps — still check package tags below)"
fi

echo
echo "===== [7] THIRD-PARTY PACKAGES (auto-tagged) ====="
echo "  TAG legend: [KEEP]=media wall  [HOME]=launcher(keep)  [MINER]  [BLOAT]  [?]=unknown, tell me what it is"
for line in $(pm list packages -3 2>/dev/null); do
  p="${line#package:}"
  # NOTE: `for line in $(pm list packages)` word-splits on IFS which strips any
  # trailing CR toybox emits, so $p is already clean — no printf/tr needed.
  tag="[?]"
  [ "$p" = "$PLAYER" ] && tag="[KEEP]"
  if [ "$p" = "$HOME_PKG" ]; then tag="[HOME]"; fi
  case " $MINER_PKGS " in *" $p "*) [ "$tag" = "[?]" ] && tag="[MINER]";; esac
  case " $BLOAT_PKGS " in *" $p "*) [ "$tag" = "[?]" ] && tag="[BLOAT]";; esac
  echo "  $tag $p"
done

echo
echo "===== [8] ALL PACKAGES with install path (/system=OEM, /data=user-installed) ====="
pm list packages -f 2>/dev/null | grep -iE '/data/app|=com\.|=cn\.|=air\.|=tv\.' | grep -v "=android"

echo
echo "===== [9] AUTOSTART / RECEIVERS hint (who wakes on boot) ====="
dumpsys package 2>/dev/null | grep -iE 'BOOT_COMPLETED' | grep -iE 'com\.|cn\.' 2>/dev/null

echo
echo "===== [10] ROOT COLD-BOOT HOOK MECHANISMS (for lmw_root_daemon persistence) ====="
# Read-only: report which root boot-hook mechanisms THIS ROM actually supports,
# so cold-boot persistence for the daemon is decided on evidence, not guesswork.
if [ -d /system/etc/init.d ]; then
  echo "  init.d dir      : PRESENT (/system/etc/init.d)"
  ls -la /system/etc/init.d 2>/dev/null | grep -v '^total' | grep -v ' \.$' | grep -v ' \.\.$'
else
  echo "  init.d dir      : absent"
fi
RUNPARTS_HIT=""
for rc in /init.rc /init.*.rc /system/etc/init/*.rc; do
  [ -f "$rc" ] || continue
  if grep -q "run-parts" "$rc" 2>/dev/null && grep -q "init\.d" "$rc" 2>/dev/null; then
    RUNPARTS_HIT="$rc"; break
  fi
done
[ -n "$RUNPARTS_HIT" ] && echo "  init.d run-parts: WIRED by $RUNPARTS_HIT (dropping a script there runs at boot)" \
                       || echo "  init.d run-parts: NOT found in any init*.rc (init.d alone would NOT run at boot)"
if [ -f /system/etc/install-recovery.sh ]; then
  echo "  install-recovery: script PRESENT (/system/etc/install-recovery.sh)"
else
  echo "  install-recovery: script absent"
fi
REC_SVC=""
for rc in /init.rc /init.*.rc /system/etc/init/*.rc; do
  [ -f "$rc" ] || continue
  svc="$(grep -m1 install-recovery.sh "$rc" 2>/dev/null)"
  case "$svc" in \#*) svc="";; esac
  [ -n "$svc" ] && { REC_SVC="$rc: $svc"; break; }
done
[ -n "$REC_SVC" ] && echo "  install-recovery service: $REC_SVC" \
                  || echo "  install-recovery service: NOT referenced in any init*.rc"
echo "  (lmw_setup installs a cold-boot hook ONLY where one of the above is real ROM"
echo "   evidence; otherwise it starts the daemon per-boot and says persistence is unwired.)"

echo
echo "############################################################"
echo "#  AUDIT COMPLETE — copy this ENTIRE output back."
echo "#  Nothing was changed. Send report from ONE box per batch."
echo "############################################################"
