@echo off
rem Splitscreen4P - remove the mod (ezz BOIII and the game stay). UNINSTALL.cmd ["game folder"]
setlocal
set "PS1=%~dp0setup\splitscreen-setup.ps1"
if not exist "%PS1%" set "PS1=%~dp0splitscreen-setup.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Action uninstall -GamePath "%~1"
echo.
pause
