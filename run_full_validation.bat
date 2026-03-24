@echo off
title EIXAM SDK Full Validation

echo ==========================================
echo EIXAM SDK - Full Validation
echo ==========================================
echo.

cd /d "%~dp0"

echo [0/6] Cleaning generated build folders...
if exist "apps\eixam_control_app\build" rmdir /s /q "apps\eixam_control_app\build"

echo.
echo [1/6] Checking formatting (tracked source folders only)...
call dart format --set-exit-if-changed apps packages docs
if errorlevel 1 (
    echo.
    echo ERROR: format check failed.
    pause
    exit /b 1
)

echo.
echo [2/6] Running flutter analyze (warnings/errors only)...
call flutter analyze --no-fatal-infos
if errorlevel 1 (
    echo.
    echo ERROR: flutter analyze failed.
    pause
    exit /b 1
)

echo.
echo [3/6] Running tests for eixam_connect_core...
cd /d "%~dp0\packages\eixam_connect_core"
call flutter test
if errorlevel 1 (
    echo.
    echo ERROR: eixam_connect_core tests failed.
    pause
    exit /b 1
)

echo.
echo [4/6] Running tests for eixam_connect_flutter...
cd /d "%~dp0\packages\eixam_connect_flutter"
call flutter test
if errorlevel 1 (
    echo.
    echo ERROR: eixam_connect_flutter tests failed.
    pause
    exit /b 1
)

echo.
echo [5/6] Running tests for eixam_control_app...
cd /d "%~dp0\apps\eixam_control_app"
call flutter test
if errorlevel 1 (
    echo.
    echo ERROR: eixam_control_app tests failed.
    pause
    exit /b 1
)

echo.
echo [6/6] Running demo app...
call flutter pub get
if errorlevel 1 (
    echo.
    echo ERROR: flutter pub get failed for eixam_control_app.
    pause
    exit /b 1
)

call flutter run -t lib/main.dart
if errorlevel 1 (
    echo.
    echo ERROR: flutter run failed for eixam_control_app.
    pause
    exit /b 1
)

cd /d "%~dp0"

echo.
echo Full validation completed successfully.
pause