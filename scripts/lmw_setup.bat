@echo off
setlocal enabledelayedexpansion
REM ==========================================================================
REM  lmw_setup.bat - ONE PC-side command that does EVERYTHING for a LAN-Media
REM  -Wall kiosk box (YunOS/AliOS 4.4.2 QZX_C1, root adb):
REM     install/upgrade player  +  arm push-update helper  +  disable all other
REM     apps  +  make the box boot straight into the media wall.
REM
REM  It bridges the mid-setup reboot for you, so from your PC this is literally
REM  one command. Replaces lmw_update.bat + lmw_provision.sh + lmw_clean.bat.
REM
REM  USAGE:
REM     lmw_setup.bat "C:\path\to\LANMediaWall-Player-Android.apk"  [FLAGS...]
REM
REM  FLAGS (optional, pass after the APK path, space-separated):
REM     FORCE      clean reinstall (uninstall+wipe first) - for signature-change
REM                upgrades KitKat would otherwise reject
REM     NOCLEAN    install/upgrade only; do NOT disable other apps
REM     KEEPDEBUG  keep file-manager + wukong remote helper for debugging
REM     NOUNINST   disable everything but do NOT uninstall /data junk
REM
REM  REQUIREMENTS: adb in PATH; box reachable (USB or `adb connect <ip>`);
REM  lmw_setup.sh + lmw_root_helper next to this .bat.
REM ==========================================================================

set "APK=%~1"
if "%APK%"=="" (
  echo ERROR: pass the player APK path as the first argument.
  echo   lmw_setup.bat "C:\path\to\LANMediaWall-Player-Android.apk" [FORCE^|NOCLEAN^|KEEPDEBUG^|NOUNINST]
  exit /b 1
)
if not exist "%APK%" ( echo ERROR: APK not found: %APK% & exit /b 1 )

set "HERE=%~dp0"
if not exist "%HERE%lmw_setup.sh"     ( echo ERROR: lmw_setup.sh not found next to this bat.     & exit /b 1 )
if not exist "%HERE%lmw_root_helper"  ( echo ERROR: lmw_root_helper not found next to this bat.  & exit /b 1 )

REM collect flags (args 2..N)
set "FLAGS="
shift
:collectflags
if "%~1"=="" goto flagsdone
set "FLAGS=!FLAGS! %~1"
shift
goto collectflags
:flagsdone

echo === LAN Media Wall kiosk setup ===
echo   APK   : %APK%
echo   flags :!FLAGS!
echo.

echo [1/5] waiting for device (adb)...
adb wait-for-device || ( echo ERROR: no device. Connect USB or run: adb connect ^<box-ip^> & exit /b 1 )
adb root >nul 2>&1
adb wait-for-device

echo [2/5] pushing setup script, helper binary, and APK to the box...
adb push "%HERE%lmw_setup.sh"    /data/local/tmp/lmw_setup.sh        || ( echo ERROR: push setup.sh failed & exit /b 1 )
adb push "%HERE%lmw_root_helper" /data/local/tmp/lmw_root_helper.new || ( echo ERROR: push helper failed   & exit /b 1 )
adb push "%APK%"                 /data/local/tmp/lmw_player.apk      || ( echo ERROR: push apk failed      & exit /b 1 )
adb shell chmod 755 /data/local/tmp/lmw_setup.sh

echo [3/5] phase 1: install/upgrade player (box will reboot once)...
adb shell "sh /data/local/tmp/lmw_setup.sh!FLAGS!"

echo     waiting for the box to reboot and come back...
REM give it a moment to actually start rebooting before we wait
ping -n 6 127.0.0.1 >nul
adb wait-for-device
adb root >nul 2>&1
adb wait-for-device
REM let the package scanner + boot settle
ping -n 16 127.0.0.1 >nul

echo [4/5] phase 2: arm helper + disable everything + bind HOME...
adb shell "sh /data/local/tmp/lmw_setup.sh!FLAGS!"

echo [5/5] verifying player is installed and enabled...
adb shell "pm list packages | grep -i lanmediawall.player"
echo.
echo === DONE. If you saw 'SETUP COMPLETE' above, the box is now a media-wall-only kiosk. ===
echo     To undo the app-disabling later:  push+run lmw_restore.sh, or reflash.
endlocal
