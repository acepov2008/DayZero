@echo off
rem ===========================================================================
rem  DayZero setup wizard launcher
rem
rem  Asks for administrator rights (UAC) if needed, then runs DayZero.ps1 with
rem  the PowerShell execution policy bypassed for that one process only. Your
rem  system-wide execution policy is not changed.
rem
rem    DayZero.cmd            normal run
rem    DayZero.cmd -DryRun    only log what would be done, change nothing
rem    DayZero.cmd /console   keep a console window open (for troubleshooting)
rem ===========================================================================
setlocal EnableExtensions
set "DZ_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "DZ_SCRIPT=%~dp0DayZero.ps1"
set "DZ_STYLE=Hidden"
set "DZ_ARGS="
:args
if "%~1"=="" goto argsdone
if /i "%~1"=="/console" (set "DZ_STYLE=Normal") else (set "DZ_ARGS=%DZ_ARGS% %1")
shift
goto args
:argsdone

"%DZ_PS%" -NoProfile -ExecutionPolicy Bypass -Command ^
  "$a = '-NoProfile -ExecutionPolicy Bypass -STA -File ' + [char]34 + $env:DZ_SCRIPT + [char]34 + ' ' + $env:DZ_ARGS;" ^
  "if ($env:DZ_STYLE -eq 'Normal') { $a = '-NoExit ' + $a };" ^
  "try { Start-Process -FilePath $env:DZ_PS -ArgumentList $a -Verb RunAs -WindowStyle $env:DZ_STYLE } catch { Write-Host 'DayZero needs administrator rights to run.'; exit 1 }"
if errorlevel 1 pause
exit /b 0
