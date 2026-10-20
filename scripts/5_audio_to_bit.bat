@echo off
chcp 936 >nul
title 音频素材 → bit（生成 hex / 同步五处 / 重综合 / 出 bit）
setlocal EnableDelayedExpansion

rem ==================================================================
rem  5_audio_to_bit.bat  ——  换音效的一站式脚本
rem
rem  做的事：
rem     [1/4] 调 tools\gen_audio_rom.py 生成 audio_rom.hex
rem           - 不给参数：用 4 段内置提示音
rem           - 拖 1~4 个 wav 到本文件上：用你的 wav（不足 4 段自动补齐）
rem     [2/4] 把 audio_rom.hex 复制到五个位置
rem     [3/4] 跑 TD 全流程综合+布线+出 bit
rem     [4/4] 把成品 bit 复制成 bit\2_billboard_full.bit
rem
rem  用法：
rem     双击本文件                      → 内置 4 段音效
rem     把 wav 拖到本文件图标上          → 用自己的音频
rem ==================================================================

cd /d "%~dp0.." || (echo [错误] 找不到工程目录 & pause & exit /b 1)
set "PRJ=%CD%"

echo ============================================================
echo   换音频素材 → 重新综合 → 出新 bit
echo ------------------------------------------------------------
echo   工程目录 : %PRJ%
echo ============================================================
echo.

rem ---- 找带标准库的 Python（生成 hex 只需要标准库）----
set "PY="
py -3 -c "import wave" >nul 2>&1 && set "PY=py -3"
if not defined PY (
  if exist "C:\Users\asus\.workbuddy\binaries\python\versions\3.13.12\python.exe" (
    set "PY=C:\Users\asus\.workbuddy\binaries\python\versions\3.13.12\python.exe"
  )
)
if not defined PY (
  echo [错误] 找不到可用的 Python
  pause
  exit /b 1
)

rem ---- 收集拖进来的 wav ----
set "WAVS="
set "NW=0"
:collect
if "%~1"=="" goto gotwav
set "WAVS=!WAVS! "%~1""
set /a NW+=1
shift
goto collect
:gotwav

echo   [1/4] 生成 audio_rom.hex ...
echo.
if "!NW!"=="0" (
  echo         未拖入 wav，使用 4 段内置提示音
  "!PY!" tools\gen_audio_rom.py -o audio_rom.hex
) else (
  echo         使用 !NW! 个 wav：
  "!PY!" tools\gen_audio_rom.py -w !WAVS! -o audio_rom.hex
)
if errorlevel 1 (echo. & echo [错误] 生成失败，看上面的提示 & pause & exit /b 1)
if not exist "audio_rom.hex" (echo [错误] 没生成 audio_rom.hex & pause & exit /b 1)
echo.

rem ---- 五处同步 ----
echo   [2/4] 同步 audio_rom.hex 到五处 ...
copy /y "audio_rom.hex" "src\hdl\audio_rom.hex"          >nul & echo         src\hdl\        OK
copy /y "audio_rom.hex" "src\rom\audio_rom.hex"          >nul & echo         src\rom\        OK
copy /y "audio_rom.hex" "sim\audio_rom.hex"              >nul & echo         sim\            OK
if exist "billboard_Runs\syn_1" (
  copy /y "audio_rom.hex" "billboard_Runs\syn_1\audio_rom.hex" >nul & echo         syn_1\          OK
)
echo.

rem ---- 重综合 ----
echo   [3/4] 重新综合 + 布线 + 出 bit（约 3~6 分钟，请勿关闭窗口）
echo.
set "TDCMD=C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe"
if not exist "%TDCMD%" (
  echo [错误] 找不到 TD：%TDCMD%
  pause
  exit /b 1
)
if not exist "build_logs" mkdir "build_logs"

"%TDCMD%" "%PRJ%\scripts\build_all.tcl" > "%PRJ%\build_logs\build_all.log" 2>&1

find /I "BUILD: ALL DONE" "%PRJ%\build_logs\build_all.log" >nul
if errorlevel 1 (
  echo.
  echo   [失败] 综合没走完，日志在：
  echo          %PRJ%\build_logs\build_all.log
  echo   搜索 ERROR 行看原因（WARNING 可忽略）
  pause
  exit /b 1
)
echo         [OK] 综合布线通过
echo.

rem ---- 出 bit ----
echo   [4/4] 复制 bit 到 bit\2_billboard_full.bit ...
if not exist "bit" mkdir "bit"
if not exist "billboard_Runs\phy_1\billboard.bit" (
  echo [错误] 没生成 billboard.bit
  pause
  exit /b 1
)
copy /y "billboard_Runs\phy_1\billboard.bit" "bit\2_billboard_full.bit" >nul
echo         [OK] bit\2_billboard_full.bit 已更新
echo.

echo ============================================================
echo   全部完成
echo ------------------------------------------------------------
echo   下一步：
echo     1. 打开 TD，Tools -^> BitWriter
echo     2. 选 bit\2_billboard_full.bit，先 Program SRAM 验证
echo     3. 确认声音正常后，再 Program FLASH 固化
echo.
echo   注意：这次只换了音频，TF 卡不用重写。
echo ============================================================
echo.
pause
endlocal
