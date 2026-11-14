@echo off
rem DSH Web tray launcher. Arguments are forwarded verbatim to dsh-web-tray.ps1.
rem   dsh-web-tray.cmd                  start with data\config.json
rem   dsh-web-tray.cmd -Port 8311       override the port for this run
rem   dsh-web-tray.cmd -NoWindow        host only, do not open a window
rem The long-running tray uses Windows PowerShell 5.1 from Windows, not user-installed pwsh 7.
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-web-tray.ps1" %*
exit /b %errorlevel%
