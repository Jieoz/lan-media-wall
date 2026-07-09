@echo off
setlocal enabledelayedexpansion
REM ==========================================================================
REM  lmw_audit.bat - PC-side READ-ONLY box auditor.
REM
REM  Pushes lmw_audit.sh into the box, runs it, and SAVES the full report to
REM  a text file next to this bat named  audit_<serial>_<timestamp>.txt
REM  so you can send me one file per box. Changes NOTHING on the box.
REM
REM  Usage: plug in ONE box via adb, then double-click this bat (or run it).
REM         Repeat for each box; each run makes its own report file.
REM ==========================================================================

set "SCRIPT_DIR=%~dp0"

if not exist "%SCRIPT_DIR%lmw_audit.sh" (
  echo ERROR: lmw_audit.sh not found next to this bat.
  pause & exit /b 1
)

echo === Checking device ===
adb get-state 1>nul 2>nul || ( echo ERROR: no adb device. Plug in / enable adb. & pause & exit /b 1 )

REM Build a filename-safe timestamp + serial.
for /f "usebackq delims=" %%S in (`adb shell getprop ro.serialno 2^>nul`) do set "SERIAL=%%S"
set "SERIAL=%SERIAL: =%"
if "%SERIAL%"=="" set "SERIAL=box"
for /f "tokens=1-4 delims=/:. " %%a in ("%date% %time%") do set "TS=%%a%%b%%c_%%d"
set "TS=%TS: =0%"
set "OUT=%SCRIPT_DIR%audit_%SERIAL%_%TS%.txt"

echo === Pushing auditor ===
adb push "%SCRIPT_DIR%lmw_audit.sh" /data/local/tmp/lmw_audit.sh || ( pause & exit /b 1 )

echo === Running READ-ONLY audit (nothing is changed) ===
echo Saving report to: %OUT%
adb shell sh /data/local/tmp/lmw_audit.sh > "%OUT%" 2>&1

echo.
type "%OUT%"
echo.
echo === Done. Report saved to: %OUT%
echo     Send me this file (one per box) and I'll build the cleanup list.
pause
endlocal
