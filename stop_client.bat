@echo off
setlocal
cd /d "%~dp0"
echo Stopping Flutter Web client on port 8911...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$owners=Get-NetTCPConnection -LocalPort 8911 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique; if(-not $owners){Write-Output 'No process is listening on port 8911.'; exit 0}; foreach($id in $owners){$proc=Get-CimInstance Win32_Process -Filter ('ProcessId = '+$id) -ErrorAction SilentlyContinue; $cmd=[string]$proc.CommandLine; if($proc -and $proc.Name -in @('dart.exe','dartvm.exe') -and $cmd -match '(?i)flutter_tools\.snapshot.*\brun\b.*web-server.*--web-hostname\s+0\.0\.0\.0.*--web-port\s+8911'){Stop-Process -Id $id -Force -ErrorAction SilentlyContinue; Write-Output ('Stopped RemoteAISync Web client (PID '+$id+').')}else{Write-Output ('Left PID '+$id+' untouched because it does not match the RemoteAISync Flutter Web client.')}}"
pause
