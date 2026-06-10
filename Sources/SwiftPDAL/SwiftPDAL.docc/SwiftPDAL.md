# ``SwiftPDAL``

A Swift wrapper around PDAL for reading LAS/LAZ/COPC/E57 point clouds,
plus an out-of-core streaming source for large COPC files. Runs on
**macOS, iOS device, and iOS Simulator** — Apple Silicon.

## Overview

SwiftPDAL wraps the PDAL C++ library with two distinct codepaths:

- **Bulk read** — `PointCloud.read(from:)` reads a whole file into a
  C-allocated buffer (Metal-friendly via ``PointCloud/makeBuffer(device:options:)``).
  Best for small/medium clouds that fit in memory.
- **Streaming** — `StreamingPointCloud` yields chunks progressively over
  an `AsyncThrowingStream`. Best for incremental loading of large LAS/LAZ.
- **Out-of-core (COPC)** — ``CopcStreamingPointCloudSource`` pages
  octree nodes in and out of GPU residency under a byte budget.
  Designed for 100M+ point COPC files rendered by
  `Satin-ComputeRasteriser`.

The out-of-core path is the recent addition and the focus of this
documentation. For the design rationale and tradeoffs, see
`docs/streaming.md` in the repo root.

## Apple-platform support

SwiftPDAL ships binary xcframeworks for both macOS and iOS, sourced from
the sibling `pdal-xcframework-builder` and `gdal-xcframework-builder`
projects:

| Platform | Shape | Notes |
| --- | --- | --- |
| macOS arm64 | Dynamic `.framework` with bundled Homebrew dylibs | Drop-in `import SwiftPDAL`. |
| iOS arm64 device | Static library xcframework | Drop-in — no extra build settings. |
| iOS arm64 Simulator | Static library xcframework | Same as device. |

### iOS plugin registration

PDAL registers its readers/writers/filters via file-scope static
initializers (`static bool LasReader_b = registerPlugin(...)`). When
`pdalcpp` is linked statically (the iOS slices), `ld64` would normally
drop those `.o` files as unreferenced, and
`StageFactory::createStage("readers.las")` would return null at runtime.

SwiftPDAL handles this internally: `CxxPDAL/pdal_static_plugins.cpp`
anchors the stages it depends on so they survive dead-stripping. The
anchored set covers everything the Swift API invokes by name —
`readers.las`, `readers.ply`, `readers.text`, `readers.copc`,
`readers.e57`, the matching writers, and `filters.range / assign /
reprojection / transformation`.

If you run a custom PDAL JSON pipeline on iOS that references a stage
outside that set (e.g. `filters.crop`, `readers.ept`), the linker will
strip it and `StageFactory::createStage(...)` will return null. The
workaround is to anchor it yourself in your app target — instantiate
the type once in any TU your app reaches.

`Examples/PDALApp/PDALApp.xcodeproj` is a working iOS sample app:
bundled `.laz` and `.e57` resources, a Swift-side probe that lists
every anchored driver, and a `PDALApp.entitlements` for the "Designed
for iPad" macOS run path.

macOS consumers get a standard dynamic framework — no anchor needed,
all PDAL symbols stay live in the dylib.

## Topics

### Out-of-core streaming (COPC)

The streaming source operates entirely against the COPC format, which
embeds an octree directly in LAZ. Non-COPC inputs should be converted
once with `pdal translate in.las out.copc.laz --writers.copc`.

- ``StreamingPointCloudSource``
- ``CopcStreamingPointCloudSource``
- ``StreamingSourceInfo``
- ``StreamingOptions``
- ``StreamingDecodeGate``
- ``LODMode``
- ``StreamingSourceError``

### Camera and residency

- ``StreamingCameraView``
- ``ChunkID``
- ``ResidentChunk``
- ``StreamingRasterBatch``
- ``StreamingUpdate``

### Bulk point-cloud reading

- ``PointCloud``
- ``PointCloudData``
- ``PointCloudError``

### GPU-ready de-interleaved buffers (Struct-of-Arrays)

An additive, non-destructive export of a bulk-read ``PointCloud`` into
de-interleaved `Float32` buffers — one per dimension, plus packed,
centered `position` and normalized `color` — ready for a Metal compute
consumer with no CPU de-interleave pass. A GPU (Metal scatter) and a
vectorized CPU backend produce identical output; ``DeinterleaveBackend/auto``
picks the faster for the point count.

- ``PointCloud/deinterleavedGeometry(device:backend:wideningIntegersToFloat:options:)``
- ``PointCloud/deinterleavedGeometryCPU(wideningIntegersToFloat:)``
- ``DeinterleavedGeometry``
- ``DeinterleavedRawGeometry``
- ``DeinterleaveBackend``
- ``PointCloud/deinterleaveAutoGPUThreshold``

### Format conversion

`pdal convert`-equivalent API for synthesising and executing a
Reader → [Filters] → Writer pipeline (e.g. PLY → LAZ, PTX → COPC.LAZ).
Streaming-mode execution surfaces per-chunk progress and supports
cancellation.

- ``PDALConvert``
- ``ConvertOptions``
- ``ConvertResult``
- ``ConvertProgress``
- ``ConvertError``
- ``PDALStage``
- ``PDALValue``

### Per-dimension statistics + STAC sidecar

Single-pass per-attribute statistics computed during a conversion via
`filters.stats` — exact mean/stddev/min/max with no extra read — plus a
STAC pointcloud-extension sidecar writer for catalog tooling.

- ``PDALConvert/convertComputingStatistics(from:to:options:)``
- ``PointCloudStatistics``
- ``PointCloudDimensionStatistic``
- ``PointCloudDimensionSchema``
- ``PointCloudBounds``

### Streaming (PDAL pipeline)

Chunked progressive read for whole-file streaming. Distinct from the
COPC out-of-core path above.

- ``StreamingPointCloud``
- ``StreamingProgress``
- ``PointCloudChunk``

### Geometry and metadata

- ``Bounds``
- ``DimensionInfo``
- ``PDALDimensionTypeHelper``
- ``PDALError``

## Acknowledgements

- **PDAL** (BSD 3-Clause, © Hobu Inc.) — bulk-read and pipeline-streaming
  paths. <https://pdal.io>
- **copc-lib** (BSD 3-Clause, © 2021 Rock Robotic, Inc.) — out-of-core
  octree access for ``CopcStreamingPointCloudSource``.
  <https://github.com/RockRobotic/copc-lib>
- **laz-perf** (Apache 2.0, © 2022 Rapidlasso GmbH) — LAZ codec used by
  copc-lib. <https://github.com/hobuinc/laz-perf>

See [THIRD_PARTY_LICENSES.md](https://github.com/mnmly/SwiftPDAL/blob/main/THIRD_PARTY_LICENSES.md)
for full license text.
