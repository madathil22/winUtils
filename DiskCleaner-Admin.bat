@echo off
rem WinUtils Disk Cleaner - elevated launcher.
rem Use this one to include protected system folders such as C:\Windows\Temp,
rem the Windows Update cache and Windows.old. You will get a UAC prompt.

setlocal
set "HERE=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File','%HERE%src\DiskCleaner.ps1'"

endlocal
