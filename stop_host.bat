@echo off
setlocal
cd /d "%~dp0"
echo Stopping RemoteAISync host on port 8910...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$root = (Get-Location).Path; $tokenFile = Join-Path $root '.remoteaisync\dev-pairing-token'; if (Test-Path $tokenFile) { $token = (Get-Content $tokenFile -Raw).Trim(); try { Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8910/dev-shutdown' -Headers @{ 'x-remoteaisync-token' = $token } -ErrorAction Stop | Out-Null } catch { } }; Get-NetTCPConnection -LocalPort 8910 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { $proc = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $_); if ($proc.CommandLine -like '*remotaisync_host.dart*' -and $proc.CommandLine.Contains($root)) { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }"
pause
