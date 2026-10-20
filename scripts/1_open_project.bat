@echo off
chcp 936 >nul
title 启动 billboard TD 工程
echo ============================================================
echo   启动 Anlogic TD 并打开 billboard 工程
echo ============================================================
echo.

rem 用 bat 自身位置推导工程根目录（整个工程换路径也不坏）
set "PRJ=%~dp0.."
set "AL=%PRJ%\billboard.al"
set "TD=C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td.exe"

echo [1/4] 检查 TD 程序
echo       %TD%
if exist "%TD%" (echo       [OK] 存在) else (echo       [错误] 找不到 TD！请确认安路 TD 装在 C:\Anlogic\ & pause & exit /b 1)

echo.
echo [2/4] 检查工程文件
echo       %AL%
if exist "%AL%" (echo       [OK] 存在) else (echo       [错误] 找不到 billboard.al！工程可能被移动了 & pause & exit /b 1)

echo.
echo [3/4] 检查 TD 是否已经在运行
tasklist /FI "IMAGENAME eq td.exe" 2>nul | find /I "td.exe" >nul
if not errorlevel 1 (
  echo       [注意] TD 已经在运行了！
  echo.
  echo       *** 安路 TD 同一时刻只能开一个实例 ***
  echo       所以这次双击看起来"没反应"，其实是因为 TD 早开着了。
  echo.
  echo       解决办法（二选一）：
  echo         A. 切到已经开着的那个 TD 窗口，看标题栏是不是
  echo            Anlogic TD 6.2.1 - C:/FPGA/billboard_prj - billboard
  echo            如果是，说明工程早打开了，直接用即可。
  echo         B. 想重新开：先全部关掉 TD（任务管理器结束 td.exe），再双击本文件。
  echo.
  pause
  exit /b 0
)

echo       [OK] 当前没有 TD 在运行，可以启动

echo.
echo [4/4] 清理残留锁文件（TD 上次没正常退出会留下 .lock.f）
if exist "%PRJ%\.lock.f" (
  del /q "%PRJ%\.lock.f" 2>nul
  echo       [OK] 已删除残留 .lock.f
) else (
  echo       [OK] 没有残留锁文件
)

echo.
echo   正在拉起 TD，请稍等 10~30 秒...
echo   打开成功后，TD 标题栏应显示：
echo       Anlogic TD 6.2.1 - C:/FPGA/billboard_prj - billboard
echo.
start "" "%TD%" "%AL%"
echo   已发送启动命令。本窗口 5 秒后自动关闭。
timeout /t 5 >nul
