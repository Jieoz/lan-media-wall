@echo off
setlocal
REM ==========================================================================
REM  lmw_restore.bat - UNDO lmw_setup.bat's cleanup. Re-enables every disabled
REM  package so the box goes back to a normal launcher. Does NOT reinstall apps
REM  that were uninstalled from /data (reflash or re-sideload for those).
REM  Requires lmw_restore.sh next to this bat.
REM ==========================================================================
set "HERE=%~dp0"
if not exist "%HERE%lmw_restore.sh" ( echo ERROR: lmw_restore.sh not found next to this bat. & exit /b 1 )

echo waiting for device...
adb wait-for-device || ( echo ERROR: no device. & exit /b 1 )
adb root >nul 2>&1
adb wait-for-device
adb push "%HERE%lmw_restore.sh" /data/local/tmp/lmw_restore.sh || ( echo ERROR: push failed & exit /b 1 )
adb shell "sh /data/local/tmp/lmw_restore.sh"
echo.
echo rebooting box so the stock launcher returns...
adb reboot
echo === RESTORE DONE. ===
endlocal
