@echo off
title Push freeb variables to fork
rem Double-click launcher for push-github-variables.ps1 (same folder).
rem Reads repo\.env.local and creates/updates the 11 NEXT_PUBLIC_*
rem Actions variables on your fork. Auth via stored git credential.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0push-github-variables.ps1"
if errorlevel 1 (
  echo.
  echo FAILED - see the error above.
) else (
  echo.
  echo DONE - variables are in place.
)
echo.
pause
