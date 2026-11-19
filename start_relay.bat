@echo off
setlocal
cd /d "%~dp0"
set "REMOTEAI_ROOT=%CD%"

where dart >nul 2>nul
if errorlevel 1 (
  echo Dart was not found on PATH. Install Flutter/Dart or add Dart's bin folder to PATH.
  pause
  exit /b 1
)

for /f "usebackq tokens=1,* delims==" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $dir=Join-Path $env:REMOTEAI_ROOT '.remoteaisync'; $path=Join-Path $dir 'relay-dev-config.json'; if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null; function New-Token([int]$size) { $bytes=New-Object byte[] $size; $rng=[System.Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($bytes); $rng.Dispose(); [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_') }; $config=[ordered]@{ room=(New-Token 18); clientToken=(New-Token 32); hostToken=(New-Token 32) }; $config | ConvertTo-Json | Set-Content -Path $path -Encoding ASCII }; $config=Get-Content -Raw -Path $path | ConvertFrom-Json; Write-Output ('ROOM='+$config.room); Write-Output ('CLIENT='+$config.clientToken); Write-Output ('HOST='+$config.hostToken)"`) do set "%%A=%%B"

if not defined ROOM (
  echo Failed to load or create .remoteaisync\relay-dev-config.json.
  pause
  exit /b 1
)

echo Starting RemoteAISync local relay on port 8920...
echo Health check: http://127.0.0.1:8920/health
echo.
echo Relay GUI admin key (keep this on the relay machine): %CLIENT%
echo Enter this key only in the relay GUI settings. Do not share it with hosts or clients.
echo.
dart run "%CD%\host\bin\remotaisync_host.dart" --mode relay --bind-address 0.0.0.0 --port 8920 --relay-token "%CLIENT%" --relay-host-token "%HOST%"
pause
