@echo off
setlocal
cd /d "%~dp0"
echo Stopping RemoteAISync relay on port 8920...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$owners=Get-NetTCPConnection -LocalPort 8920 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique; if(-not $owners){Write-Output 'No process is listening on port 8920.'; exit 0}; foreach($id in $owners){$proc=Get-CimInstance Win32_Process -Filter ('ProcessId = '+$id) -ErrorAction SilentlyContinue; $cmd=[string]$proc.CommandLine; if($proc -and $cmd -like '*remotaisync_host.dart*' -and $cmd -match '(?i)--mode\s+relay' -and $cmd -match '(?i)--port\s+8920'){Stop-Process -Id $id -Force -ErrorAction SilentlyContinue; Write-Output ('Stopped RemoteAISync relay (PID '+$id+').')}else{Write-Output ('Left PID '+$id+' untouched because it is not RemoteAISync relay on port 8920.')}}"
pause
