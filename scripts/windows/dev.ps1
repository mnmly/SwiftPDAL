# Run a command inside the SwiftPDAL Windows dev environment (MSVC toolchain,
# swift/cmake/ninja on PATH, vcpkg prefixes set, vcpkg bin on PATH for runtime
# DLL resolution). With no arguments, just reports that the env is ready - useful
# when dot-sourced to configure the current shell.
#
#   powershell -ExecutionPolicy Bypass -File scripts\windows\dev.ps1 swift --version
#   powershell -ExecutionPolicy Bypass -File scripts\windows\dev.ps1 .\.build\release\PDAL2COPC.exe in.laz out.copc.laz
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_env.ps1"
Import-SwiftPDALEnv

# Native tools write progress to stderr; don't let PowerShell treat that as a
# terminating error. Rely on the child's exit code.
$ErrorActionPreference = "Continue"
if ($args.Count -eq 0) {
    Write-Host "[dev.ps1] environment ready (MSVC + swift/cmake/ninja + vcpkg prefixes)."
    exit 0
}
$exe = $args[0]
$rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
& $exe @rest
exit $LASTEXITCODE
