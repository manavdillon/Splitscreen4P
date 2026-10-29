@echo off
rem Splitscreen4P - install (or update). Double-click, or: INSTALL.cmd "D:\Games\Call of Duty Black Ops III"
setlocal
set "PS1=%~dp0setup\splitscreen-setup.ps1"
if not exist "%PS1%" set "PS1=%~dp0splitscreen-setup.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Action install -GamePath "%~1"
echo.
pause
