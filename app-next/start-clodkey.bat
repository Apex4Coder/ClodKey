@echo off
rem ============================================================
rem start-clodkey.bat - OPTIONAL entry point (ASCII only + CRLF,
rem do NOT "improve": cmd.exe reads .bat in OEM codepage, UTF-8
rem Cyrillic executes as garbage).
rem
rem NOTE: double-clicking a .bat always flashes its own cmd window
rem for a moment. For ZERO windows anywhere (visible or hidden)
rem double-click run-hidden.vbs directly - wscript has no console.
rem
rem Chain: run-hidden.vbs -> WMI Win32_Process.Create
rem (CreateFlags=CREATE_NO_WINDOW, ShowWindow=SW_HIDE)
rem -> powershell ClodKey.ps1 => no console window is EVER created.
rem (DETACHED_PROCESS=8 was tested and kills powershell.exe on
rem Win11; CREATE_NO_WINDOW=16 runs with zero windows.)
rem NO -WindowStyle Hidden: that would create a hidden console
rem window; CREATE_NO_WINDOW means there is nothing to hide.
rem
rem Debug mode: set CK_NO_DETACH=1 -> visible foreground run.
rem ============================================================
setlocal EnableExtensions
cd /d "%~dp0"

if "%CK_NO_DETACH%"=="1" goto foreground

where wscript.exe >nul 2>nul
if errorlevel 1 goto foreground

start "" wscript.exe "%~dp0run-hidden.vbs"
exit /b 0

:foreground
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0ClodKey.ps1"
exit /b 0
