# Build copc-lib + laz-perf from source as static MSVC libs for the SwiftPDAL
# Windows build. This is the Windows counterpart of build-copc-xcframework.sh.
#
#   powershell -ExecutionPolicy Bypass -File scripts\windows\build-copc.ps1
#
# Output prefix: SWIFTPDAL_COPC_PREFIX (default C:\src\copc-install), containing
#   include\{copc-lib,lazperf}\...   lib\{copc-lib.lib,lazperf.lib}
#
# The lazperf reset() API patch (Frameworks/lazperf-patches/0001-add-reset-api.patch)
# is applied on top of upstream laz-perf, matching the xcframework build.
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_env.ps1"
Import-SwiftPDALEnv

$repoRoot    = (Resolve-Path "$PSScriptRoot\..\..").Path
$paths       = Get-SwiftPDALPaths
$COPC_TAG    = if ($env:COPC_TAG)    { $env:COPC_TAG }    else { "v2.6.3" }
$LAZPERF_TAG = if ($env:LAZPERF_TAG) { $env:LAZPERF_TAG } else { "master" }
$work        = if ($env:COPC_WORK_DIR) { $env:COPC_WORK_DIR } else { "C:\src\copc-build" }
$src         = "$work\copc-lib"
$build       = "$work\build"
$install     = $paths.CopcPrefix
$patch       = "$repoRoot\Frameworks\lazperf-patches\0001-add-reset-api.patch"

New-Item -ItemType Directory -Force -Path $work | Out-Null

# --- fetch sources ---
if (-not (Test-Path $src)) {
    git clone --depth 1 --branch $COPC_TAG https://github.com/RockRobotic/copc-lib.git $src
}
if (-not (Test-Path "$src\libs\laz-perf\.git")) {
    git clone --depth 1 --branch $LAZPERF_TAG https://github.com/hobuinc/laz-perf.git "$src\libs\laz-perf"
}

# --- apply the lazperf reset() patch (idempotent) ---
Push-Location "$src\libs\laz-perf"
git apply --reverse --check $patch 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "lazperf reset() patch already applied"
} else {
    git apply --check $patch 2>$null
    if ($LASTEXITCODE -eq 0) { git apply $patch; Write-Host "lazperf reset() patch applied" }
    else { Pop-Location; throw "lazperf patch does not apply cleanly: $patch" }
}
Pop-Location

# --- configure + build (Ninja + MSVC, static, dynamic CRT /MD) ---
# LAZPERF_VENDORED makes lazperf's LAZPERF_EXPORT macro empty: for a static
# build dllexport is wrong, and the patched reset() member would otherwise get
# dllexport-on-a-dllexport-class (a hard error under clang-cl).
if (Test-Path $build) { Remove-Item -Recurse -Force $build }
if (Test-Path $install) { Remove-Item -Recurse -Force $install }
$cmakeArgs = @(
    "-S", $src, "-B", $build, "-G", "Ninja",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DWITH_TESTS=OFF",
    "-DWITH_PYTHON=OFF",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL",
    "-DCMAKE_CXX_FLAGS=-DLAZPERF_VENDORED",
    "-DCMAKE_INSTALL_PREFIX=$install"
)
& cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
& cmake --build $build --target install
if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }

# --- patch the installed lazperf export header for static consumption ---
# laz-perf's install generates a consumer lazperf_base.hpp hardcoding
# LAZPERF_EXPORT = __declspec(dllimport) on Windows. When SwiftPDAL's CxxCOPC
# links these libs statically, dllimport is wrong and re-triggers the
# dllimport-on-a-dllimport-member error. Neutralize it.
$lazBase = "$install\include\lazperf\lazperf_base.hpp"
if (Test-Path $lazBase) {
    (Get-Content $lazBase -Raw) `
        -replace '#define LAZPERF_EXPORT __declspec\(dllimport\)', '#define LAZPERF_EXPORT /* static: no dllimport */' `
        | Set-Content -Path $lazBase -NoNewline
}

Write-Host ""
Write-Host "copc-lib installed to $install"
Get-ChildItem "$install\lib" -Filter *.lib | Select-Object Name, Length | Format-Table -AutoSize
