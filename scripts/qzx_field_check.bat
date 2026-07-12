@echo off
setlocal enabledelayedexpansion
REM ==========================================================================
REM  qzx_field_check.bat - ONE DOUBLE-CLICK real-device field check for QZX_C1.
REM  Jay plugs in ONE box, double-clicks this file, and gets one folder + report.
REM
REM  (A) RESTART PROOF: proves the app-only restart (RESTART_APP) brings the
REM      Player back AUTOMATICALLY within a bounded timeout - the v1.14.3 field
REM      failure was force-stop landing but the relaunch NOT taking (black kiosk
REM      until a manual am start). It drives the REAL daemon worker over the
REM      AUTHORIZED root path (lmw_root_daemon -restart, the same verify-and-retry
REM      state machine the socket RESTART_APP forks), then polls for the Player
REM      process to reappear and times it. Pulls the daemon's restart evidence log.
REM
REM  (B) BACKEND A/B: runs BOTH video kernels (ExoPlayer vs native MediaPlayer) on
REM      the SAME box + SAME media (box replays its last item via resume_last) for
REM      PLAY_SECONDS each, pulling player.log/logcat/meminfo/gfxinfo/media evidence.
REM
REM  CONSERVATIVE: it NEVER reboots, uninstalls, remounts, clears app data, clears
REM  logcat, or deletes broadly. Its ONLY device writes are the documented A/B
REM  override file and restarting our OWN app - both reverted at the end.
REM
REM  Production socket auth is NOT weakened: lmw_root_daemon -restart is reachable
REM  only by a caller already root (like -probe). If the daemon binary is absent it
REM  falls back to a clearly-labeled MANUAL controller-restart checkpoint.
REM
REM  Usage: double-click, or:  qzx_field_check.bat [serial]
REM  Optional env before running: PLAY_SECONDS (default 60), RESTART_TIMEOUT (30).
REM ==========================================================================

set "SCRIPT_DIR=%~dp0"
set "PKG=com.jieoz.lanmediawall.player"
set "COMPONENT=%PKG%/%PKG%.MainActivity"
set "OVERRIDE=/data/local/tmp/lmw_video_backend"
set "RESTART_LOG=/data/local/tmp/lmw_restart.log"
set "DAEMON=/system/xbin/lmw_root_daemon"
set "LOG_REL=files/logs/player.log"
if "%PLAY_SECONDS%"=="" set "PLAY_SECONDS=60"
if "%RESTART_TIMEOUT%"=="" set "RESTART_TIMEOUT=30"

where adb >nul 2>nul || ( echo ERROR: adb not on PATH. & pause & exit /b 1 )

REM --- device selection: explicit arg, else exactly one attached 'device' ------
set "SERIAL=%~1"
if not "%SERIAL%"=="" goto have_serial
set "COUNT=0"
for /f "skip=1 tokens=1,2" %%A in ('adb devices') do (
  if "%%B"=="device" ( set /a COUNT+=1 & set "SERIAL=%%A" )
)
if "%COUNT%"=="0" ( echo ERROR: no attached 'device'. & adb devices & pause & exit /b 1 )
if %COUNT% GTR 1 (
  echo More than one device attached; re-run as:  %~nx0 ^<serial^>
  adb devices & pause & exit /b 2
)
:have_serial
echo Using device: %SERIAL%

set "ADB=adb -s %SERIAL%"
%ADB% root >nul 2>nul
%ADB% wait-for-device

REM stamp + output folder next to this bat
for /f "tokens=1-4 delims=/:. " %%a in ("%date% %time%") do set "TS=%%a%%b%%c_%%d"
set "TS=%TS: =0%"
set "OUT=%SCRIPT_DIR%qzx_field_%SERIAL%_%TS%"
mkdir "%OUT%" 2>nul
mkdir "%OUT%\restart" 2>nul

REM is the daemon present (drives real worker vs manual fallback)?
set "DAEMON_PRESENT="
for /f "usebackq delims=" %%P in (`%ADB% shell "[ -x %DAEMON% ] && echo yes" 2^>nul`) do set "DAEMON_PRESENT=%%P"
set "DAEMON_PRESENT=%DAEMON_PRESENT: =%"

echo === device info ===
( %ADB% shell "getprop ro.product.model; getprop ro.build.version.release"
  %ADB% shell "dumpsys package %PKG% | grep -m1 versionName"
  %ADB% shell "dumpsys package %PKG% | grep -m1 versionCode"
  echo daemon=%DAEMON% present=%DAEMON_PRESENT% ) > "%OUT%\device.txt" 2>&1

echo.
echo === (A) RESTART PROOF (timeout %RESTART_TIMEOUT%s) ===
REM capture BEFORE state
( echo --- before ---
  echo uptime_s:
  %ADB% shell "cat /proc/uptime"
  echo player_pid:
  %ADB% shell "ps | grep -w %PKG% | grep -v grep"
  echo resumed:
  %ADB% shell "dumpsys activity activities | grep -m1 -i ResumedActivity"
  echo --- wifi before ---
  %ADB% shell "getprop wifi.interface; getprop init.svc.wpa_supplicant; getprop dhcp.wlan0.ipaddress"
  %ADB% shell "ifconfig wlan0 2>/dev/null || ip addr show wlan0 2>/dev/null"
  echo --- daemon probe ---
  %ADB% shell "su 0 %DAEMON% -probe 2>/dev/null || %DAEMON% -probe 2>/dev/null" ) > "%OUT%\restart\before.txt" 2>&1

REM record BEFORE pid to detect the relaunch (new pid = process came back)
set "BEFORE_PID="
for /f "tokens=2" %%P in ('%ADB% shell "ps ^| grep -w %PKG% ^| grep -v grep" 2^>nul') do if not defined BEFORE_PID set "BEFORE_PID=%%P"

set "DAEMON_RC=n/a"
if "%DAEMON_PRESENT%"=="yes" (
  echo   triggering RESTART via authorized daemon worker: %DAEMON% -restart
  REM -restart runs the SAME verify-and-retry worker socket RESTART_APP forks; its
  REM EXIT CODE is the two-signal full-recovery verdict (0 = process up AND activity
  REM resumed). Unreportable activity fails closed, so PASS is never pid-only.
  REM adbd is root on the target fleet; invoke the worker exactly once. A nonzero
  REM verification result is authoritative and must never trigger a second restart.
  %ADB% shell "%DAEMON% -restart 2>&1; echo daemon_exit=$?" > "%OUT%\restart\restart_trigger.txt" 2>&1
  for /f "tokens=2 delims==" %%R in ('findstr /b "daemon_exit=" "%OUT%\restart\restart_trigger.txt"') do set "DAEMON_RC=%%R"
) else (
  echo   *** daemon not found at %DAEMON% ***
  echo   *** restart proof FAIL/INCONCLUSIVE: real worker cannot be executed. ***
  echo FAIL: daemon absent; real RESTART_APP worker was not executed > "%OUT%\restart\restart_trigger.txt"
)

REM SIGNAL 1: poll for the Player process to return (new pid) within the timeout.
set "PROCESS_UP=0"
set "AFTER_PID="
set /a ELAPSED=0
:poll
set "AFTER_PID="
for /f "tokens=2" %%P in ('%ADB% shell "ps ^| grep -w %PKG% ^| grep -v grep" 2^>nul') do if not defined AFTER_PID set "AFTER_PID=%%P"
if defined AFTER_PID if not "%AFTER_PID%"=="%BEFORE_PID%" ( set "PROCESS_UP=1" & goto polled )
if %ELAPSED% GEQ %RESTART_TIMEOUT% goto polled
ping -n 3 127.0.0.1 >nul
set /a ELAPSED+=2
goto poll
:polled

REM SIGNAL 2 (E0001): is OUR component the resumed/focused (frontmost) activity, or
REM is the process up behind the launcher (black kiosk)? EVALUATE it, don't just
REM capture it. ACT = yes (our component) / no (another app) / unsupported (no line).
set "RESUMED_LINE="
for /f "usebackq delims=" %%L in (`%ADB% shell "dumpsys activity activities ^| grep -m1 -iE 'mResumedActivity^|mFocusedActivity'" 2^>nul`) do set "RESUMED_LINE=%%L"
if not defined RESUMED_LINE for /f "usebackq delims=" %%L in (`%ADB% shell "dumpsys window windows ^| grep -m1 -i mCurrentFocus" 2^>nul`) do set "RESUMED_LINE=%%L"
set "ACT=unsupported"
if defined RESUMED_LINE (
  set "ACT=no"
  echo !RESUMED_LINE! | findstr /c:"%PKG%/" >nul && set "ACT=yes"
)

REM full recovery = process up AND activity resumed. Unsupported is inconclusive.
set "RECOVERED=0"
if "%DAEMON_PRESENT%"=="yes" if "%DAEMON_RC%"=="0" if "%PROCESS_UP%"=="1" if "%ACT%"=="yes" set "RECOVERED=1"

( echo trigger_daemon_present=%DAEMON_PRESENT% daemon_exit=%DAEMON_RC%
  echo before_player_pid=%BEFORE_PID%
  echo after_player_pid=%AFTER_PID%
  echo process_up_within_%RESTART_TIMEOUT%s=%PROCESS_UP% elapsed_s=%ELAPSED%
  echo activity_resumed=%ACT% ^(yes=our component frontmost, no=other app frontmost, unsupported=box cannot report^)
  echo resumed_line: !RESUMED_LINE!
  echo fully_recovered=%RECOVERED%
  echo --- after ---
  echo uptime_s ^(must NOT reset - a reset means a REBOOT happened^):
  %ADB% shell "cat /proc/uptime"
  echo --- wifi after ---
  %ADB% shell "getprop wifi.interface; getprop init.svc.wpa_supplicant; getprop dhcp.wlan0.ipaddress"
  %ADB% shell "ifconfig wlan0 2>/dev/null || ip addr show wlan0 2>/dev/null" ) > "%OUT%\restart\after.txt" 2>&1

REM pull the daemon's persistent restart evidence log + a logcat tail
%ADB% shell "cat %RESTART_LOG%"      > "%OUT%\restart\lmw_restart.log"   2>nul
%ADB% shell "cat %RESTART_LOG%.1"    > "%OUT%\restart\lmw_restart.log.1" 2>nul
%ADB% shell "logcat -d -v time -t 400" > "%OUT%\restart\logcat_tail.txt" 2>nul

REM PASS requires BOTH signals. Process up behind the launcher = PARTIAL (the field
REM bug), never PASS. Unsupported activity evidence is inconclusive/failure.
if "%DAEMON_PRESENT%"=="no" (
  set "RESTART_RESULT=FAIL/INCONCLUSIVE: daemon absent; real RESTART_APP worker was not executed."
) else if not "%DAEMON_RC%"=="0" (
  set "RESTART_RESULT=FAIL: daemon restart worker exited %DAEMON_RC%; later process/activity state cannot overwrite that failure."
) else if "%RECOVERED%"=="1" (
  set "RESTART_RESULT=PASS: Player fully recovered in %ELAPSED%s - process up (pid %BEFORE_PID% -^> %AFTER_PID%) AND our activity resumed."
) else if "%PROCESS_UP%"=="1" (
  set "RESTART_RESULT=PARTIAL/FAIL: process returned (pid %BEFORE_PID% -^> %AFTER_PID%) but our activity is NOT frontmost (activity_resumed=%ACT%) - kiosk likely black. See restart\lmw_restart.log."
) else (
  set "RESTART_RESULT=FAIL: Player process did NOT auto-return within %RESTART_TIMEOUT%s. See restart\lmw_restart.log."
)
echo   !RESTART_RESULT!

echo.
echo === (B) BACKEND A/B (exoplayer then mediaplayer, %PLAY_SECONDS%s each) ===
for %%K in (exoplayer mediaplayer) do (
  echo.
  echo   --- kernel: %%K ---
  mkdir "%OUT%\%%K" 2>nul
  %ADB% shell "echo %%K > %OVERRIDE%" 1>nul 2>nul
  %ADB% shell "cat %OVERRIDE%" > "%OUT%\%%K\override_readback.txt" 2>nul
  REM restart via the real daemon worker; fall back to explicit am start
  %ADB% shell "su 0 %DAEMON% -restart 2>/dev/null || (am force-stop %PKG%; sleep 1; am start -n %COMPONENT% -f 0x10200000)" 1>nul 2>nul
  echo     playing %PLAY_SECONDS%s on %%K ...
  ping -n %PLAY_SECONDS% 127.0.0.1 >nul
  %ADB% shell "cat /data/data/%PKG%/%LOG_REL%"   > "%OUT%\%%K\player.log"   2>nul
  %ADB% shell "cat /data/data/%PKG%/%LOG_REL%.1" > "%OUT%\%%K\player.log.1" 2>nul
  %ADB% shell "logcat -d -v time -t 800"         > "%OUT%\%%K\logcat_tail.txt" 2>nul
  %ADB% shell "dumpsys meminfo %PKG%"            > "%OUT%\%%K\meminfo.txt"  2>nul
  %ADB% shell "dumpsys gfxinfo %PKG%"            > "%OUT%\%%K\gfxinfo.txt"  2>nul
  %ADB% shell "ls -l /data/data/%PKG%/files/logs"> "%OUT%\%%K\logs_ls.txt"  2>nul
  echo     collected -^> %OUT%\%%K
)

echo.
echo === restoring box (remove A/B override + relaunch configured kernel) ===
%ADB% shell "rm -f %OVERRIDE%" 1>nul 2>nul
%ADB% shell "su 0 %DAEMON% -restart 2>/dev/null || am start -n %COMPONENT% -f 0x10200000" 1>nul 2>nul

echo.
echo === summarizing A/B (dropped-frame honesty; playback-never-started detector) ===
REM PowerShell summarizer mirroring qzx_field_check.sh's summarize_kernel: parses the
REM authoritative backend_metrics= line, reports Exo dropped_frames as a real number
REM but MediaPlayer as n/a (NOT zero), and flags PLAYBACK-NEVER-STARTED when there is
REM no first_frame AND no prepared/ready line. Writes ab_summary.txt for report.txt.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$out='%OUT%'; $ks=@('exoplayer','mediaplayer');" ^
  "$sb=New-Object System.Text.StringBuilder;" ^
  "foreach($k in $ks){ [void]$sb.AppendLine('['+$k+']');" ^
  "  $lf=Join-Path $out (Join-Path $k 'player.log');" ^
  "  if(!(Test-Path $lf) -or (Get-Item $lf).Length -eq 0){ [void]$sb.AppendLine('  player_log=absent (could not pull)'); continue }" ^
  "  $t=Get-Content $lf;" ^
  "  $ff=($t ^| Select-String 'first_frame rendered').Count;" ^
  "  $pr=($t ^| Select-String 'prepared^|state READY^|onPrepared').Count;" ^
  "  $de=($t ^| Select-String 'dropped_frames count=').Count;" ^
  "  $dt=0; ($t ^| Select-String 'dropped_frames count=(\d+)' ^| %%{ $dt+=[int]$_.Matches[0].Groups[1].Value });" ^
  "  $gc=($t ^| Select-String 'GC_^|dalvikvm.*GC^|concurrent.*GC').Count;" ^
  "  $m=($t ^| Select-String 'backend_metrics=' ^| Select-Object -Last 1);" ^
  "  [void]$sb.AppendLine('  first_frame_events='+$ff+' prepared_events='+$pr+' stall_gc_lines='+$gc);" ^
  "  if($m){ $ml=($m.Line -replace '.*backend_metrics=','');" ^
  "    [void]$sb.AppendLine('  metrics: '+$ml);" ^
  "    $md=''; if($ml -match 'dropped_frames=([^ ]+)'){ $md=$Matches[1] };" ^
  "    if($md -eq 'n/a'){ [void]$sb.AppendLine('  dropped_frames=n/a (kernel has no dropped-frame callback - NOT zero)') }" ^
  "    elseif($md){ [void]$sb.AppendLine('  dropped_frames_total='+$md+' (from backend_metrics)') } }" ^
  "  else { [void]$sb.AppendLine('  metrics: (no backend_metrics line - older build or never logged)') }" ^
  "  if($de -gt 0){ [void]$sb.AppendLine('  dropped_frame_report_events='+$de+' summed_dropped='+$dt) }" ^
  "  if($ff -eq 0 -and $pr -eq 0){ [void]$sb.AppendLine('  PLAYBACK-NEVER-STARTED: no first_frame and no prepared/ready - A/B for this kernel is INCONCLUSIVE (check the box has a resume_last item).') } }" ^
  "Set-Content -Path (Join-Path $out 'ab_summary.txt') -Value $sb.ToString()" 2>nul
if not exist "%OUT%\ab_summary.txt" echo   (summarizer skipped: PowerShell unavailable) > "%OUT%\ab_summary.txt"

echo.
echo === writing report.txt ===
( echo ==================== QZX FIELD CHECK REPORT ====================
  echo serial=%SERIAL%  stamp=%TS%  pkg=%PKG%
  echo.
  echo (A) RESTART PROOF
  echo   !RESTART_RESULT!
  echo   evidence: restart\before.txt restart\after.txt restart\lmw_restart.log restart\logcat_tail.txt
  echo   NOTE: after uptime must be ^>= before uptime - a reset would mean a REBOOT (Wi-Fi risk).
  echo.
  echo (B) BACKEND A/B (same box + same resume_last media; %PLAY_SECONDS%s each^)
  echo   --- per-kernel summary (dropped-frame honesty; playback-never-started) ---
  type "%OUT%\ab_summary.txt"
  echo.
  echo   Compare between kernels: first_frame latency, stalls, dropped_frames
  echo   (Exo real number vs MediaPlayer n/a), errors, GC pressure.
  echo   resume_last ASSUMPTION: both kernels replay the SAME last-pushed item.
  echo   A PLAYBACK-NEVER-STARTED flag = inconclusive for that kernel.
  echo   Raw evidence per kernel in exoplayer\ and mediaplayer\.
  echo ===============================================================
) > "%OUT%\report.txt" 2>&1
type "%OUT%\report.txt"

REM one zip (PowerShell Compress-Archive is always present on Win10+)
powershell -NoProfile -Command "Compress-Archive -Force -Path '%OUT%\*' -DestinationPath '%OUT%.zip'" 1>nul 2>nul
if exist "%OUT%.zip" ( echo ZIP: %OUT%.zip ) else ( echo Send the folder: %OUT% )

echo.
echo DONE. Send me: %OUT%.zip  (or the folder %OUT%)
pause
