@echo off
chcp 936 >nul
title 一键写入广告牌素材到 TF 卡
setlocal EnableDelayedExpansion

rem ==================================================================
rem  4_write_card_auto.bat  ——  无人值守写卡（不需要手动输入 YES）
rem
rem  和 4_write_card.bat 的区别：
rem     原版要 回车 + 输入 YES 两次确认；
rem     本版只要双击 + UAC 点"是"，其余全自动。
rem
rem  用法：
rem     双击本文件
rem     TF 卡不是 PhysicalDrive1 时，在命令行带盘号：
rem         4_write_card_auto.bat 2
rem ==================================================================

net session >nul 2>&1
if errorlevel 1 (
  echo   需要管理员权限（要写物理磁盘），正在弹出 UAC，请点"是"...
  if "%~1"=="" (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  ) else (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '%~1'"
  )
  exit /b
)

cd /d "%~dp0.." || (echo [错误] 进不了工程目录 & pause & exit /b 1)
set "PRJ=%CD%"

set "DRV=%~1"
if "%DRV%"=="" set "DRV=1"

echo ============================================================
echo   一键写入广告牌素材
echo ------------------------------------------------------------
echo   工程目录   : %PRJ%
echo   目标物理盘 : PhysicalDrive%DRV%
echo ============================================================
echo.

rem ---- 找带 Pillow 的 Python ----
set "PY="
py -3 -c "import PIL" >nul 2>&1 && set "PY=py -3"
if not defined PY (
  if exist "C:\Users\asus\.workbuddy\binaries\python\versions\3.13.12\python.exe" (
    "C:\Users\asus\.workbuddy\binaries\python\versions\3.13.12\python.exe" -c "import PIL" >nul 2>&1
    if not errorlevel 1 set "PY=C:\Users\asus\.workbuddy\binaries\python\versions\3.13.12\python.exe"
  )
)
if not defined PY (
  echo [错误] 找不到带 Pillow 的 Python。
  pause
  exit /b 1
)
echo   [1/4] Python 检查通过
echo.

rem ---- 确认有图片 ----
if not exist "assets\img\*.jpg" if not exist "assets\img\*.png" (
  echo [错误] assets\img\ 里找不到图片。
  pause
  exit /b 1
)

rem ---- 打包 ----
echo   [2/4] 打包图片到 container.bin ...
echo.
!PY! tools\gen_container.py -i assets/img/ -o container.bin
if errorlevel 1 (echo.& echo [错误] 打包失败 & pause & exit /b 1)
if not exist "container.bin" (echo [错误] 没生成 container.bin & pause & exit /b 1)
echo.

rem ---- 容器自检（写卡前先确认 container.bin 结构没问题）----
echo   [2.5/4] 容器自检：
echo.
!PY! tools\check_container.py
if errorlevel 1 (
  echo.
  echo [错误] 容器自检没通过，上面有原因。不写卡，先修容器。
  pause
  exit /b 1
)
echo.

rem ---- 列盘核对 ----
echo   [3/4] 物理驱动器一览（请确认 PhysicalDrive%DRV% 就是你的 TF 卡）：
echo.
!PY! tools\write_container.py --list
echo.
echo   ============================================
echo   要写的是 PhysicalDrive%DRV%
echo   如果不对，现在按 Ctrl+C 取消，改用：
echo        4_write_card_auto.bat 2
echo   5 秒后自动开始写入 ...
echo   ============================================
timeout /t 5 /nobreak >nul

rem ---- 正式写入（--yes 跳过手动确认）----
echo.
echo   [4/4] 开始写入 ...
echo.
!PY! tools\write_container.py \\.\PhysicalDrive%DRV% --input container.bin --lba 1048576 --yes
set "RC=!errorlevel!"
echo.

if "!RC!"=="0" (
  echo ============================================================
  echo   写入完成
  echo ------------------------------------------------------------
  echo   接下来：
  echo     1. 在 Windows 里"安全弹出"这张卡，再拔读卡器
  echo     2. 把 TF 卡插到开发板背面的卡槽
  echo     3. BitWriter 烧 bit\2_billboard_full.bit（先烧 bit\1_hdmi_test_colorbar.bit 验通路）
  echo     4. 上板若黑屏，跑 python tools\check_container.py 复核容器
  echo ============================================================
) else (
  echo ============================================================
  echo   写入失败，返回码 !RC! 常见原因：
  echo     - 盘号不对：换一个盘号再试
  echo     - 卡被占用：关掉资源管理器里打开该卡的窗口
  echo     - UAC 被拒：重新双击本文件
  echo ============================================================
)
echo.
pause
endlocal
