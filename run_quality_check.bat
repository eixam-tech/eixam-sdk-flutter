@echo off
title EIXAM SDK Quality Checks

echo ==========================================
echo EIXAM SDK - Quality Checks
echo ==========================================
echo.

cd /d "%~dp0"

echo [1/3] Checking formatting...
call dart format --set-exit-if-changed .
if errorlevel 1 (
    echo.
    echo ERROR: format check failed.
    pause
    exit /b 1
)

echo.
echo [2/3] Running flutter analyze...
call flutter analyze
if errorlevel 1 (
    echo.
    echo ERROR: flutter analyze failed.
    pause
    exit /b 1
)

echo.
echo [3/3] Running flutter test...
call flutter test
if errorlevel 1 (
    echo.
    echo ERROR: flutter test failed.
    pause
    exit /b 1
)

echo.
echo All quality checks passed.
pause