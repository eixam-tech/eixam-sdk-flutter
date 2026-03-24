@echo off
title EIXAM Control App Demo

echo ==========================================
echo EIXAM Control App - Demo Run
echo ==========================================
echo.

cd /d "%~dp0\apps\eixam_control_app"

echo [1/2] Fetching dependencies...
call flutter pub get
if errorlevel 1 (
    echo.
    echo ERROR: flutter pub get failed.
    pause
    exit /b 1
)

echo.
echo [2/2] Running demo app...
call flutter run -t lib/main.dart
if errorlevel 1 (
    echo.
    echo ERROR: flutter run failed.
    pause
    exit /b 1
)

pause