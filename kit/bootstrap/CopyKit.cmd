@echo off
rem ===========================================================================
rem  DayZero - copy the toolkit from the USB stick to %SystemDrive%\DayZero
rem
rem  Called by autounattend.xml in the "specialize" pass (while the USB stick is
rem  still plugged in), and again from FirstLogon.cmd if that copy did not happen.
rem
rem    Usage: CopyKit.cmd <usb-drive, e.g. E:> <build-id>
rem
rem  Safe to run more than once: it does nothing when the copy is already there.
rem  The marker file is copied last, so it only exists when the copy is complete.
rem ===========================================================================
setlocal EnableExtensions
set "SRC=%~1\DayZero"
set "BUILD=%~2"
set "DST=%SystemDrive%\DayZero"

if "%BUILD%"=="" exit /b 2
if not exist "%SRC%\build-%BUILD%.marker" exit /b 2
if exist "%DST%\build-%BUILD%.marker" exit /b 0

if not exist "%DST%\Logs" mkdir "%DST%\Logs"
>>"%DST%\Logs\copykit.log" echo [%DATE% %TIME%] Copying DayZero from %SRC% to %DST%

robocopy "%SRC%" "%DST%" /E /R:2 /W:2 /NP /NDL /XD Logs /XF "build-*.marker" /LOG+:"%DST%\Logs\copykit.log"
if errorlevel 8 (
    >>"%DST%\Logs\copykit.log" echo [%DATE% %TIME%] robocopy failed with exit code %ERRORLEVEL%
    exit /b 1
)

copy /y "%SRC%\build-%BUILD%.marker" "%DST%\" >nul
>>"%DST%\Logs\copykit.log" echo [%DATE% %TIME%] Copy finished.
exit /b 0
