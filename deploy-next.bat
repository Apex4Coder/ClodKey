@echo off
rem ============================================================
rem deploy-next.bat - double-click entry for deploy.ps1
rem (app-next -> live, backup + rollback, launch from live).
rem ASCII only + CRLF, do NOT "improve" (OEM codepage rule).
rem ============================================================
setlocal EnableExtensions
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1"
echo.
pause
