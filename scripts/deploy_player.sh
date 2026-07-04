#!/usr/bin/env bash
#
# deploy_player.sh — batch-install the LAN Media Wall player APK onto a fleet of
# rooted YunOS/AliOS Android 4.4 TV boxes.
#
# WHY THIS EXISTS (the install trap, see commit 5081f9c + AndroidManifest §6.3):
#   These 外贸/山寨 boxes report a bogus recommendAppInstallLocation to the
#   forked PackageManagerService. A normal `adb install` (or `pm install`) hits
#   INSTALL_FAILED_INVALID_INSTALL_LOCATION *before* any force-internal flag
#   applies. The reliable path on these boxes — which default to `adb root` — is
#   to push the APK straight into /data/app and let the next boot's package
#   scanner adopt it, skipping the location recommender entirely.
#
# WHAT IT DOES, per device:
#   1. confirm the device is visible and rooted (adb root / `id` == uid 0)
#   2. push the APK to /data/app/<pkg>-1.apk
#   3. chmod 644 so PackageManager can read it at scan time
#   4. reboot; wait for the box to come back
#   5. verify the package is now installed (pm list packages) + report version
#
# It loops over every attached device (or an explicit serial list) and prints a
# per-device PASS/FAIL summary at the end. Nothing here is destructive to the
# host; on the device it only adds our APK and reboots.
#
# USAGE:
#   scripts/deploy_player.sh <player.apk> [serial ...]
#
#   scripts/deploy_player.sh app-release.apk
#       → deploy to ALL devices listed by `adb devices`
#   scripts/deploy_player.sh app-release.apk 0123456789ABCDEF 192.168.1.44:5555
#       → deploy only to the given serials
#
# ENV OVERRIDES:
#   PKG            package name to verify (default com.jieoz.lanmediawall.player)
#   BOOT_TIMEOUT   seconds to wait for a device to finish rebooting (default 180)
#   SKIP_REBOOT=1  push + chmod only, don't reboot/verify (for staging)
#
# REQUIREMENTS: adb on PATH. Boxes must allow `adb root` (these do by default).
#
# NOTE: not run in CI (no real hardware in the container). Pure shell; lint with
#   `shellcheck scripts/deploy_player.sh` before shipping changes.

set -uo pipefail

PKG="${PKG:-com.jieoz.lanmediawall.player}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
SKIP_REBOOT="${SKIP_REBOOT:-0}"
REMOTE_APK="/data/app/${PKG}-1.apk"

log()  { printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "${1}" "${2}"; }
info() { log "INFO" "$*"; }
warn() { log "WARN" "$*" >&2; }
err()  { log "FAIL" "$*" >&2; }

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '/^!/d'
    exit "${1:-0}"
}

# --- arg parsing ---------------------------------------------------------
[ $# -ge 1 ] || { err "missing APK path"; usage 1; }
case "$1" in -h|--help) usage 0 ;; esac

APK="$1"; shift
if [ ! -f "$APK" ]; then err "APK not found: $APK"; exit 1; fi
command -v adb >/dev/null 2>&1 || { err "adb not on PATH"; exit 1; }

# Explicit serials if given, else every attached 'device' (not 'offline'/etc).
if [ $# -gt 0 ]; then
    DEVICES=("$@")
else
    mapfile -t DEVICES < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
fi
if [ "${#DEVICES[@]}" -eq 0 ]; then
    err "no target devices (none passed, and 'adb devices' shows none ready)"
    exit 1
fi
info "targets: ${DEVICES[*]}"
info "apk: $APK  pkg: $PKG"

# --- per-device helpers --------------------------------------------------

# Run adb for a specific serial.
adbd() { adb -s "$1" "${@:2}"; }

# Ensure adb runs as root on the device; these boxes allow it by default.
ensure_root() {
    local s="$1"
    adbd "$s" root >/dev/null 2>&1 || true
    adbd "$s" wait-for-device
    local uid
    uid="$(adbd "$s" shell id -u 2>/dev/null | tr -d '\r')"
    if [ "$uid" != "0" ]; then
        warn "[$s] adbd is not root (uid=$uid). /data/app push will likely fail."
        return 1
    fi
    return 0
}

# Wait until the device reports boot completed (or time out).
wait_boot() {
    local s="$1" waited=0
    adbd "$s" wait-for-device
    while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
        local done
        done="$(adbd "$s" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
        if [ "$done" = "1" ]; then return 0; fi
        sleep 3; waited=$((waited + 3))
    done
    return 1
}

# Is our package installed on this device?
is_installed() {
    adbd "$1" shell pm list packages 2>/dev/null | tr -d '\r' | grep -q "package:${PKG}$"
}

installed_version() {
    adbd "$1" shell dumpsys package "$PKG" 2>/dev/null \
        | tr -d '\r' | awk -F= '/versionName=/{print $2; exit}'
}

# Deploy to one device. Echoes nothing; sets global RESULT.
deploy_one() {
    local s="$1"
    info "[$s] starting deploy"

    if ! ensure_root "$s"; then
        RESULT="FAIL: not rooted"; return 1
    fi

    info "[$s] pushing APK -> $REMOTE_APK"
    if ! adbd "$s" push "$APK" "$REMOTE_APK" >/dev/null 2>&1; then
        RESULT="FAIL: push failed (is /data writable / rooted?)"; return 1
    fi
    # PackageManager reads the APK at scan time as a non-root user → world-read.
    adbd "$s" shell chmod 644 "$REMOTE_APK" >/dev/null 2>&1 || \
        warn "[$s] chmod failed (continuing; scan may still work)"

    if [ "$SKIP_REBOOT" = "1" ]; then
        RESULT="OK: pushed (reboot/verify skipped)"; return 0
    fi

    info "[$s] rebooting to let the package scanner adopt the APK"
    adbd "$s" reboot >/dev/null 2>&1 || true
    if ! wait_boot "$s"; then
        RESULT="FAIL: device did not finish booting within ${BOOT_TIMEOUT}s"; return 1
    fi

    # Give the package scanner a moment after boot_completed.
    sleep 5
    if is_installed "$s"; then
        local ver; ver="$(installed_version "$s")"
        RESULT="OK: installed ${PKG} ${ver:-(version?)}"; return 0
    fi
    RESULT="FAIL: package not present after reboot"; return 1
}

# --- main loop -----------------------------------------------------------
declare -A SUMMARY
overall=0
for s in "${DEVICES[@]}"; do
    RESULT=""
    if deploy_one "$s"; then
        info "[$s] $RESULT"
    else
        err "[$s] $RESULT"
        overall=1
    fi
    SUMMARY["$s"]="$RESULT"
done

echo
echo "================ DEPLOY SUMMARY ================"
for s in "${DEVICES[@]}"; do
    printf '  %-24s %s\n' "$s" "${SUMMARY[$s]}"
done
echo "==============================================="
exit "$overall"
