@echo off
rem ===========================================================================
rem  DayZero - first sign-in hook
rem
rem  Started by FirstLogonCommands in autounattend.xml. Windows runs it elevated
rem  for the new administrator account, before the desktop appears, so it only
rem  does quick work: make sure the toolkit is on %SystemDrive%, register the
rem  DayZero scheduled task and start the wizard.
rem
rem    Usage: FirstLogon.cmd <build-id>
rem ===========================================================================
setlocal EnableExtensions
set "BUILD=%~1"
set "DST=%SystemDrive%\DayZero"

rem Running from the USB stick means the specialize-pass copy did not happen: copy now.
if /i not "%~d0"=="%SystemDrive%" call "%~dp0CopyKit.cmd" "%~d0" "%BUILD%"

if not exist "%DST%\bootstrap\FirstLogon.ps1" (
    if not exist "%DST%\Logs" mkdir "%DST%\Logs"
    >>"%DST%\Logs\firstlogon.log" echo [%DATE% %TIME%] DayZero files are missing on %SystemDrive%. Plug in the USB stick and run DayZero\DayZero.cmd by hand.
    exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%DST%\bootstrap\FirstLogon.ps1" -BuildId "%BUILD%"
exit /b %ERRORLEVEL%
