@echo off
setlocal enabledelayedexpansion
REM ==========================================================================
REM  lmw_update.bat - PC-side one-command updater for the LAN-Media-Wall Player
REM  on YunOS/AliOS 4.4.2 boxes (fake-flash, root adb).
REM
REM  The ON-BOX script must reboot the box mid-install and a reboot kills the
REM  shell running it, so the box-side work is split across two runs. THIS bat
REM  bridges that reboot for you (adb wait-for-device + boot_completed poll),
REM  so from your PC it really is a single command.
REM
REM  The APK can be named ANYTHING. Three ways to point at it:
REM     1) DRAG the .apk onto this .bat in Explorer               (easiest)
REM     2) lmw_update.bat "C:\path\to\whatever-name.apk"
REM     3) drop ONE .apk next to this .bat and just run:  lmw_update.bat
REM        (if several .apk are present it picks the NEWEST one)
REM
REM  Optional 2nd arg FORCE = clean reinstall (use when the signing key changed
REM  and KitKat would otherwise reject the in-place upgrade).
REM ==========================================================================

set "SCRIPT_DIR=%~dp0"
set "APK=%~1"
set "FORCE=%~2"

REM If no APK passed, auto-pick the newest *.apk sitting next to this script.
if "%APK%"=="" (
  echo No APK given - looking for the newest *.apk next to this script...
  for /f "delims=" %%F in ('dir /b /a-d /o-d "%SCRIPT_DIR%*.apk" 2^>nul') do (
    if not defined APK set "APK=%SCRIPT_DIR%%%F"
  )
  if "!APK!"=="" (
    echo ERROR: no .apk found. Drag an APK onto this .bat, or pass its path.
    pause
    exit /b 1
  )
  echo Using newest: !APK!
)

if not exist "%APK%" (
  echo ERROR: APK not found: %APK%
  pause
  exit /b 1
)

if not exist "%SCRIPT_DIR%lmw_provision.sh" (
  echo ERROR: lmw_provision.sh not found next to this script.
  pause
  exit /b 1
)

echo === Checking device ===
adb get-state 1>nul 2>nul || ( echo ERROR: no adb device. Plug in / enable adb. & pause & exit /b 1 )

echo === Pushing APK + provisioner ===
adb push "%APK%" /data/local/tmp/lmw_player.apk || ( pause & exit /b 1 )
adb push "%SCRIPT_DIR%lmw_provision.sh" /data/local/tmp/lmw_provision.sh || ( pause & exit /b 1 )

echo === Reset phase (fresh run) ===
adb shell "rm -f /data/local/tmp/lmw_phase"

echo === Phase 1: install + reboot ===
if /I "%FORCE%"=="FORCE" (
  adb shell sh /data/local/tmp/lmw_provision.sh FORCE
) else (
  adb shell sh /data/local/tmp/lmw_provision.sh
)

echo === Waiting for the box to go down and come back ===
ping -n 6 127.0.0.1 >nul
adb wait-for-device
echo === Device reconnected, waiting for boot to complete ===
:waitboot
set "BOOTED="
for /f "usebackq delims=" %%B in (`adb shell getprop sys.boot_completed 2^>nul`) do set "BOOTED=%%B"
set "BOOTED=%BOOTED: =%"
if not "%BOOTED%"=="1" (
  ping -n 3 127.0.0.1 >nul
  goto waitboot
)
ping -n 4 127.0.0.1 >nul

echo === Phase 2: verify + autostart + clean ===
if /I "%FORCE%"=="FORCE" (
  adb shell sh /data/local/tmp/lmw_provision.sh FORCE
) else (
  adb shell sh /data/local/tmp/lmw_provision.sh
)

echo.
echo === Done. If you saw "PROVISION COMPLETE" above, the box is updated. ===
echo     The new version is whatever was inside the APK you pushed.
pause
endlocal
