@echo off
rem WinUtils Disk Cleaner - normal launcher.
rem Scans your drive and shows what is using the space.

setlocal
set "HERE=%~dp0"

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden ^
  -File "%HERE%src\DiskCleaner.ps1"

endlocal
