@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM One-click bridge for fleets whose old/dead daemon cannot self-update.
REM Run next to lmw_setup.bat, lmw_setup.sh, lmw_root_daemon and devices.txt.

set "HERE=%~dp0"
set "APK=%~1"
set "LIST=%HERE%devices.txt"
set "REPORT=%HERE%lmw_fleet_bootstrap_report.txt"
if "%APK%"=="" (echo ERROR: usage: lmw_fleet_bootstrap.bat "player.apk" [setup flags]& exit /b 1)
if not exist "%APK%" (echo ERROR: APK not found: %APK%& exit /b 1)
if not exist "%LIST%" (echo ERROR: devices.txt not found next to this script.& exit /b 1)
if not exist "%HERE%lmw_setup.bat" (echo ERROR: lmw_setup.bat missing.& exit /b 1)
where adb >nul 2>&1 || (echo ERROR: adb not found in PATH.& exit /b 1)

set "FLAGS="
shift
:flags
if "%~1"=="" goto begin
set "FLAGS=!FLAGS! %~1"
shift
goto flags

:begin
>"%REPORT%" echo LAN Media Wall fleet bootstrap report
set /a TOTAL=0, PASS=0, FAIL=0
for /f "usebackq tokens=* eol=#" %%S in ("%LIST%") do (
  set "SERIAL=%%S"
  if not "!SERIAL!"=="" call :one "!SERIAL!"
)
echo.
echo ===== FLEET SUMMARY: total=!TOTAL! pass=!PASS! fail=!FAIL! =====
echo Report: %REPORT%
if not "!FAIL!"=="0" exit /b 1
exit /b 0

:one
set /a TOTAL+=1
set "SERIAL=%~1"
echo.
echo [!TOTAL!] !SERIAL!
adb connect "!SERIAL!" >nul 2>&1
adb -s "!SERIAL!" wait-for-device || goto one_fail
adb -s "!SERIAL!" root >nul 2>&1
adb -s "!SERIAL!" wait-for-device || goto one_fail
set "BEFORE_DAEMON=unreachable"
for /f "delims=" %%P in ('adb -s "!SERIAL!" shell /system/xbin/lmw_root_daemon -probe 2^>nul') do set "BEFORE_DAEMON=%%P"
set "BEFORE_VERSION=unknown"
for /f "tokens=2 delims==" %%V in ('adb -s "!SERIAL!" shell dumpsys package com.jieoz.lanmediawall.player 2^>nul ^| findstr /c:"versionName="') do if "!BEFORE_VERSION!"=="unknown" set "BEFORE_VERSION=%%V"
set "ANDROID_SERIAL=!SERIAL!"
call "%HERE%lmw_setup.bat" "%APK%" NOCLEAN NOUNINST !FLAGS!
if errorlevel 1 goto one_fail_after
set "AFTER_DAEMON=unreachable"
for /f "delims=" %%P in ('adb -s "!SERIAL!" shell /system/xbin/lmw_root_daemon -probe 2^>nul') do set "AFTER_DAEMON=%%P"
echo !AFTER_DAEMON! | findstr /b /c:"ready " >nul || goto one_fail_after
set "AFTER_VERSION=unknown"
for /f "tokens=2 delims==" %%V in ('adb -s "!SERIAL!" shell dumpsys package com.jieoz.lanmediawall.player 2^>nul ^| findstr /c:"versionName="') do if "!AFTER_VERSION!"=="unknown" set "AFTER_VERSION=%%V"
>>"%REPORT%" echo PASS serial=!SERIAL! before_version=!BEFORE_VERSION! after_version=!AFTER_VERSION! before_daemon=!BEFORE_DAEMON! after_daemon=!AFTER_DAEMON!
set /a PASS+=1
exit /b 0

:one_fail_after
>>"%REPORT%" echo FAIL serial=!SERIAL! before_version=!BEFORE_VERSION! before_daemon=!BEFORE_DAEMON! reason=setup_or_after_probe_failed
set /a FAIL+=1
exit /b 0
:one_fail
>>"%REPORT%" echo FAIL serial=!SERIAL! reason=adb_unreachable
set /a FAIL+=1
exit /b 0
