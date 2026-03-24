@echo off
title EIXAM SDK Quality Checks

echo ==========================================
echo EIXAM SDK - Quality Checks
echo ==========================================
echo.

cd /d "%~dp0"

echo [0/3] Cleaning generated build folders...
if exist "apps\eixam_control_app\build" rmdir /s /q "apps\eixam_control_app\build"

echo.
echo [1/3] Checking formatting (tracked source folders only)...
call dart format --set-exit-if-changed apps packages docs
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