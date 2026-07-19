# Shared environment setup for the SwiftPDAL Windows build scripts.
# Dot-source this: `. "$PSScriptRoot\_env.ps1"` then call Import-SwiftPDALEnv.
#
# Establishes:
#   - the MSVC x64 toolchain env (INCLUDE/LIB/PATH via vcvars64.bat),
#   - swift/cmake/ninja on PATH (machine + user, i.e. winget installs),
#   - the vcpkg + copc prefixes as SWIFTPDAL_VCPKG_PREFIX / SWIFTPDAL_COPC_PREFIX
#     (these are what Package.swift reads on Windows),
#   - the vcpkg bin dir on PATH so pdalcpp.dll & friends resolve at run time.
#
# Override any path with the matching environment variable before invoking.

function Get-SwiftPDALPaths {
    # Namespaced var, NOT the ambient VCPKG_ROOT: Visual Studio 2022 sets
    # VCPKG_ROOT to its own bundled vcpkg (...\VC\vcpkg), which does not have our
    # ports installed. Override with SWIFTPDAL_VCPKG_ROOT to use a different tree.
    $vcpkgRoot   = if ($env:SWIFTPDAL_VCPKG_ROOT) { $env:SWIFTPDAL_VCPKG_ROOT } else { "C:\src\vcpkg" }
    $vcpkgPrefix = if ($env:SWIFTPDAL_VCPKG_PREFIX) { $env:SWIFTPDAL_VCPKG_PREFIX } else { "$vcpkgRoot\installed\x64-windows" }
    $copcPrefix  = if ($env:SWIFTPDAL_COPC_PREFIX)  { $env:SWIFTPDAL_COPC_PREFIX }  else { "C:\src\copc-install" }
    [pscustomobject]@{
        VcpkgRoot   = $vcpkgRoot
        VcpkgPrefix = $vcpkgPrefix
        CopcPrefix  = $copcPrefix
    }
}

function Import-SwiftPDALEnv {
    $ErrorActionPreference = "Stop"

    # 1. winget-installed tools (swift, cmake, ninja) from machine + user PATH.
    $machine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $user    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"

    # 2. MSVC env via vcvars64.bat (located with vswhere).
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw "vswhere not found - install Visual Studio 2022 with the C++ workload." }
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsPath) { throw "No Visual Studio install with the VC x64 tools found." }
    $vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found at $vcvars" }
    $tmp = [System.IO.Path]::GetTempFileName()
    cmd /c "`"$vcvars`" >nul 2>&1 && set" | Out-File -FilePath $tmp -Encoding ascii
    Get-Content $tmp | ForEach-Object {
        if ($_ -match "^([^=]+)=(.*)$") { Set-Item -Path "Env:$($matches[1])" -Value $matches[2] }
    }
    Remove-Item $tmp -ErrorAction SilentlyContinue
    $env:Path = "$machine;$user;$env:Path"

    # 3. Prefixes for Package.swift + runtime DLL resolution.
    $p = Get-SwiftPDALPaths
    $env:SWIFTPDAL_VCPKG_PREFIX = ($p.VcpkgPrefix -replace '\\', '/')
    $env:SWIFTPDAL_COPC_PREFIX  = ($p.CopcPrefix  -replace '\\', '/')
    $env:Path = "$($p.VcpkgPrefix)\bin;$env:Path"
}
