@echo off
setlocal
cd /d "%~dp0"

where flutter >nul 2>nul
if errorlevel 1 (
  echo Flutter was not found on PATH. Install Flutter or add its bin folder to PATH.
  pause
  exit /b 1
)

echo Starting RemoteAISync host console...
echo Use the desktop console to start and manage the Dart host service.
flutter run -d windows -t lib/main_desktop.dart
pause
