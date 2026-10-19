@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\configurar.ps1" %*
