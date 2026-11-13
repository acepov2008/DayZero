@echo off
setlocal EnableExtensions EnableDelayedExpansion
powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '%~dp0'" 2>nul
title Activate Windows + Office

rem ============================================================
rem  DayZero script: activates Windows 10/11 and Microsoft Office
rem  Runs unattended. Safe to run repeatedly.
rem  Exit: 0 ok | 10 Windows failed | 20 Office failed | 30 both | 99 engine missing
rem  Optional arg: --offline  (forces offline-safe methods)
rem ============================================================

set "BASE=%~dp0"
set "MAS=%BASE%MAS_AIO.cmd"
set "MASALT=%BASE%bin\MAS_AIO.cmd"
set "LOG=%BASE%activation-log.txt"
set "FORCEOFF=0"
if /i "%~1"=="--offline" set "FORCEOFF=1"

cd /d "%BASE%"
echo ============================================================
echo  Activating Windows and Microsoft Office
echo ============================================================
echo.

rem ---------- safety: elevate if DayZero ever runs this unelevated ----------
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Not elevated - relaunching as administrator...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs"
    exit /b 0
)

call :log "=== Activation started ==="
call :log "Host: %COMPUTERNAME% / User: %USERNAME%"

rem ---------- locate engine ----------
if not exist "%MAS%" if exist "%MASALT%" set "MAS=%MASALT%"
if not exist "%MAS%" (
    call :log "ERROR: MAS_AIO.cmd not found next to this script."
    set "RC=99"
    goto :finish
)
for %%A in ("%MAS%") do (
    if %%~zA LSS 100000 (
        call :log "ERROR: MAS_AIO.cmd looks truncated (%%~zA bytes)."
        set "RC=99"
        goto :finish
    )
)
call :log "Engine: %MAS%"

rem ---------- environment ----------
for /f "usebackq delims=" %%a in (`powershell -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).BuildNumber"`) do set "BUILD=%%a"
for /f "usebackq delims=" %%a in (`powershell -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).ProductType"`) do set "PTYPE=%%a"
for /f "usebackq delims=" %%a in (`powershell -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).Caption"`) do set "CAPTION=%%a"
if not defined BUILD set "BUILD=0"
if not defined PTYPE set "PTYPE=1"
call :log "OS: %CAPTION% (build %BUILD%, type %PTYPE%)"

set "ONLINE=0"
if "%FORCEOFF%"=="0" (
    call :checknet
    if "%errorlevel%"=="0" set "ONLINE=1"
)
if "%ONLINE%"=="1" (call :log "Network: online") else (call :log "Network: offline - offline methods only")

set "WINFAIL=0"
set "OFFFAIL=0"

rem ============================================================
rem  WINDOWS
rem ============================================================
call :winLicensed
if "%errorlevel%"=="0" (
    call :log "Windows already activated, skipping."
    goto :office
)

if not "%PTYPE%"=="1" (
    call :log "Server SKU - HWID not applicable, using TSforge."
    call "%MAS%" /Z-Windows /S
) else if "%ONLINE%"=="0" (
    call :log "Offline - using TSforge ZeroCID for Windows..."
    call "%MAS%" /Z-Windows /S
) else if %BUILD% GEQ 10240 (
    call :log "Windows 10/11 online - running HWID..."
    call "%MAS%" /HWID /S
    call :winLicensed
    if not "%errorlevel%"=="0" (
        call :log "HWID did not license Windows, falling back to TSforge..."
        call "%MAS%" /Z-Windows /S
    )
) else (
    call :log "Pre-Windows 10 build - using TSforge..."
    call "%MAS%" /Z-Windows /S
)

call :winLicensed
if "%errorlevel%"=="0" (
    call :log "RESULT: Windows ACTIVATED."
) else (
    call :log "RESULT: Windows activation FAILED."
    set "WINFAIL=1"
)

:office
rem ============================================================
rem  OFFICE
rem ============================================================
call :officePresent
if not "%errorlevel%"=="0" (
    call :log "No Office installation detected, skipping Office."
    goto :verify
)
call :officeLicensed
if "%errorlevel%"=="0" (
    call :log "Office already activated, skipping."
    goto :verify
)

call :log "Office found - installing Ohook (offline, permanent)..."
call "%MAS%" /Ohook /S

call :officeLicensed
if "%errorlevel%"=="0" (
    call :log "RESULT: Office ACTIVATED."
) else (
    call :log "Ohook did not license Office, falling back to TSforge..."
    call "%MAS%" /Z-Office /S
    call :officeLicensed
    if "%errorlevel%"=="0" (
        call :log "RESULT: Office ACTIVATED (TSforge)."
    ) else (
        call :log "RESULT: Office activation FAILED."
        set "OFFFAIL=1"
    )
)

:verify
call :log "--- Final state ---"
call :winLicensed
if "%errorlevel%"=="0" (call :log "Windows: licensed") else (call :log "Windows: NOT licensed")
call :officeLicensed
if "%errorlevel%"=="0" (call :log "Office: licensed") else (call :log "Office: NOT licensed")

set "RC=0"
if "%WINFAIL%%OFFFAIL%"=="10" set "RC=10"
if "%WINFAIL%%OFFFAIL%"=="01" set "RC=20"
if "%WINFAIL%%OFFFAIL%"=="11" set "RC=30"

:finish
call :log "=== Finished, exit code %RC% ==="
echo.
if "%RC%"=="0" (echo Activation complete.) else (echo Activation finished with errors - see activation-log.txt)
endlocal & exit /b %RC%

rem ============================================================
rem  HELPERS (errorlevel 0 = true)
rem ============================================================
:checknet
where curl.exe >nul 2>&1
if not "%errorlevel%"=="0" goto :netping
curl.exe -s -m 5 -o nul https://massgrave.dev
if "%errorlevel%"=="0" exit /b 0
:netping
ping -n 1 -w 1500 1.1.1.1 >nul 2>&1
if "%errorlevel%"=="0" exit /b 0
exit /b 1

:winLicensed
powershell -NoProfile -Command "$p=Get-CimInstance SoftwareLicensingProduct -Filter 'ApplicationId=''55c92734-d682-4d71-983e-d6ec3f16059f'' AND LicenseStatus=1 AND PartialProductKey IS NOT NULL'; if($p){exit 0}else{exit 1}"
exit /b %errorlevel%

:officeLicensed
powershell -NoProfile -Command "$p=Get-CimInstance SoftwareLicensingProduct -Filter 'PartialProductKey IS NOT NULL AND LicenseStatus=1'; if($p -match 'Office'){exit 0}else{exit 1}"
exit /b %errorlevel%

:officePresent
if exist "%ProgramFiles%\Microsoft Office\root\Office16\ospp.vbs" exit /b 0
if exist "%ProgramFiles(x86)%\Microsoft Office\root\Office16\ospp.vbs" exit /b 0
if exist "%ProgramFiles%\Microsoft Office\Office16\ospp.vbs" exit /b 0
if exist "%ProgramFiles(x86)%\Microsoft Office\Office16\ospp.vbs" exit /b 0
reg query "HKLM\SOFTWARE\Microsoft\Office\ClickToRun" >nul 2>&1 && exit /b 0
reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun" >nul 2>&1 && exit /b 0
exit /b 1

:log
echo [%date% %time%] %~1
>>"%LOG%" echo [%date% %time%] %~1
exit /b 0