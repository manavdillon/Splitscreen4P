@echo off
rem BO3 Splitscreen 4P - check the installation (changes nothing). CHECK.cmd ["game folder"]
setlocal
set "PS1=%~dp0setup\splitscreen-setup.ps1"
if not exist "%PS1%" set "PS1=%~dp0splitscreen-setup.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Action check -GamePath "%~1"
echo.
pause
