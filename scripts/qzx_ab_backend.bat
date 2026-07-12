@echo off
setlocal enabledelayedexpansion
REM ==========================================================================
REM  qzx_ab_backend.bat - ONE-ACTION A/B of the two video kernels (ExoPlayer vs
REM  native android.media.MediaPlayer) on ONE QZX_C1 box, saving all evidence to
REM  a folder next to this bat.  See scripts/qzx_ab_backend.sh for the full story.
REM
REM  For each kernel (exoplayer, then mediaplayer) it:
REM    1. writes /data/local/tmp/lmw_video_backend  (the only device write; the
REM       app reads it at startup and it beats the saved Settings choice)
REM    2. force-stops + relaunches the kiosk so it rebuilds the player
REM    3. lets it play PLAY_SECONDS (the box replays its last pushed item)
REM    4. pulls the exported player.log + a logcat tail into the output folder
REM  Then it REMOVES the override and relaunches so the box returns to normal.
REM
REM  READ-ONLY except the one override file + restarting our own app (both
REM  reverted at the end). It never installs / reboots / touches media or config.
REM
REM  Usage: plug in ONE box via adb, then double-click this bat.
REM         Optional: set PLAY_SECONDS before running (default 40).
REM ==========================================================================

set "SCRIPT_DIR=%~dp0"
set "PKG=com.jieoz.lanmediawall.player"
set "MAIN=%PKG%/%PKG%.MainActivity"
set "OVERRIDE=/data/local/tmp/lmw_video_backend"
if "%PLAY_SECONDS%"=="" set "PLAY_SECONDS=40"

echo === Checking device ===
adb get-state 1>nul 2>nul || ( echo ERROR: no adb device. Plug in / enable adb. & pause & exit /b 1 )
adb root 1>nul 2>nul
adb wait-for-device

for /f "usebackq delims=" %%S in (`adb shell getprop ro.serialno 2^>nul`) do set "SERIAL=%%S"
set "SERIAL=%SERIAL: =%"
if "%SERIAL%"=="" set "SERIAL=box"
for /f "tokens=1-4 delims=/:. " %%a in ("%date% %time%") do set "TS=%%a%%b%%c_%%d"
set "TS=%TS: =0%"
set "OUT=%SCRIPT_DIR%qzx_ab_%SERIAL%_%TS%"
mkdir "%OUT%" 2>nul

adb shell "getprop ro.product.model; getprop ro.build.version.release" > "%OUT%\device.txt" 2>&1

for %%K in (exoplayer mediaplayer) do (
  echo.
  echo === kernel: %%K ===
  mkdir "%OUT%\%%K" 2>nul
  adb shell "echo %%K > %OVERRIDE%" 1>nul 2>nul
  adb shell "cat %OVERRIDE%" > "%OUT%\%%K\override_readback.txt" 2>&1
  adb shell "am force-stop %PKG%" 1>nul 2>nul
  ping -n 3 127.0.0.1 1>nul
  adb shell "am start -n %MAIN%" 1>nul 2>nul
  echo    playing %PLAY_SECONDS%s on %%K ...
  ping -n %PLAY_SECONDS% 127.0.0.1 1>nul
  adb shell "cat /data/data/%PKG%/files/logs/player.log" > "%OUT%\%%K\player.log" 2>nul
  adb shell "cat /data/data/%PKG%/files/logs/player.log.1" > "%OUT%\%%K\player.log.1" 2>nul
  adb shell "logcat -d -v time -t 600" > "%OUT%\%%K\logcat_tail.txt" 2>nul
  adb shell "dumpsys meminfo %PKG%" > "%OUT%\%%K\meminfo.txt" 2>nul
  echo    collected -^> %OUT%\%%K
)

echo.
echo === restoring box to its configured kernel ===
adb shell "rm -f %OVERRIDE%" 1>nul 2>nul
adb shell "am force-stop %PKG%" 1>nul 2>nul
ping -n 2 127.0.0.1 1>nul
adb shell "am start -n %MAIN%" 1>nul 2>nul

echo.
echo ================ QZX A/B BACKEND DONE ================
echo Evidence saved under: %OUT%
echo Compare player.log between the two kernel folders:
echo   - "first_frame rendered" lines (does it ever show pixels?)
echo   - "state BUFFERING" / "buffering_start" (stalls)
echo   - "dropped_frames" (ExoPlayer only; MediaPlayer = n/a)
echo   - any "error" lines
echo Send me the whole %SERIAL% folder.
echo =====================================================
pause
