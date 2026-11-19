$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$releaseDirectory = Join-Path $repoRoot 'build\windows\x64\runner\Release'
$runtimeDirectory = Join-Path $releaseDirectory 'runtime'
$runtimePath = Join-Path $runtimeDirectory 'remotaisync_host.exe'
$guiPath = Join-Path $releaseDirectory 'remote_ai_sync.exe'

Push-Location $repoRoot
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) {
        throw 'flutter pub get failed.'
    }

    flutter build windows --release -t lib/main_desktop.dart
    if ($LASTEXITCODE -ne 0) {
        throw 'Flutter Windows Release build failed.'
    }
    if (-not (Test-Path -LiteralPath $guiPath -PathType Leaf)) {
        throw "Flutter did not produce the expected GUI executable: $guiPath"
    }

    New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
    dart compile exe host/bin/remotaisync_host.dart -o $runtimePath
    if ($LASTEXITCODE -ne 0) {
        throw 'Dart host and relay runtime build failed.'
    }
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
        throw "Dart did not produce the expected runtime executable: $runtimePath"
    }

    Write-Host ''
    Write-Host 'Windows portable build is ready:'
    Write-Host "  GUI:     $guiPath"
    Write-Host "  Runtime: $runtimePath"
    Write-Host 'Copy the complete Release directory to the target Windows computer.'
} finally {
    Pop-Location
}
