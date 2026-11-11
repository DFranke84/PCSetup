@echo off
rem Starts PCSetup as administrator. Script policy is bypassed for this run only.
rem /resume is used by Windows to continue a run after a restart.
set "RESUME="
if /i "%~1"=="/resume" set "RESUME=-Resume"
net session >nul 2>&1
if %errorlevel% neq 0 (
  if defined RESUME (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '/resume' -Verb RunAs"
  ) else (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  )
  exit /b
)
start "" powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PCSetup.ps1" %RESUME%
