@echo off
chcp 936 >nul
title 清理 billboard 工程的临时产物
echo ============================================================
echo   清理临时产物（只删"可再生"的文件，不动任何源码/文档）
echo ============================================================
echo.
echo   本脚本会删除下面这些（跑一次脚本/开一次 TD 就会重新生成）：
echo.
echo     sim\ivlogs\          仿真日志（run_iverilog.sh 生成）
echo     sim\ivl_tmp\         iverilog 中间文件
echo     sim\logs\            ModelSim 日志
echo     sim\work\            ModelSim 工作库
echo     sim\transcript       ModelSim 命令行回显
echo     sim\*.wlf            ModelSim 波形文件
echo     sim\modelsim.ini     ModelSim 配置
echo     log\                 TD 自己的控制台日志
echo     .lock.f              TD 异常退出留下的锁文件
echo.
echo   不会动：src\  docs\  sim\tb_*.v  sim\run_*.sh  tools\  两个 .hex
echo.

set "PRJ=%~dp0.."
cd /d "%PRJ%" || (echo [错误] 进不了工程目录 & pause & exit /b 1)

rem ---- 先检查 TD 是否在运行：开着就不动 log\ 和 .lock.f ----
set "TD_RUN=0"
tasklist /FI "IMAGENAME eq td.exe" 2>nul | find /I "td.exe" >nul
if not errorlevel 1 set "TD_RUN=1"

if "%TD_RUN%"=="1" (
  echo   [注意] 检测到 TD 正在运行（td.exe）
  echo          -> log\ 和 .lock.f 先跳过，等你关掉 TD 再跑一次本脚本
  echo.
)

set /p ANS=确认开始清理吗？(y/N) 
if /I not "%ANS%"=="y" (echo 已取消，什么都没删。 & pause & exit /b 0)

echo.
echo [1/4] 清理仿真临时产物...
for %%D in (ivlogs ivl_tmp logs work) do (
  if exist "sim\%%D" (
    rmdir /s /q "sim\%%D" 2>nul
    echo       [OK] 已删 sim\%%D
  ) else (
    echo       [--] sim\%%D 不存在，跳过
  )
)

echo.
echo [2/4] 清理 ModelSim 单文件产物...
for %%F in (transcript modelsim.ini) do (
  if exist "sim\%%F" (
    del /q "sim\%%F" 2>nul
    echo       [OK] 已删 sim\%%F
  ) else (
    echo       [--] sim\%%F 不存在，跳过
  )
)
if exist "sim\*.wlf" (
  del /q "sim\*.wlf" 2>nul
  echo       [OK] 已删 sim\*.wlf
) else (
  echo       [--] sim\*.wlf 不存在，跳过
)

echo.
echo [3/4] 清理 TD 控制台日志...
if "%TD_RUN%"=="1" (
  echo       [跳过] TD 还开着
) else (
  if exist "log" (
    rmdir /s /q "log" 2>nul
    echo       [OK] 已删 log\
  ) else (
    echo       [--] log\ 不存在，跳过
  )
)

echo.
echo [4/4] 清理锁文件...
if "%TD_RUN%"=="1" (
  echo       [跳过] TD 还开着
) else (
  if exist ".lock.f" (
    del /q ".lock.f" 2>nul
    echo       [OK] 已删 .lock.f
  ) else (
    echo       [--] .lock.f 不存在，跳过
  )
)

echo.
echo ============================================================
echo   清理完成。工程现在只剩"源码 + 文档 + 素材 + 编译产物"。
echo   想恢复仿真日志：cd sim 然后 bash run_iverilog.sh
echo ============================================================
pause
