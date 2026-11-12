@echo off
rem ===========================================================================
rem  DayZero USB Builder launcher
rem
rem  Asks for administrator rights (UAC; needed to read the Windows image on the
rem  USB stick), then runs builder\Builder.ps1 with the PowerShell execution
rem  policy bypassed for that one process only. Nothing system-wide changes.
rem
rem    Build-DayZeroUSB.cmd            normal run
rem    Build-DayZeroUSB.cmd /console   keep a console window open (troubleshooting)
rem ===========================================================================
setlocal EnableExtensions
set "DZ_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "DZ_SCRIPT=%~dp0builder\Builder.ps1"
set "DZ_STYLE=Hidden"
if /i "%~1"=="/console" set "DZ_STYLE=Normal"

"%DZ_PS%" -NoProfile -ExecutionPolicy Bypass -Command ^
  "$a = '-NoProfile -ExecutionPolicy Bypass -STA -File ' + [char]34 + $env:DZ_SCRIPT + [char]34;" ^
  "if ($env:DZ_STYLE -eq 'Normal') { $a = '-NoExit ' + $a };" ^
  "try { Start-Process -FilePath $env:DZ_PS -ArgumentList $a -Verb RunAs -WindowStyle $env:DZ_STYLE } catch { Write-Host 'The DayZero Builder needs administrator rights to run.'; exit 1 }"
if errorlevel 1 pause
exit /b 0
