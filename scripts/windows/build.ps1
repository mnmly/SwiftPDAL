# Build a SwiftPDAL product on Windows in a fully-configured MSVC + vcpkg env.
#
#   powershell -ExecutionPolicy Bypass -File scripts\windows\build.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\windows\build.ps1 -Product PDAL2COPC -Config release
#
# Only the Windows-portable products build (see scripts/windows/README.md): PDAL2COPC and
# the SwiftPDAL library convert path. The Metal/streaming/SoA targets and the
# XCTest bundle are compiled out on Windows.
param(
    [string]$Product = "PDAL2COPC",
    [ValidateSet("debug", "release")]
    [string]$Config = "release"
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_env.ps1"
Import-SwiftPDALEnv

$repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
Set-Location $repoRoot
Write-Host "Building product '$Product' ($Config) with"
Write-Host "  SWIFTPDAL_VCPKG_PREFIX=$env:SWIFTPDAL_VCPKG_PREFIX"
Write-Host "  SWIFTPDAL_COPC_PREFIX=$env:SWIFTPDAL_COPC_PREFIX"
& swift build --product $Product -c $Config
exit $LASTEXITCODE
