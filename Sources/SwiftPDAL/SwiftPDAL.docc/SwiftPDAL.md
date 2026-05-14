# ``SwiftPDAL``

A Swift wrapper around PDAL for reading LAS/LAZ/COPC point clouds, plus
an out-of-core streaming source for large COPC files.

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

## Topics

### Out-of-core streaming (COPC)

The streaming source operates entirely against the COPC format, which
embeds an octree directly in LAZ. Non-COPC inputs should be converted
once with `pdal translate in.las out.copc.laz --writers.copc`.

- ``StreamingPointCloudSource``
- ``CopcStreamingPointCloudSource``
- ``StreamingSourceInfo``
- ``StreamingOptions``
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
