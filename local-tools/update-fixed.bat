@echo off
title Update freeb (fixed freebuff)
rem One-click updater: rebases the fix, retests, rebuilds, reinstalls freeb, verifies.
rem Just double-click this file, wait for OK, then run:  freeb --cwd <project>
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-fixed.ps1"
if errorlevel 1 (
  echo.
  echo FAILED - see the error above. Fix it and double-click again.
) else (
  echo.
  echo DONE - freeb is ready. Example: freeb --cwd C:\path\to\project
)
echo.
pause
