@echo off
rem DayZero - runs your own scripts in C:\DayZero\Scripts again (asks for admin rights).
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0RunScripts.ps1\"'"
