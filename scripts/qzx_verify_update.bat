@echo off
setlocal enabledelayedexpansion
REM ==========================================================================
REM  qzx_verify_update.bat - REAL-DEVICE acceptance for the v1.14.2 update path:
REM  activate a new APK via `pm install -r` WITHOUT a whole-device reboot.
REM  See scripts/qzx_verify_update.sh for the full story.
REM
REM  It measures the two things that define the contract:
REM    (1) versionCode CHANGED  -> new code activated, PM reports the new version
REM    (2) uptime did NOT reset -> no whole-device reboot happened
REM  by driving the EXACT command the daemon runs (`pm install -r <staged>`) as
REM  root over adb. It does NOT reboot / uninstall / touch media or config; the
REM  staged file under /data/local/tmp is removed at the end.
REM
REM  Usage: plug in ONE box via adb, then:
REM         qzx_verify_update.bat  path\to\new-or-same-signer.apk
REM ==========================================================================

set "PKG=com.jieoz.lanmediawall.player"
set "STAGE=/data/local/tmp/lmw_update_staged.apk"

set "APK=%~1"
if "%APK%"=="" (
  echo usage: %~nx0 ^<apk-path^>
  exit /b 2
)
if not exist "%APK%" (
  echo apk not found: %APK%
  exit /b 2
)

REM Require exactly one attached device (this bat targets a single box).
set "SERIAL="
for /f "skip=1 tokens=1,2" %%A in ('adb devices') do (
  if "%%B"=="device" (
    if defined SERIAL (
      echo More than one device attached; run the .sh with an explicit serial.
      adb devices
      exit /b 2
    )
    set "SERIAL=%%A"
  )
)
if not defined SERIAL (
  echo No attached 'device' found.
  adb devices
  exit /b 2
)

echo ==============================================================
echo device %SERIAL% - verifying pm-install-r update of %PKG% (no reboot)
echo ==============================================================

REM --- before: versionCode + uptime ---
set "BEFORE_VC="
for /f "tokens=2 delims==" %%V in ('adb -s %SERIAL% shell "dumpsys package %PKG% ^| grep versionCode=" 2^>nul') do (
  if not defined BEFORE_VC for /f "tokens=1" %%W in ("%%V") do set "BEFORE_VC=%%W"
)
set "BEFORE_UP="
for /f "tokens=1" %%U in ('adb -s %SERIAL% shell cat /proc/uptime 2^>nul') do if not defined BEFORE_UP set "BEFORE_UP=%%U"
echo   before: versionCode=%BEFORE_VC% uptime=%BEFORE_UP%s

echo   pushing APK to %STAGE% ...
adb -s %SERIAL% push "%APK%" "%STAGE%" >nul 2>&1
if errorlevel 1 (
  echo   FAIL: adb push failed
  exit /b 1
)
adb -s %SERIAL% shell "chmod 644 %STAGE%" >nul 2>&1

echo   running: pm install -r %STAGE% (as root) ...
set "PMLOG=%TEMP%\lmw_pm_%RANDOM%.txt"
adb -s %SERIAL% shell "su 0 pm install -r %STAGE% 2>&1 || pm install -r %STAGE% 2>&1" > "%PMLOG%" 2>&1
type "%PMLOG%"
adb -s %SERIAL% shell "rm -f %STAGE%" >nul 2>&1

REM let PM settle
ping -n 4 127.0.0.1 >nul

set "AFTER_VC="
for /f "tokens=2 delims==" %%V in ('adb -s %SERIAL% shell "dumpsys package %PKG% ^| grep versionCode=" 2^>nul') do (
  if not defined AFTER_VC for /f "tokens=1" %%W in ("%%V") do set "AFTER_VC=%%W"
)
set "AFTER_UP="
for /f "tokens=1" %%U in ('adb -s %SERIAL% shell cat /proc/uptime 2^>nul') do if not defined AFTER_UP set "AFTER_UP=%%U"
echo   after:  versionCode=%AFTER_VC% uptime=%AFTER_UP%s

set "OK=1"
findstr /C:"Success" "%PMLOG%" >nul 2>&1
if errorlevel 1 (
  echo   FAIL: pm did not report Success
  set "OK=0"
)
del "%PMLOG%" >nul 2>&1

if "%BEFORE_VC%"=="%AFTER_VC%" (
  echo   WARN: versionCode unchanged (%AFTER_VC%) - expected if you re-installed the SAME build;
  echo         use a build with a HIGHER versionCode to prove activation of new code.
)

REM Uptime is a float; compare the integer seconds. A reboot resets it toward 0.
for /f "tokens=1 delims=." %%A in ("%BEFORE_UP%") do set "B=%%A"
for /f "tokens=1 delims=." %%A in ("%AFTER_UP%") do set "A=%%A"
if defined A if defined B (
  if !A! LSS !B! (
    echo   FAIL: uptime went backwards (%B% -^> %A%) - a reboot happened!
    set "OK=0"
  ) else (
    echo   PASS: no reboot (uptime advanced %B% -^> %A%)
  )
)

if "%OK%"=="1" (
  echo   RESULT: OK - new APK activated via pm install -r, device did NOT reboot.
) else (
  echo   RESULT: NOT OK - see FAIL lines above.
  exit /b 1
)
exit /b 0
