@echo off
rem 一键打开 billboard TD 工程（纯英文路径，已避开 TD 中文路径 bug）
rem 简易版：不自检、不停留。想看详细自检请用 "①打开TD工程(点这个).bat"
set "PRJ=%~dp0.."
set "TD=C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td.exe"
set "AL=%PRJ%\billboard.al"
if not exist "%AL%" ( echo [错误] 找不到 %AL% & pause & exit /b 1 )
start "" "%TD%" "%AL%"
