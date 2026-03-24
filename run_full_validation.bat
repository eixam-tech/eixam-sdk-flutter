@echo off
title EIXAM SDK Full Validation

echo ==========================================
echo EIXAM SDK - Full Validation
echo ==========================================
echo.

cd /d "%~dp0"

echo [1/4] Checking formatting...
call dart format --set-exit-if-changed .
if errorlevel 1 (
    echo.
    echo ERROR: format check failed.
    pause
    exit /b 1
)

echo.
echo [2/4] Running flutter analyze...
call flutter analyze
if errorlevel 1 (
    echo.
    echo ERROR: flutter analyze failed.
    pause
    exit /b 1
)

echo.
echo [3/4] Running flutter test...
call flutter test
if errorlevel 1 (
    echo.
    echo ERROR: flutter test failed.
    pause
    exit /b 1
)

echo.
echo [4/4] Running demo app...
cd /d "%~dp0\apps\eixam_control_app"

call flutter pub get
if errorlevel 1 (
    echo.
    echo ERROR: flutter pub get failed.
    pause
    exit /b 1
)

call flutter run -t lib/main.dart
if errorlevel 1 (
    echo.
    echo ERROR: flutter run failed.
    pause
    exit /b 1
)

pause