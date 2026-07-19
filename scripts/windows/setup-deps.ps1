# One-shot dependency setup for the SwiftPDAL native-Windows build.
#
#   powershell -ExecutionPolicy Bypass -File scripts\windows\setup-deps.ps1
#
# Steps:
#   1. Bootstrap vcpkg (clone + build) at VCPKG_ROOT (default C:\src\vcpkg).
#   2. vcpkg install pdal (x64-windows) - pulls GDAL 3.12.4, PDAL 2.10.1,
#      libE57Format 3.3.0 and the full transitive tree, using the bundled
#      libaec overlay (GitHub mirror) to dodge gitlab.dkrz.de HTTP 429s.
#   3. Build copc-lib from source (scripts\windows\build-copc.ps1).
#
# Prerequisites (install first - see scripts/windows/README.md):
#   Visual Studio 2022 + "Desktop development with C++", Git, and the Swift
#   toolchain / CMake / Ninja (winget install Swift.Toolchain Kitware.CMake
#   Ninja-build.Ninja). This is a long run (vcpkg builds ~60 ports from source).
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_env.ps1"

$paths     = Get-SwiftPDALPaths
$vcpkgRoot = $paths.VcpkgRoot
$overlay   = (Resolve-Path "$PSScriptRoot\vcpkg-overlays").Path

# 1. bootstrap vcpkg
if (-not (Test-Path "$vcpkgRoot\.git")) {
    New-Item -ItemType Directory -Force -Path (Split-Path $vcpkgRoot) | Out-Null
    git clone https://github.com/microsoft/vcpkg.git $vcpkgRoot
}
if (-not (Test-Path "$vcpkgRoot\vcpkg.exe")) {
    & "$vcpkgRoot\bootstrap-vcpkg.bat" -disableMetrics
}
Write-Host "vcpkg: $(& "$vcpkgRoot\vcpkg.exe" version | Select-Object -First 1)"

# 2. install pdal (+ transitive GDAL/E57/proj/...) with the libaec overlay
Write-Host "Installing pdal (this builds ~60 ports from source; expect 45-90 min)..."
& "$vcpkgRoot\vcpkg.exe" install pdal --triplet x64-windows --overlay-ports=$overlay
if ($LASTEXITCODE -ne 0) { throw "vcpkg install pdal failed" }

# 3. build copc-lib from source
& "$PSScriptRoot\build-copc.ps1"
if ($LASTEXITCODE -ne 0) { throw "build-copc.ps1 failed" }

Write-Host ""
Write-Host "Dependencies ready:"
Write-Host "  vcpkg prefix: $($paths.VcpkgPrefix)"
Write-Host "  copc prefix:  $($paths.CopcPrefix)"
Write-Host "Next: scripts\windows\build.ps1"
