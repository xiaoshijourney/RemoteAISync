@echo off
setlocal
cd /d "%~dp0"

where flutter >nul 2>nul
if errorlevel 1 (
  echo Flutter was not found on PATH. Install Flutter or add its bin folder to PATH.
  pause
  exit /b 1
)

echo Starting RemoteAISync Web client on port 8911...
echo On this computer, open: http://localhost:8911
echo On a phone, use the computer's Wi-Fi IPv4 address followed by :8911.
echo Do not open http://0.0.0.0:8911; that address is for server listening only.
echo.
echo Detected private IPv4 addresses:
powershell -NoProfile -ExecutionPolicy Bypass -Command "$items=Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -notlike '127.*'} | Select-Object -ExpandProperty IPAddress; if($items){$items | ForEach-Object {Write-Output ('  http://'+$_+':8911')}}else{Write-Output '  No DHCP IPv4 address was detected. Check the active network adapter.'}"
echo.
echo Checking whether port 8911 is already in use...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$listener=Get-NetTCPConnection -LocalPort 8911 -State Listen -ErrorAction SilentlyContinue; if($listener){Write-Output ('Port 8911 is already in use by PID(s): '+(($listener.OwningProcess | Sort-Object -Unique) -join ', ')); exit 2}"
if errorlevel 2 (
  echo Stop the existing client with stop_client.bat, then run this file again.
  pause
  exit /b 2
)

echo.
echo If Windows Firewall asks for access, allow Dart/Flutter on Private networks.
echo If the phone still cannot connect, run this command once in an elevated terminal:
echo   netsh advfirewall firewall add rule name="RemoteAISync Web 8911" dir=in action=allow protocol=TCP localport=8911 profile=private
echo.
flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8911
pause
