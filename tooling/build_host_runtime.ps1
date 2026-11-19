$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$outputDirectory = Join-Path $repoRoot 'build\host-runtime'
$outputPath = Join-Path $outputDirectory 'remotaisync_host.exe'

Push-Location $repoRoot
try {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    dart pub get
    dart compile exe host/bin/remotaisync_host.dart -o $outputPath
    Write-Host "Built Windows host runtime: $outputPath"
    Write-Host 'For a release GUI bundle, place it at <app>\runtime\remotaisync_host.exe.'
} finally {
    Pop-Location
}
