@echo off
rem ============================================================
rem  Android OTA 离线检测器 — 现场操作员双击即用
rem  本工具无需安装 Python:直接调用同目录下的
rem  android_ota\android_ota_diag.exe(独立 Windows 可执行文件)。
rem  选择设备诊断 ZIP 后,会在其旁边生成中文结果 *-OTA检测结果.txt。
rem ============================================================
chcp 65001 >nul
setlocal enableextensions
set "HERE=%~dp0"
set "EXE=%HERE%android_ota\android_ota_diag.exe"
set "PROFILE=%HERE%android_ota\profiles\qzx-yunos-4.4.json"

if not exist "%EXE%" (
  echo [错误] 未找到检测程序:"%EXE%"
  echo 请确认已完整解压 QZX Update Tools 压缩包。
  goto :hold
)
if not exist "%PROFILE%" (
  echo [错误] 未找到默认 profile:"%PROFILE%"
  goto :hold
)

rem 诊断包路径:优先用命令行参数;否则弹出 Windows 文件选择框。
set "BUNDLE=%~1"
if "%BUNDLE%"=="" (
  if defined LMW_OTA_NONINTERACTIVE (
    echo [错误] 无人值守模式下必须以参数传入诊断包路径。
    goto :hold
  )
  echo 请在弹出的窗口中选择设备诊断 ZIP 文件...
  for /f "usebackq delims=" %%F in (`powershell -NoProfile -STA -Command "Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.OpenFileDialog; $d.Filter = 'OTA 诊断包 (*.zip)|*.zip|所有文件 (*.*)|*.*'; $d.Title = '选择设备 OTA 诊断 ZIP'; if ($d.ShowDialog() -eq 'OK') { $d.FileName }"`) do set "BUNDLE=%%F"
)

if "%BUNDLE%"=="" (
  echo 未选择任何文件,已取消。
  goto :hold
)
if not exist "%BUNDLE%" (
  echo [错误] 诊断包不存在:"%BUNDLE%"
  goto :hold
)

set "RESULT=%BUNDLE%-OTA检测结果.txt"
echo 正在分析:"%BUNDLE%"
"%EXE%" --profile "%PROFILE%" --human analyze "%BUNDLE%" > "%RESULT%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo [错误] 检测程序返回码 %RC%,分析失败。详见:"%RESULT%"
  goto :hold
)
echo.
echo ===== 检测结果(已保存到 "%RESULT%") =====
type "%RESULT%"
echo.
echo 结果文件:"%RESULT%"

:hold
if defined LMW_OTA_NONINTERACTIVE goto :eof
echo.
pause
