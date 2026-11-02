@echo off
chcp 65001 >nul
title DSH First Aid
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel%==0 goto run

echo Requesting administrator rights...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
exit /b

:run
if "%~1"=="" goto default
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rescue.ps1" -Fix %*
goto done

:default
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rescue.ps1" -Fix

:done
echo.
echo Finished. Press any key to close.
pause >nul
