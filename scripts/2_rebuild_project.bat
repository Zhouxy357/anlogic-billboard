@echo off
chcp 936 >nul
title 重建 billboard TD 工程（命令行方式）
echo ============================================================
echo   从零重建 billboard TD 工程
echo ============================================================
echo.
echo   作用：创建 billboard.al，加入全部源文件+引脚约束，跑 design 步验证。
echo   用时：约 30 秒。
echo.

set "PRJ=%~dp0.."
set "TDCMD=C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe"

echo [1/4] 检查 TD 命令行程序
echo       %TDCMD%
if exist "%TDCMD%" (echo       [OK] 存在) else (echo       [错误] 找不到 TD！ & pause & exit /b 1)

echo.
echo [2/4] 准备脚本（复制到纯英文临时目录，绕开 TD 的中文路径 bug）
set "TMPD=C:\FPGA\_tmp_tcl"
if not exist "%TMPD%" mkdir "%TMPD%"
copy /y "%~dp0step0_build.tcl" "%TMPD%\step0_build.tcl" >nul
if errorlevel 1 (echo       [错误] 复制失败 & pause & exit /b 1)
echo       [OK] 已就位：%TMPD%\step0_build.tcl

echo.
echo [3/4] 清理旧工程（否则会报 already exists）
if exist "%PRJ%\billboard.al" (
  echo       发现旧工程，正在删除...
  del /q "%PRJ%\billboard.al" 2>nul
  rmdir /s /q "%PRJ%\billboard_Runs" 2>nul
  del /q "%PRJ%\.lock.f" 2>nul
  echo       [OK] 旧工程已清除
) else (
  echo       [OK] 没有旧工程
)

echo.
echo [4/4] 运行 TD 命令行，约 30 秒，请耐心等待...
"%TDCMD%" "%TMPD%\step0_build.tcl" > "%PRJ%\build_logs\step0_run.log" 2>&1

echo.
echo   完成，正在检查结果...
find /I "STEP0 DONE" "%PRJ%\build_logs\step0_run.log" >nul
if not errorlevel 1 (
  echo.
  echo   [成功] 工程已重建，design 步跑通！
  echo          现在可以双击 1_open_project.bat 打开工程。
) else (
  echo.
  echo   [失败] 请打开日志查看原因：
  echo          %PRJ%\build_logs\step0_run.log
)
rmdir /s /q "%TMPD%" 2>nul
echo.
pause
