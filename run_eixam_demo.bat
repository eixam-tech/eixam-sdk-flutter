@echo off
title EIXAM Flutter Demo Runner

echo ==========================================
echo EIXAM SDK - Flutter Demo Runner
echo ==========================================
echo.

cd /d C:\Users\roger\flutterdev\eixam_connect_sdk\apps\eixam_control_app

echo Current directory:
cd
echo.

echo [1/3] Running flutter clean...
call flutter clean
if errorlevel 1 (
    echo.
    echo ERROR: flutter clean failed.
    pause
    exit /b 1
)

echo.
echo [2/3] Running flutter pub get...
call flutter pub get
if errorlevel 1 (
    echo.
    echo ERROR: flutter pub get failed.
    pause
    exit /b 1
)

echo.
echo [3/3] Running flutter app...
call flutter run -t lib/main.dart
if errorlevel 1 (
    echo.
    echo ERROR: flutter run failed.
    pause
    exit /b 1
)

pause