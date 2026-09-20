@echo off
title The Pool
cd /d "%~dp0web"
where node >/dev/null 2>&1
if errorlevel 1 (
  echo Node.js is not installed. Install the LTS version from https://nodejs.org and run this again.
  pause
  exit /b 1
)
if not exist node_modules (
  echo Installing dependencies - one-time, about a minute...
  call npm install
)
start "" http://localhost:5173
echo.
echo The Pool is running at http://localhost:5173 - keep this window open. Close it to stop.
call npm run dev
pause
