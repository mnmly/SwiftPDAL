# SwiftPDAL on Windows

SwiftPDAL builds and runs natively on Windows (`x86_64-unknown-windows-msvc`).
The **convert path** — the `PDAL2COPC` CLI and the `SwiftPDAL` library's
`PDALConvert` API — is fully supported: any PDAL-readable input (LAS/LAZ, PLY,
PCD, BPF, XYZ/TXT, …) → Cloud-Optimized Point Cloud (`*.copc.laz`) plus a STAC
sidecar.

Verified on `x86_64-unknown-windows-msvc` (Swift 6.3.3): `test.laz`
(2,108,473 points) → a valid 12 MB `*.copc.laz` + sidecar, exit 0.

## What is and isn't ported

| Feature | Windows |
|---|---|
| `PDAL2COPC` (convert to COPC + sidecar) | ✅ |
| `SwiftPDAL` convert API + per-dim statistics | ✅ |
| Core readers/writers (LAS/LAZ/COPC/PLY/text/…) | ✅ |
| Metal buffer export (`PointCloud`, `makeBuffer`) | ❌ Apple-only |
| COPC out-of-core streaming (`StreamingPointCloudSource`) | ❌ compiled out |
| SoA de-interleave (`DeinterleavedGeometry`) | ❌ compiled out |
| COPC-over-HTTP streaming (`http_stream`) | ❌ stubbed (returns nullptr) |
| E57 reader | ⚠️ needs the plugin DLL on `PDAL_DRIVER_PATH` (see below) |

The excluded pieces are Metal-backed and/or push heavy C++ types across the
Swift↔C++ module boundary, which the Windows toolchain can't currently do — see
[Why the interface is thin on Windows](#why-the-interface-is-thin-on-windows).

## Prerequisites

Install once (PowerShell, as the build user):

```powershell
# Visual Studio 2022 with the C++ workload (MSVC + Windows SDK).
winget install Microsoft.VisualStudio.2022.Community `
  --override "--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"

# Toolchain (Git is usually already present).
winget install Git.Git Swift.Toolchain Kitware.CMake Ninja-build.Ninja
```

## Build the dependencies

PDAL/GDAL/libE57Format come from vcpkg at the exact pinned versions
(2.10.1 / 3.12.4 / 3.3.0); copc-lib is built from source. One command does both:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\setup-deps.ps1
```

This bootstraps vcpkg at `%VCPKG_ROOT%` (default `C:\src\vcpkg`), runs
`vcpkg install pdal` with the bundled **libaec overlay**
(`scripts\windows\vcpkg-overlays\libaec` — fetches libaec from its GitHub mirror
because `gitlab.dkrz.de` frequently returns HTTP 429), then builds copc-lib via
`scripts\windows\build-copc.ps1` into `%SWIFTPDAL_COPC_PREFIX%`
(default `C:\src\copc-install`). Budget 45–90 min for the vcpkg from-source
build the first time; it is cached afterward.

## Build SwiftPDAL

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\build.ps1
# -> .build\release\PDAL2COPC.exe
```

`build.ps1` imports the MSVC env, sets `SWIFTPDAL_VCPKG_PREFIX` /
`SWIFTPDAL_COPC_PREFIX` (which `Package.swift` reads), and runs
`swift build --product PDAL2COPC -c release`. Pass `-Product` / `-Config` to
change the target. Do **not** run a bare `swift build` — it would try to build
the Metal/streaming targets and the XCTest bundle, which are Windows-excluded.

## Run

The built exe needs the vcpkg `bin` directory (pdalcpp.dll + ~64 deps) on
`PATH`. `dev.ps1` sets that up:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\dev.ps1 `
  .\.build\release\PDAL2COPC.exe input.laz output.copc.laz
```

E57 input additionally needs PDAL's E57 plugin discoverable: set
`SWIFTPDAL_PDAL_DRIVER_PATH` to the vcpkg `bin` dir (which holds
`libpdal_plugin_reader_e57.dll`) before running.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `SWIFTPDAL_VCPKG_ROOT` | `C:\src\vcpkg` | vcpkg checkout location (namespaced so VS 2022's ambient `VCPKG_ROOT` can't hijack it) |
| `SWIFTPDAL_VCPKG_PREFIX` | `<SWIFTPDAL_VCPKG_ROOT>\installed\x64-windows` | PDAL/GDAL/E57 headers + import libs + DLLs; read by `Package.swift` |
| `SWIFTPDAL_COPC_PREFIX` | `C:\src\copc-install` | copc-lib + lazperf static libs + headers; read by `Package.swift` |
| `SWIFTPDAL_PDAL_DRIVER_PATH` | *(empty)* | `PDAL_DRIVER_PATH` for optional plugins (e.g. E57) |

## Why the interface is thin on Windows

The Swift compiler's clang importer builds the `CxxPDAL` module against the
**modularized MSVC STL**. As soon as a heavy STL header (`<regex>`, `<deque>`,
…) enters the module's *public* header surface, clang hits an unresolvable
cross-submodule specialization error:

```
error: explicit specialization of 'coroutine_handle<>' must be imported from
module 'std.coroutine' before it is required
```

No clang-module flag fixes this (`-std=c++20`,
`-fmodules-local-submodule-visibility`, force-including `<coroutine>`, on either
the importing target or the module target — all tried). The only reliable fix is
to keep heavy C++ headers **out of the Swift-imported module surface**. So on
Windows:

- `pdal_wrapper.h`'s binary-read / streaming / SoA API (which exposes
  `pdal::PointView`, `std::map`, … and is Metal-backed on the Swift side) is
  gated out with `#if !defined(_WIN32)`;
- `pdal_wrapper.cpp` and the four Metal/heavy Swift files (`SwiftPDAL.swift`,
  `Deinterleave/DeinterleavedGeometry.swift`, `Streaming/ChunkPacking.swift`,
  `Streaming/StreamingPointCloudSource.swift`) are excluded from the Windows
  build in `Package.swift`;
- the convert path (`Convert.swift`, `PDALRuntime.swift`,
  `Statistics/PointCloudStatistics.swift`, `Streaming/DecodeGate.swift`) — whose
  module headers (`pdal_convert.h`, …) expose only C/POD types — stays.

**Rule of thumb:** any C++ header a Swift target imports on Windows must expose
only C/POD/opaque types, never heavy C++ STL or library headers.

## Layout

```
scripts/windows/
  _env.ps1                    # shared: MSVC env + tool PATH + prefixes
  setup-deps.ps1              # vcpkg bootstrap + install pdal + build copc-lib
  build-copc.ps1              # copc-lib + laz-perf -> static MSVC libs
  build.ps1                   # swift build --product PDAL2COPC
  dev.ps1                     # run a command in the configured env
  vcpkg-overlays/libaec/      # GitHub-mirror overlay port (gitlab 429 workaround)
docs/windows.md               # this file
```

## Known limitations / future work

- COPC-over-HTTP streaming: `http_stream_win.cpp` is a stub. A WinHTTP or
  libcurl-backed `std::streambuf` would restore remote streaming.
- The XCTest suite exercises the excluded Metal/streaming/SoA features, so
  `swift test` does not build as-is; a Windows-scoped convert-only test subset
  would give CI coverage.
- The heavy read/SoA API could be offered on Windows via a thin C/opaque-handle
  interface (the same technique that keeps the convert path importable).
