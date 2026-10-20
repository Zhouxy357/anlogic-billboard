@echo off
chcp 936 >nul
title 把广告牌图片素材写入 TF 卡
setlocal EnableDelayedExpansion

rem ==================================================================
rem  4_write_card.bat  ——  打包 assets\img 的图片并写进 TF 卡
rem
rem  用法：直接双击本文件（会自动弹出 UAC 申请管理员权限，点"是"）
rem        如果 TF 卡不是 PhysicalDrive1，带参数指定盘号，例如：
rem            4_write_card.bat 2
rem
rem  本脚本做的事：
rem    1. 检查 Python + Pillow
rem    2. 把 assets\img\ 里的图片打包成 container.bin
rem    3. 列出物理盘，让你核对哪一个是 TF 卡
rem    4. 把 container.bin 写进 TF 卡的 1048576 号扇区（= 512 MiB 偏移）
rem ==================================================================

rem ---- ① 写物理磁盘必须要管理员权限，没有就自动提权重开 ----
net session >nul 2>&1
if errorlevel 1 (
  echo   本脚本需要管理员权限（写物理磁盘），正在弹出 UAC 窗口...
  echo   请在弹出的对话框里点"是"。
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
echo   把图片素材写入 TF 卡
echo ------------------------------------------------------------
echo   工程目录   : %PRJ%
echo   目标物理盘 : PhysicalDrive%DRV%
echo ============================================================
echo.

rem ---- ② 找一个带 Pillow 的 Python ----
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
  echo        请先在命令行执行这一句装依赖：
  echo            py -3 -m pip install Pillow
  echo.
  pause
  exit /b 1
)
echo   [1/4] Python 检查通过
echo         !PY!
echo.

rem ---- ③ 确认有图片 ----
if not exist "assets\img\*.jpg" if not exist "assets\img\*.png" (
  echo [错误] assets\img\ 里找不到图片。
  echo        请先把要轮播的横图放进去（建议命名 01.jpg ~ 08.jpg）。
  echo.
  pause
  exit /b 1
)

rem ---- ④ 打包成 container.bin ----
echo   [2/4] 打包图片到 container.bin ...
echo.
!PY! tools\gen_container.py -i assets/img/ -o container.bin
if errorlevel 1 (
  echo.
  echo [错误] 打包失败，请把上面的报错内容发给协助者。
  pause
  exit /b 1
)
if not exist "container.bin" (
  echo [错误] 没有生成 container.bin，打包可能没真正完成。
  pause
  exit /b 1
)
echo.

rem ---- ⑤ 列出物理盘，让用户核对 ----
echo   [3/4] 这台电脑上的物理驱动器一览，请核对：
echo.
!PY! tools\write_container.py --list
echo.
echo   ================  请务必核对  ================
echo   TF 卡 = 容量较小、且 MBR 的那个（一般 7~32 GB）
echo   本脚本接下来要写的是：PhysicalDrive%DRV%
echo.
echo   如果上表里 TF 卡的盘号不是 %DRV%，马上按 Ctrl+C 取消，
echo   然后这样重跑（把 2 换成正确盘号）：
echo        4_write_card.bat 2
echo   ============================================
echo.
pause
echo.

rem ---- ⑥ 正式写入（工具内部还会再要求输入大写 YES） ----
echo   [4/4] 开始写入 ...
echo.
!PY! tools\write_container.py \\.\PhysicalDrive%DRV% --input container.bin --lba 1048576
set "RC=!errorlevel!"
echo.

if "!RC!"=="0" (
  echo ============================================================
  echo   写入完成！
  echo ------------------------------------------------------------
  echo   接下来三步：
  echo     1. 在 Windows 里"安全弹出"这张卡，再拔读卡器
  echo     2. 把 TF 卡插到开发板【背面】的卡槽
  echo     3. 在 TD 里用 BitWriter 烧 billboard_Runs\phy_1\billboard.bit
  echo ============================================================
) else (
  echo ============================================================
  echo   写入没有成功，返回码 !RC!。常见原因：
  echo     - 盘号不对    ：用 4_write_card.bat 2 换个盘号再试
  echo     - 卡被占用    ：关掉资源管理器里打开该卡的窗口再试
  echo     - 没点"是"    ：UAC 授权被拒，重新双击本文件
  echo ============================================================
)
echo.
pause
endlocal
