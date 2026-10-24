@echo off
rem soozmsg.cmd -- run soozmsg.ps1 from cmd or PowerShell without changing the
rem execution policy. Keep it in the same folder as soozmsg.ps1, on your PATH.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0soozmsg.ps1" %*
exit /b %ERRORLEVEL%
