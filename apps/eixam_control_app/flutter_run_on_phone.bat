@echo off
setlocal enabledelayedexpansion

echo Checking connected Android devices...
adb devices
echo.

set DEVICE_ID=
for /f "skip=1 tokens=1,2" %%A in ('adb devices') do (
  if "%%B"=="device" (
    echo Found device: %%A
    set DEVICE_ID=%%A
    goto :device_found
  )
)

echo Error: No authorized Android device found.
pause
exit /b 1

:device_found
echo.
echo Clearing previous logs on device: %DEVICE_ID%
adb -s %DEVICE_ID% logcat -c

echo.
echo Building and launching app with Flutter on device...
echo This is the best option if you want Flutter + Android logs together.
echo Press Ctrl+C to stop.
echo.

flutter run -d %DEVICE_ID%
