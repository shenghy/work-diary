@echo off
setlocal
title Work Diary - Local Launcher

echo ========================================
echo   Work Diary - Local Launch (App + API)
echo ========================================
echo.

set "SERVER_DIR=E:\Code\WorkDiary\work_diary_server"
set "APP_DIR=E:\Code\WorkDiary\work_diary_app\build\windows\x64\runner\Debug"
set "APP_EXE=%APP_DIR%\work_diary_app.exe"
set "API_URL=http://127.0.0.1:8010"
set "PORT=8010"
set "HEALTH_FILE=%TEMP%\wd_health.txt"

REM ---------- 0. Already running? ----------
powershell -NoProfile -ExecutionPolicy Bypass -Command "try{(Invoke-WebRequest -Uri 'http://127.0.0.1:%PORT%/api/health' -UseBasicParsing -TimeoutSec 2).StatusCode}catch{0}" > "%HEALTH_FILE%" 2>nul
set "health=0"
for /f "usebackq delims=" %%i in ("%HEALTH_FILE%") do set "health=%%i"
if "%health%"=="200" (
    echo [1/4] API service already running at %API_URL%
    goto skip_service
)

REM ---------- 1. Python env ----------
if not exist "%SERVER_DIR%\.venv\Scripts\python.exe" (
    echo [1/4] First run: creating Python venv and installing deps ^(about 1 min^)...
    py -3 -m venv "%SERVER_DIR%\.venv"
    "%SERVER_DIR%\.venv\Scripts\python.exe" -m pip install -r "%SERVER_DIR%\requirements.txt"
) else (
    echo [1/4] Python env ready
)

REM ---------- 2. Start API service in its own window ----------
echo [2/4] Starting API service at %API_URL% ...
start "Work Diary API Service" cmd /k "cd /d %SERVER_DIR% && .venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port %PORT%"

REM ---------- 3. Wait for service ready ----------
echo [3/4] Waiting for API service ^(first start connects to cloud DB, ~10s^)...
set "tries=0"
:waitloop
powershell -NoProfile -ExecutionPolicy Bypass -Command "try{(Invoke-WebRequest -Uri 'http://127.0.0.1:%PORT%/api/health' -UseBasicParsing -TimeoutSec 2).StatusCode}catch{0}" > "%HEALTH_FILE%" 2>nul
set "health=0"
for /f "usebackq delims=" %%i in ("%HEALTH_FILE%") do set "health=%%i"
if "%health%"=="200" goto ready
set /a tries+=1
if %tries% geq 40 (
    echo.
    echo [ERROR] API service start timeout ^(40s^). Check the "Work Diary API Service" window.
    echo   Common causes: port %PORT% occupied, or cloud DB unreachable.
    pause
    exit /b 1
)
timeout /t 1 /nobreak >nul
goto waitloop

:ready
echo        API service ready

:skip_service
REM ---------- 4. Write API url file and launch app ----------
echo [4/4] Writing API url and launching app...
echo %API_URL%>"%APP_DIR%\api_url.txt"
if not exist "%APP_EXE%" (
    echo [ERROR] App not found. Build it first:
    echo   cd /d E:\Code\WorkDiary\work_diary_app ^&^& flutter build windows --debug
    pause
    exit /b 1
)
start "" "%APP_EXE%"

echo.
echo ========================================
echo   Done! The app window is open.
echo.
echo   API service : %API_URL%  ^(window: Work Diary API Service^)
echo.
echo   To stop the service: close the "Work Diary API Service" window.
echo   This window can be closed anytime.
echo ========================================
timeout /t 6 /nobreak >nul
endlocal
