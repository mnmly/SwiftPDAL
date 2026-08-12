import Foundation
import simd
import CxxCOPC
import CxxStdlib

typealias CopcReader = swiftpdal.copc.Reader
typealias CopcNodeInfo = swiftpdal.copc.NodeInfo
typealias CopcNodeKey = swiftpdal.copc.NodeKey
typealias CopcEbFieldInfo = swiftpdal.copc.EbFieldInfo
typealias CopcExtractDesc = swiftpdal.copc.ExtractDesc

// MARK: - Standard LAS dimension table

/// Standard per-point LAS dimensions that can be streamed by name. The raw
/// `code` is shared verbatim with the C++ `read_node` accessor switch. Names
/// match the resident-path / PDAL dimension names so the same graph applies to
/// both sources.
enum StandardLasDim: Int32, CaseIterable {
    case classification = 0
    case intensity = 1
    case returnNumber = 2
    case numberOfReturns = 3
    case scanAngle = 4
    case userData = 5
    case pointSourceId = 6
    case gpsTime = 7

    var name: String {
        switch self {
        case .classification: return "Classification"
        case .intensity: return "Intensity"
        case .returnNumber: return "ReturnNumber"
        case .numberOfReturns: return "NumberOfReturns"
        case .scanAngle: return "ScanAngleRank"
        case .userData: return "UserData"
        case .pointSourceId: return "PointSourceId"
        case .gpsTime: return "GpsTime"
        }
    }

    /// Standard dims present for a given LAS point format id. GPS time is
    /// absent from formats 0 and 2; everything else is in every format.
    static func present(forPointFormat fmt: Int8) -> [StandardLasDim] {
        let hasGps = !(fmt == 0 || fmt == 2)
        return StandardLasDim.allCases.filter { $0 != .gpsTime || hasGps }
    }
}

// MARK: - Identity

/// Stable identifier for a streamable chunk.
///
/// Backed by a COPC octree key `(depth, x, y, z)` packed into a single
/// 64-bit value: 5 bits depth + 19 bits per axis. This representation is
/// stable across `Hashable` lookups in residency maps and keeps the
/// ``StreamingUpdate`` deltas cheap to diff.
///
/// `depth` may not exceed 31; per-axis indices may not exceed `2^19 - 1`.
/// COPC tilesets in practice stay far below these limits.
public struct ChunkID: Hashable, Sendable, CustomStringConvertible {
    /// The packed 64-bit representation.
    public let rawValue: UInt64

    /// Create a `ChunkID` from a previously-packed raw value.
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Create a `ChunkID` from a COPC `(depth, x, y, z)` voxel key.
    ///
    /// - Parameters:
    ///   - depth: Octree depth, 0 = root.
    ///   - x: Voxel index along the X axis at this depth.
    ///   - y: Voxel index along the Y axis at this depth.
    ///   - z: Voxel index along the Z axis at this depth.
    public init(depth: Int, x: Int, y: Int, z: Int) {
        let d  = UInt64(depth) & 0x1F
        let xv = UInt64(x) & 0x7FFFF
        let yv = UInt64(y) & 0x7FFFF
        let zv = UInt64(z) & 0x7FFFF
        self.rawValue = (d << 57) | (xv << 38) | (yv << 19) | zv
    }

    /// Octree depth, 0 = root.
    public var depth: Int { Int((rawValue >> 57) & 0x1F) }
    /// Voxel index along the X axis at this depth.
    public var x:     Int { Int((rawValue >> 38) & 0x7FFFF) }
    /// Voxel index along the Y axis at this depth.
    public var y:     Int { Int((rawValue >> 19) & 0x7FFFF) }
    /// Voxel index along the Z axis at this depth.
    public var z:     Int { Int( rawValue        & 0x7FFFF) }

    public var description: String { "ChunkID(d=\(depth), \(x),\(y),\(z))" }

    /// The COPC hierarchy parent of this chunk, or `nil` for the root.
    ///
    /// Mirrors copc-lib's `VoxelKey::GetParent()`: the parent one octree
    /// level up covers the same region at coarser density (`depth - 1`,
    /// with each axis index halved). A COPC hierarchy is connected from the
    /// root — every non-root node that carries points has a real parent
    /// node — so walking ``parent`` repeatedly always reaches the root.
    public var parent: ChunkID? {
        guard depth > 0 else { return nil }
        return ChunkID(depth: depth - 1, x: x >> 1, y: y >> 1, z: z >> 1)
    }
}

// MARK: - Source info

/// Static metadata about an opened streaming source.
///
/// Returned from ``CopcStreamingPointCloudSource/open(_:options:)`` and
/// stable for the lifetime of the source. Use ``bytesPerPoint`` together
/// with the renderer's batch granularity (``pointsPerBatch``) to size GPU
/// budgets.
public struct StreamingSourceInfo: Sendable {
    /// File-level AABB in source-file coordinates (before ``originShift``).
    public let bounds: Bounds
    /// Translation applied to every chunk's packed positions, in source
    /// coordinates. The renderer should incorporate this as the
    /// translation component of `RasterFile.world`.
    ///
    /// Set to the center of ``bounds`` at open. Required for 100B-point
    /// scenes where double-precision world coordinates exceed Float
    /// precision once batched.
    public let originShift: SIMD3<Double>
    /// Total point count across the whole file.
    public let totalPoints: UInt64
    /// Maximum octree depth present in the file's COPC hierarchy.
    public let maxDepth: Int
    /// Renderer batch granularity. COPC nodes are split into render
    /// batches of this size at decode time.
    public let pointsPerBatch: Int
    /// On-GPU byte cost per point: `xyzLow(4) + xyzMed(4) + xyzHigh(4)
    /// + colors(4) + levels(1) = 17`. Multiply by point count to predict
    /// VRAM footprint. Unaffected by extra dimensions (those ride host-side).
    public let bytesPerPoint: Int
    /// Per-point dimension names available to stream alongside position+color:
    /// the standard LAS dims present for this file's point format plus every
    /// custom Extra Bytes dimension declared in the file. Use to populate an
    /// attribute picker or validate a requested set.
    public let availableDimensions: [String]
    /// Host-side byte cost per point of the *requested* extra dimensions
    /// (`4 * requestedDimensionCount`), accounted separately from
    /// ``bytesPerPoint``. `0` when no extra dimensions were requested.
    public let extraBytesPerPoint: Int
    /// Node count at each octree depth (`nodesAtDepth[0]` = the root level).
    /// Length is `maxDepth + 1`; empty when the producer didn't supply it
    /// (a mock built through the memberwise init's default).
    public let nodesAtDepth: [Int]
    /// Slot footprint of the nodes at each octree depth: `slotsAtDepth[d]` is
    /// `Σ ceil(node.pointCount / pointsPerBatch)` over every node at depth `d`,
    /// the granularity ``StreamingPointCloudSource/setBudget(slots:)`` charges
    /// in. Length is `maxDepth + 1`; empty when the producer didn't supply it.
    ///
    /// Together with ``slotsThroughDepth(_:)`` this lets a host size a GPU pool
    /// for a *depth-limited* pin (see
    /// ``StreamingOptions/alwaysResidentDepth``) from the pinned set's real
    /// footprint instead of the whole hierarchy's — on a deep scan the two
    /// differ by two orders of magnitude.
    public let slotsAtDepth: [Int]

    /// Slot footprint of every node with `depth <= depth` — the exact pool cost
    /// of pinning at that depth. `nil` when ``slotsAtDepth`` is empty (the
    /// source didn't publish a histogram, so there is no basis to answer).
    ///
    /// Depths above ``maxDepth`` clamp to the whole hierarchy, matching
    /// ``StreamingOptions/alwaysResidentDepth``'s "pins every node" behavior;
    /// a negative depth is `0` (nothing pinned).
    public func slotsThroughDepth(_ depth: Int) -> Int? {
        guard !slotsAtDepth.isEmpty else { return nil }
        guard depth >= 0 else { return 0 }
        return slotsAtDepth.prefix(depth + 1).reduce(0, +)
    }

    /// Node count at `depth <= depth`, on the same contract as
    /// ``slotsThroughDepth(_:)``.
    public func nodesThroughDepth(_ depth: Int) -> Int? {
        guard !nodesAtDepth.isEmpty else { return nil }
        guard depth >= 0 else { return 0 }
        return nodesAtDepth.prefix(depth + 1).reduce(0, +)
    }

    /// Slot footprint of the whole hierarchy — what a fully-resident file
    /// costs. `nil` when ``slotsAtDepth`` is empty.
    ///
    /// Strictly greater than `ceil(totalPoints / pointsPerBatch)` whenever any
    /// node's final batch is partial, which on real scans is every node.
    public var totalSlots: Int? {
        slotsAtDepth.isEmpty ? nil : slotsAtDepth.reduce(0, +)
    }

    /// Create source metadata.
    ///
    /// Exposed so consumers can build a mock ``StreamingPointCloudSource``
    /// for unit tests without opening a real COPC file. The concrete
    /// ``CopcStreamingPointCloudSource`` fills this in from the file's header
    /// and hierarchy at open.
    ///
    /// - Parameters:
    ///   - bounds: File-level AABB in source-file coordinates.
    ///   - originShift: Translation applied to every chunk's packed positions.
    ///   - totalPoints: Total point count across the whole file.
    ///   - maxDepth: Maximum octree depth present in the hierarchy.
    ///   - pointsPerBatch: Renderer batch granularity.
    ///   - bytesPerPoint: On-GPU byte cost per point.
    ///   - availableDimensions: Per-point dimension names available to stream.
    ///   - extraBytesPerPoint: Host-side byte cost per point of requested
    ///     extra dimensions. Defaults to `0`.
    ///   - nodesAtDepth: Per-depth node counts. Defaults to empty ("unknown").
    ///   - slotsAtDepth: Per-depth slot footprints. Defaults to empty
    ///     ("unknown"), which makes ``slotsThroughDepth(_:)`` and
    ///     ``totalSlots`` return `nil` so callers fall back to their own
    ///     estimate rather than reading a bogus zero.
    public init(
        bounds: Bounds,
        originShift: SIMD3<Double>,
        totalPoints: UInt64,
        maxDepth: Int,
        pointsPerBatch: Int,
        bytesPerPoint: Int,
        availableDimensions: [String],
        extraBytesPerPoint: Int = 0,
        nodesAtDepth: [Int] = [],
        slotsAtDepth: [Int] = []
    ) {
        self.bounds = bounds
        self.originShift = originShift
        self.totalPoints = totalPoints
        self.maxDepth = maxDepth
        self.pointsPerBatch = pointsPerBatch
        self.bytesPerPoint = bytesPerPoint
        self.availableDimensions = availableDimensions
        self.extraBytesPerPoint = extraBytesPerPoint
        self.nodesAtDepth = nodesAtDepth
        self.slotsAtDepth = slotsAtDepth
    }
}

// MARK: - Camera

/// Camera state consumed by the residency policy.
///
/// All fields live in world-space; the streaming layer doesn't know about
/// projection conventions (handedness, reverse-Z) — only the AABB-vs-frustum
/// test on ``viewProjection`` and the distance-from-``position`` score.
public struct StreamingCameraView: Sendable, Equatable {
    /// World-space camera position used for distance scoring.
    public let position: SIMD3<Float>
    /// View-projection matrix used to derive 6 frustum planes.
    public let viewProjection: simd_float4x4
    /// Pixels per world-unit at unit distance. Drives the desired LOD
    /// depth target. Approximation: `screenHeight / (2 * tan(fov/2))`.
    /// Under an orthographic projection this is already pixels per
    /// world-unit *at any distance* (`viewportHeight * 0.5 * P[1][1]`,
    /// where `P[1][1] = 2/orthoHeight`) — the wanted-set scorer
    /// auto-detects ortho from ``viewProjection``'s w-row and skips the
    /// distance division in that case.
    public let pixelScale: Float
    /// Soft tolerance on depth selection. Nodes within ±N depth levels
    /// of the target depth remain resident.
    public let depthTolerance: Int

    /// Create a camera view.
    ///
    /// - Parameters:
    ///   - position: World-space camera position.
    ///   - viewProjection: View-projection matrix (frustum source).
    ///   - pixelScale: Pixels per world-unit at unit distance.
    ///   - depthTolerance: ±N depth levels kept resident around the
    ///     target depth.
    public init(
        position: SIMD3<Float>,
        viewProjection: simd_float4x4,
        pixelScale: Float,
        depthTolerance: Int = 1
    ) {
        self.position = position
        self.viewProjection = viewProjection
        self.pixelScale = pixelScale
        self.depthTolerance = depthTolerance
    }
}

// MARK: - Resident chunk payload

/// One render-batch's metadata, ready for GPU upload.
///
/// Field order intentionally mirrors `SatinComputeRasteriser.RasterBatch`
/// so glue code can `memcpy` an array of these into the renderer's batch
/// buffer. A static-layout assertion belongs in the consuming app —
/// SwiftPDAL deliberately does not import the renderer package.
public struct StreamingRasterBatch: Sendable {
    /// Residency flag the cull kernel reads. `1` = resident,
    /// `0` = empty/evicting. The renderer skips batches whose state is `0`.
    public var state: Int32
    /// AABB minimum X (origin-shifted, world units).
    public var minX: Float
    /// AABB minimum Y (origin-shifted, world units).
    public var minY: Float
    /// AABB minimum Z (origin-shifted, world units).
    public var minZ: Float
    /// AABB maximum X (origin-shifted, world units).
    public var maxX: Float
    /// AABB maximum Y (origin-shifted, world units).
    public var maxY: Float
    /// AABB maximum Z (origin-shifted, world units).
    public var maxZ: Float
    /// Number of points in this batch.
    public var numPoints: UInt32
    /// Offset of this batch's first point within its parent
    /// ``ResidentChunk``'s per-point buffers. The renderer rewrites this
    /// to a slot-relative offset after upload.
    public var firstPoint: UInt32
    /// Index into the renderer's `files` array. The streaming source
    /// always emits `0`; a multi-file compositor rewrites it.
    public var fileIndex: UInt32
    /// Cumulative LOD level counts `cum[0] | cum[1] << 16` (two `uint16`),
    /// where `cum[L]` is the number of points in this batch with LOD level
    /// ≤ `L`. Batch points are stored level-ascending, so `cum[L]` is the
    /// prefix length the renderer may draw at a given LOD threshold.
    public var padding3: UInt32 = 0
    /// Cumulative LOD level counts `cum[2] | cum[3] << 16`. See ``padding3``.
    public var padding4: UInt32 = 0
    /// Cumulative LOD level counts `cum[4] | cum[5] << 16`. See ``padding3``.
    public var padding5: UInt32 = 0
    /// Cumulative LOD level counts `cum[6] | cum[7] << 16`. See ``padding3``.
    /// `cum[7] == numPoints > 0` for every bucketed batch, so
    /// `padding6 == 0` is the legacy sentinel: consumers treat such a batch
    /// as unbucketed and fall back to full-range draws.
    public var padding6: UInt32 = 0
    public var padding7: UInt32 = 0
    public var padding8: UInt32 = 0

    /// Create a `StreamingRasterBatch`.
    ///
    /// - Parameters:
    ///   - state: `1` for resident, `0` for empty.
    ///   - min: AABB minimum corner.
    ///   - max: AABB maximum corner.
    ///   - numPoints: Point count in this batch.
    ///   - firstPoint: Offset within the chunk's per-point buffers.
    ///   - fileIndex: Renderer `files`-array index.
    public init(
        state: Int32,
        min: SIMD3<Float>,
        max: SIMD3<Float>,
        numPoints: UInt32,
        firstPoint: UInt32,
        fileIndex: UInt32
    ) {
        self.state = state
        self.minX = min.x; self.minY = min.y; self.minZ = min.z
        self.maxX = max.x; self.maxY = max.y; self.maxZ = max.z
        self.numPoints = numPoints
        self.firstPoint = firstPoint
        self.fileIndex = fileIndex
    }
}

/// A decoded, packed, ready-to-upload chunk.
///
/// Contains 1..K ``StreamingRasterBatch`` entries (one per
/// `pointsPerBatch`-sized partition of the COPC node) plus the per-point
/// buffers for the whole chunk. The buffers are concatenated across
/// batches — ``StreamingRasterBatch/firstPoint`` indexes into them.
///
/// All buffer lengths are derived from ``totalPointCount``:
/// - ``xyzLow``, ``xyzMed``, ``xyzHigh``, ``colors``: `4 * totalPointCount`
/// - ``levels``: `1 * totalPointCount`
public struct ResidentChunk: Sendable {
    /// Stable identifier matching the source COPC node.
    public let id: ChunkID
    /// Per-batch metadata. Each batch covers `pointsPerBatch` points
    /// (the last batch may be shorter).
    public let batches: [StreamingRasterBatch]
    /// Packed positions, 10 bits per axis, low-significance fragment.
    /// One `UInt32` per point.
    public let xyzLow: Data
    /// Packed positions, middle fragment. One `UInt32` per point.
    public let xyzMed: Data
    /// Packed positions, high-significance fragment. One `UInt32` per
    /// point. Reconstructed position = `(low | med << 10 | high << 20)`
    /// scaled to the batch's AABB.
    public let xyzHigh: Data
    /// RGBA8 packed colors, one `UInt32` per point. Alpha is always `255`.
    public let colors: Data
    /// Per-point LOD level, one `UInt8` per point. `0` = coarsest
    /// (visible at distance), `levelsCount - 1` = finest.
    public let levels: Data
    /// Optional per-point scalar dimensions (Float32, one per point), keyed by
    /// dimension name and Morton-reordered to match ``xyzLow``/``colors``.
    /// Empty unless extra dimensions were requested via
    /// ``StreamingOptions/extraDimensions``.
    public let extraScalars: [String: Data]

    /// Total points in this chunk (sum of `batches[i].numPoints`).
    public var totalPointCount: Int { batches.reduce(0) { $0 + Int($1.numPoints) } }
    /// Approximate GPU byte cost: `totalPointCount * (17 + 4 per extra
    /// dimension)` — positions + colors + levels, plus one Float32 per point
    /// per streamed extra dimension. Use this to track budget against
    /// ``StreamingSourceInfo/bytesPerPoint`` +
    /// ``StreamingSourceInfo/extraBytesPerPoint``.
    public var byteCost: Int { totalPointCount * (17 + 4 * extraScalars.count) }

    /// Create a resident chunk.
    ///
    /// Exposed so consumers can build a mock ``StreamingPointCloudSource``
    /// for unit tests without opening a real COPC file. The concrete
    /// ``CopcStreamingPointCloudSource`` populates every field from a decoded
    /// node; a mock can supply whatever the test needs (empty buffers are
    /// fine for residency-protocol tests that never touch the GPU).
    ///
    /// - Parameters:
    ///   - id: Stable identifier matching the source COPC node.
    ///   - batches: Per-batch metadata (one per `pointsPerBatch` partition).
    ///   - xyzLow: Packed positions, low-significance fragment.
    ///   - xyzMed: Packed positions, middle fragment.
    ///   - xyzHigh: Packed positions, high-significance fragment.
    ///   - colors: RGBA8 packed colors, one `UInt32` per point.
    ///   - levels: Per-point LOD level, one `UInt8` per point.
    ///   - extraScalars: Optional per-point scalar dimensions keyed by name.
    ///     Defaults to empty (the position+color-only path).
    public init(
        id: ChunkID,
        batches: [StreamingRasterBatch],
        xyzLow: Data,
        xyzMed: Data,
        xyzHigh: Data,
        colors: Data,
        levels: Data,
        extraScalars: [String: Data] = [:]
    ) {
        self.id = id
        self.batches = batches
        self.xyzLow = xyzLow
        self.xyzMed = xyzMed
        self.xyzHigh = xyzHigh
        self.colors = colors
        self.levels = levels
        self.extraScalars = extraScalars
    }
}

// MARK: - Update result

/// Delta to apply to GPU residency on the next frame.
///
/// Returned from ``StreamingPointCloudSource/pollLatest()``. The consumer
/// applies ``removed`` first (frees GPU slots), then ``added`` (allocates
/// slots, blits payloads, patches the batch table).
public struct StreamingUpdate: Sendable {
    /// Chunks that became resident since the last drain.
    public let added: [ResidentChunk]
    /// Chunks that should be evicted from GPU residency.
    public let removed: [ChunkID]
    /// Convenience: `true` if both ``added`` and ``removed`` are empty.
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    /// Create an update.
    public init(added: [ResidentChunk], removed: [ChunkID]) {
        self.added = added
        self.removed = removed
    }
}

// MARK: - Decode-queue telemetry

/// A thread-safe snapshot of the source's decode pipeline, returned by
/// ``StreamingPointCloudSource/decodeStats()``.
///
/// Poll this to observe streaming progress and back-pressure without an
/// `await`: a rising ``pendingRequests`` with a flat ``decodedChunks`` means
/// decodes are queued behind the concurrency cap (see
/// ``StreamingDecodeGate``); a ``pendingRequests`` and ``inFlightDecodes`` of
/// zero with the wanted set filled means the pipeline is idle/caught up.
public struct StreamingDecodeStats: Sendable {
    /// Nodes scheduled for decode but not yet being decoded — either waiting
    /// in the internal job queue or parked on the process-wide decode gate.
    /// **Instantaneous**: reflects the pipeline at the moment of the call.
    public let pendingRequests: Int
    /// Nodes currently being decoded on a worker (past the gate, mid-LAZ
    /// decompress + pack). **Instantaneous.** Bounded in practice by
    /// ``StreamingOptions/decodeConcurrency`` and the shared
    /// ``StreamingDecodeGate`` limit.
    public let inFlightDecodes: Int
    /// Total chunks successfully decoded over the source's lifetime.
    /// **Monotonic**: only ever increases (never reset while the source is
    /// open).
    public let decodedChunks: UInt64
    /// Total points across all successfully decoded chunks over the source's
    /// lifetime. **Monotonic.**
    public let decodedPoints: UInt64

    /// Create a decode-stats snapshot. All counters default to zero so a mock
    /// source can return an empty snapshot.
    public init(
        pendingRequests: Int = 0,
        inFlightDecodes: Int = 0,
        decodedChunks: UInt64 = 0,
        decodedPoints: UInt64 = 0
    ) {
        self.pendingRequests = pendingRequests
        self.inFlightDecodes = inFlightDecodes
        self.decodedChunks = decodedChunks
        self.decodedPoints = decodedPoints
    }
}

// MARK: - Options

/// LOD level assignment strategy.
///
/// COPC's depth-based hierarchy is the primary LOD signal; per-point
/// levels are a within-chunk fine-grained dither. See `docs/streaming.md`
/// for the precomputed-sidecar tradeoff.
public enum LODMode: Sendable {
    /// Compute per-point LOD levels locally at decode time using
    /// density-aware voxel occupancy on the current chunk's bounds.
    ///
    /// Cheap (no precompute) but density bands won't be globally
    /// consistent across nodes — neighbouring chunks may classify the
    /// same physical region into different LOD bands.
    case perChunk

    /// Read precomputed LOD levels from a sidecar built by an offline
    /// tool. Falls back to ``perChunk`` if the sidecar is missing.
    ///
    /// - Parameter URL: Path to `<file>.swiftpdal-lod`.
    case sidecar(URL)
}

/// How the residency policy turns a camera view into a wanted set of
/// chunks. Independent of the budget fill: regardless of mode, the
/// wanted set is capped by the running budget and the eviction
/// hysteresis still applies.
public enum ResidencyPolicy: Equatable, Sendable {
    /// Two-pass fill (default). First admit chunks intersecting the
    /// camera frustum, scored by distance, until the budget is full.
    /// If headroom remains, do a second pass over the rejected
    /// non-visible chunks (sorted by distance) to surround the camera
    /// with a halo of nearby off-screen chunks — ready for the moment
    /// the user turns their head.
    case frustumFirstThenHalo
    /// Ignore the frustum entirely and score every chunk by distance
    /// from the camera position. Right choice for VR / free-camera
    /// scrubbing, where any chunk near the camera could become visible
    /// at any moment.
    case distanceOnly
}

/// Configuration for ``CopcStreamingPointCloudSource``.
public struct StreamingOptions: Sendable {
    /// Maximum chunks scheduled for decode per driver tick. Acts as the
    /// per-tick work budget; the actual parallelism is bounded by
    /// ``decodeConcurrency``.
    public var maxInFlightLoads: Int
    /// Number of independent COPC ``FileReader`` instances opened against
    /// the file. Each reader owns its own `fstream`, so up to this many
    /// node decodes run concurrently on cooperative threads. Setting this
    /// above the physical core count rarely helps; the underlying LAZ
    /// decompression is single-threaded per chunk. This is the *per-source*
    /// reader-pool size; aggregate decode concurrency across all open
    /// sources is additionally bounded by ``StreamingDecodeGate``.
    public var decodeConcurrency: Int
    /// LOD level source. See ``LODMode``.
    public var lodMode: LODMode
    /// If `true`, the first ``StreamingPointCloudSource/pollLatest()``
    /// after open blocks on root + depth-1 nodes so the initial frame
    /// isn't empty. Adds startup latency.
    public var prefetchRoot: Bool
    /// Driver ticks a chunk must miss the wanted set before eviction.
    /// Hysteresis against camera-dolly thrash.
    public var evictionDelayTicks: Int
    /// Wall-clock interval between residency-policy ticks. Typical:
    /// 50–200 ms (camera state changes slowly relative to a 60 Hz frame).
    public var driverTickInterval: Duration
    /// Strategy for translating the camera view into the wanted set.
    /// See ``ResidencyPolicy``. Whole-file mode (every chunk wanted)
    /// engages automatically whenever the file fits in the current
    /// budget, regardless of this setting.
    public var residencyPolicy: ResidencyPolicy
    /// Target on-screen size of a single COPC node's longest AABB
    /// axis, in pixels. The residency scorer ranks each candidate node
    /// by how close its projected screen size is to this value:
    /// nodes that project to roughly this many pixels win, nodes that
    /// would be much smaller (over-detailed) or much larger
    /// (under-detailed) lose. Lower values pull finer-depth chunks
    /// into residency sooner; higher values bias toward coarse
    /// coverage. 256 px per chunk is a reasonable default for
    /// per-point density on a typical desktop display.
    public var targetChunkScreenSize: Float
    /// Per-point dimension names to stream alongside position+color, by name
    /// (standard LAS dims like `"Classification"`/`"Intensity"`, or custom
    /// Extra Bytes dimension names). **Opt-in:** empty (the default) preserves
    /// the exact position+color-only path. Names not present in the file are
    /// dropped (see ``StreamingSourceInfo/availableDimensions``).
    public var extraDimensions: [String]
    /// If `true`, stream **every** dimension in
    /// ``StreamingSourceInfo/availableDimensions`` (ignoring
    /// ``extraDimensions``). For inspector/spreadsheet use that wants all
    /// attributes without scanning a graph. Default `false`.
    public var requestAllAvailableDimensions: Bool
    /// Enforce the COPC hierarchy residency invariant: a non-root node is
    /// only ever published as resident once its parent is resident, and a
    /// node is only evicted once none of its children remain resident.
    ///
    /// COPC partitions a region's points across octree levels — full
    /// density at any point is the *union* of a node and all its ancestors.
    /// With this on (the default), the residency scorer still prioritizes
    /// by screen-space error, but the wanted set is expanded to include
    /// each admitted node's missing ancestor chain (charged to the slot
    /// budget, ancestors first), eviction proceeds leaf-first, and every
    /// published ``StreamingUpdate`` lists parents before descendants in
    /// ``StreamingUpdate/added`` and descendants before parents in
    /// ``StreamingUpdate/removed``. The net effect is that a consumer never
    /// renders a fine node's sparse slice without the coarser ancestors
    /// that fill in the rest of its density.
    ///
    /// Set to `false` to restore the pre-invariant score-only behavior
    /// (finer nodes may become resident before their ancestors). Only do
    /// this if a consumer deliberately relies on the old, unordered deltas.
    public var enforceHierarchyResidency: Bool

    /// Depth (inclusive) at/below which octree nodes are pinned permanently
    /// resident, or `nil` (the default) to disable coarse pinning entirely.
    ///
    /// When set, the source keeps every node with `depth <= alwaysResidentDepth`
    /// resident for the lifetime of the source: they are scheduled *before*
    /// any scored chunk (coarse coverage arrives first), never appear in a
    /// ``StreamingUpdate/removed`` delta, and are de-duplicated against
    /// re-admission. COPC's full density at any point is the union of a node
    /// and all its ancestors, so a handful of shallow nodes — a negligible
    /// fraction of the points — blanket the whole scene at low density.
    /// Pinning them turns a fine node's transient "empty until its parents
    /// arrive" hole into "briefly coarse", which is the correct streaming UX.
    ///
    /// ## Budget accounting
    ///
    /// Pinned nodes **are** charged against the slot budget set via
    /// ``StreamingPointCloudSource/setBudget(slots:)`` (or the byte-denominated
    /// ``StreamingPointCloudSource/setBudget(_:)``) — they occupy the same GPU
    /// slots the scorer draws from, at `ceil(pointCount / pointsPerBatch)` slots
    /// each. Their cost is charged first; the
    /// screen-space-error scorer then fills whatever headroom remains. If the
    /// pinned set alone meets or exceeds the budget, scored residency clamps
    /// to zero rather than evicting any pinned node — the pins are honored
    /// regardless of budget, so size the budget to comfortably exceed the
    /// pinned set's footprint.
    ///
    /// ## Hierarchy-invariant interaction
    ///
    /// A depth-limited prefix `0...alwaysResidentDepth` is already closed
    /// under parent, so pinning composes cleanly with
    /// ``enforceHierarchyResidency``: pinned nodes publish parent-first (the
    /// root has no parent and lands immediately, then depth 1, …) and a
    /// scored fine node's ancestor-chain climb terminates at the pinned
    /// prefix instead of re-charging it. Pins are never evicted, so leaf-first
    /// eviction never has to pull one out from under a resident descendant.
    ///
    /// A value `< 0` is treated the same as `nil` (off). Values above the
    /// file's ``StreamingSourceInfo/maxDepth`` simply pin every node.
    public var alwaysResidentDepth: Int?

    /// Aggregate concurrent-decode cap for the process-wide
    /// ``StreamingDecodeGate``, or `nil` (the default) to auto-size it.
    ///
    /// The gate bounds how many LAZ decodes run at once across *all* open
    /// streaming sources (not just this one). Its default floor is
    /// `activeProcessorCount - 2` (leaving two cores for the rest of the
    /// process), which can sit *below* a source's own ``decodeConcurrency`` —
    /// silently capping a source configured for, say, 18 workers at 16
    /// concurrent decodes.
    ///
    /// - `nil` (default): on open, the gate is raised to *at least* this
    ///   source's ``decodeConcurrency`` via
    ///   ``StreamingDecodeGate/ensureLimitAtLeast(_:)``, so a single source
    ///   always gets the parallelism it asked for while still composing with
    ///   other open sources (the gate ends at the max request). Never lowered.
    /// - non-`nil`: on open, the gate is set to exactly this value via
    ///   ``StreamingDecodeGate/setLimit(_:)`` — an explicit aggregate ceiling
    ///   for hosts that open many sources. Set it `>=` ``decodeConcurrency``
    ///   to avoid throttling this source's own workers.
    public var decodeGateLimit: Int?

    /// Create a configuration.
    ///
    /// - Parameters:
    ///   - maxInFlightLoads: Per-tick scheduling cap.
    ///   - decodeConcurrency: Reader-pool size; max simultaneous decoders.
    ///   - lodMode: LOD assignment strategy.
    ///   - prefetchRoot: Block on coarse nodes during first poll.
    ///   - evictionDelayTicks: Hysteresis frames.
    ///   - driverTickInterval: Tick cadence.
    ///   - residencyPolicy: Wanted-set construction strategy.
    ///   - targetChunkScreenSize: Pixels per chunk target for LOD
    ///     selection. See ``targetChunkScreenSize``.
    ///   - extraDimensions: Per-point dimension names to stream (opt-in;
    ///     empty preserves the position+color-only path).
    ///   - requestAllAvailableDimensions: Stream every available dimension.
    ///   - enforceHierarchyResidency: Keep the resident set closed under
    ///     parent (default `true`). See ``enforceHierarchyResidency``.
    ///   - alwaysResidentDepth: Depth at/below which nodes are pinned
    ///     permanently resident, or `nil` (default) to disable pinning.
    ///     See ``alwaysResidentDepth``.
    ///   - decodeGateLimit: Explicit process-wide decode-gate cap, or `nil`
    ///     (default) to auto-size it to at least ``decodeConcurrency``.
    ///     See ``decodeGateLimit``.
    public init(
        maxInFlightLoads: Int = 4,
        decodeConcurrency: Int = 4,
        lodMode: LODMode = .perChunk,
        prefetchRoot: Bool = true,
        evictionDelayTicks: Int = 5,
        driverTickInterval: Duration = .milliseconds(100),
        residencyPolicy: ResidencyPolicy = .frustumFirstThenHalo,
        targetChunkScreenSize: Float = 256,
        extraDimensions: [String] = [],
        requestAllAvailableDimensions: Bool = false,
        enforceHierarchyResidency: Bool = true,
        alwaysResidentDepth: Int? = nil,
        decodeGateLimit: Int? = nil
    ) {
        self.maxInFlightLoads = maxInFlightLoads
        self.decodeConcurrency = decodeConcurrency
        self.lodMode = lodMode
        self.prefetchRoot = prefetchRoot
        self.evictionDelayTicks = evictionDelayTicks
        self.driverTickInterval = driverTickInterval
        self.residencyPolicy = residencyPolicy
        self.targetChunkScreenSize = targetChunkScreenSize
        self.extraDimensions = extraDimensions
        self.requestAllAvailableDimensions = requestAllAvailableDimensions
        self.enforceHierarchyResidency = enforceHierarchyResidency
        self.alwaysResidentDepth = alwaysResidentDepth
        self.decodeGateLimit = decodeGateLimit
    }
}

// MARK: - Errors

/// Errors thrown by ``CopcStreamingPointCloudSource/open(_:options:)``.
public enum StreamingSourceError: Error {
    /// The file could not be opened as a COPC LAZ. May indicate a
    /// non-COPC LAS/LAZ — convert with
    /// `pdal translate in.las out.copc.laz --writers.copc`.
    case openFailed(URL)
    /// COPC header parsed but hierarchy is malformed or unreachable.
    case malformedHierarchy(String)
    /// Underlying I/O failure.
    case ioFailed(String)
    /// Sidecar specified via ``LODMode/sidecar(_:)`` couldn't be read.
    case lodSidecarUnreadable(URL, underlying: Error?)
}

// MARK: - Protocol

/// Out-of-core point cloud source for the Satin-ComputeRasteriser pipeline.
///
/// Owns a COPC file's octree, decides per-tick residency against a camera
/// and residency budget, and returns ready-to-upload chunks. The protocol is
/// deliberately small so the renderer package stays free of PDAL /
/// LASzip / copc-lib dependencies.
///
/// ## Usage
///
/// ```swift
/// let source = try await CopcStreamingPointCloudSource.open(url)
/// source.setBudget(slots: slotPoolCapacity)  // size to the renderer's slot pool
/// // or, byte-denominated (converted to whole slots internally):
/// source.setBudget(2 << 30)                  // 2 GB
///
/// // every frame (cheap, non-async):
/// source.submit(view: camera)
/// if let delta = source.pollLatest() {
///     renderer.removeBatches(forChunks: delta.removed)
///     renderer.addBatches(delta.added)
/// }
///
/// source.close()
/// ```
///
/// ## Threading
///
/// All methods on this protocol are safe to call from any thread.
/// Implementations run an internal driver `Task` that scores the
/// hierarchy and dispatches loads at ``StreamingOptions/driverTickInterval``;
/// the render thread never `await`s.
public protocol StreamingPointCloudSource: AnyObject, Sendable {
    /// File-level metadata. Stable for the lifetime of the source.
    var info: StreamingSourceInfo { get }

    /// Update the camera the residency policy targets.
    ///
    /// Latest-wins: intermediate submissions are coalesced. Safe to call
    /// every frame; non-blocking.
    ///
    /// - Parameter view: Current camera state.
    func submit(view: StreamingCameraView)

    /// Submit several camera views at once; the residency wanted-set becomes
    /// the **union** across all views — a node is wanted if *any* view sees it,
    /// scored by its best on-screen match across the set. Use this to cover a
    /// multi-projection frame (CAVE walls + floor, stereo eyes) or to preload a
    /// known camera path (sample poses ahead and submit them together) from one
    /// streamed cloud. Latest-wins and non-blocking, exactly like
    /// ``submit(view:)`` — an empty array is ignored.
    ///
    /// The budget still caps the union, so size it to hold every view's working
    /// set; ``residencyBudgetLimited`` reports when it didn't.
    ///
    /// - Parameter views: The camera views to union.
    func submit(views: [StreamingCameraView])

    /// Update the budget for resident payloads (positions + colors + levels),
    /// expressed in bytes. Takes effect on the next driver tick.
    ///
    /// Residency is admitted in whole GPU **slots** (see ``setBudget(slots:)``),
    /// so the byte figure is converted conservatively to a slot count
    /// (`bytes / (pointsPerBatch × bytesPerPoint)`): the equivalent number of
    /// *full* slots, charging the partial-batch waste that a pure byte budget
    /// would ignore. Prefer ``setBudget(slots:)`` when sizing directly against a
    /// renderer slot pool.
    ///
    /// - Parameter bytes: Maximum total payload bytes. Resident chunks
    ///   will not exceed this budget.
    func setBudget(_ bytes: Int)

    /// Update the residency budget in whole GPU **slots**. Takes effect on the
    /// next driver tick.
    ///
    /// The renderer stores each decoded node in fixed-size slots of
    /// ``StreamingSourceInfo/pointsPerBatch`` points; a node with `N` points
    /// occupies `ceil(N / pointsPerBatch)` whole slots, so a partial final batch
    /// still burns a full slot. Budgeting in slots (rather than bytes) makes
    /// "the wanted set physically fits the slot pool" hold by construction — the
    /// byte budget was systematically optimistic because it ignored that
    /// partial-batch rounding. Size this to your renderer's slot-pool capacity.
    ///
    /// A default no-op implementation is provided so existing conformers stay
    /// source-compatible; ``CopcStreamingPointCloudSource`` overrides it.
    ///
    /// - Parameter slots: Maximum number of GPU slots the resident set may
    ///   occupy.
    func setBudget(slots: Int)

    /// Synchronously drain pending residency changes.
    ///
    /// Non-blocking. Returns `nil` if nothing has changed since the last
    /// poll. Use this on the render thread.
    ///
    /// - Returns: A ``StreamingUpdate`` delta, or `nil`.
    func pollLatest() -> StreamingUpdate?

    /// Asynchronous equivalent of ``pollLatest()``.
    ///
    /// Currently returns the same snapshot as the synchronous variant —
    /// use this from non-rendering contexts (background prefetch
    /// coordinators, tests).
    func nextUpdate() async -> StreamingUpdate?

    /// Cancel in-flight loads for the given chunk IDs.
    ///
    /// No-op for chunks that have already completed loading; they'll be
    /// evicted on the next residency tick instead.
    ///
    /// - Parameter chunkIDs: Chunks to cancel.
    func cancel(_ chunkIDs: [ChunkID])

    /// Stop the driver, release file handles, and free residency state.
    ///
    /// Subsequent calls to ``pollLatest()`` return `nil` and ``submit(view:)``
    /// becomes a no-op.
    func close()

    /// Retarget the residency scorer's desired on-screen chunk size at
    /// runtime.
    ///
    /// Mirrors ``StreamingOptions/targetChunkScreenSize`` but adjustable on a
    /// live source — no restart, re-open, or budget change. The new value
    /// takes effect on the next residency tick's re-score: it changes which
    /// nodes the scorer *wants*, biasing toward finer detail (lower values)
    /// or coarser coverage (higher values). Already-resident chunks are left
    /// alone until they fall out of the wanted set through the normal
    /// eviction hysteresis / refinement, so retargeting never causes a
    /// visible flush. Values are clamped to `>= 1`.
    ///
    /// A default no-op implementation is provided so existing conformers stay
    /// source-compatible; ``CopcStreamingPointCloudSource`` overrides it.
    ///
    /// - Parameter pixels: New target on-screen size, in pixels, of a node's
    ///   longest AABB axis.
    func setTargetChunkScreenSize(_ pixels: Float)

    /// Swap the wanted-set construction strategy on a live source — no restart
    /// or re-open. Takes effect on the next residency tick's re-score.
    /// A default no-op is provided; ``CopcStreamingPointCloudSource`` overrides.
    /// See ``StreamingOptions/residencyPolicy``.
    ///
    /// - Parameter policy: New ``ResidencyPolicy``.
    func setResidencyPolicy(_ policy: ResidencyPolicy)

    /// Toggle the parent-closed residency invariant on a live source. Takes
    /// effect on the next tick. A default no-op is provided;
    /// ``CopcStreamingPointCloudSource`` overrides. See
    /// ``StreamingOptions/enforceHierarchyResidency``.
    ///
    /// - Parameter enabled: New enforcement flag.
    func setEnforceHierarchyResidency(_ enabled: Bool)

    /// Retarget the QoS of the LAZ decode worker pool on a live source — no
    /// restart or re-open.
    ///
    /// Decode workers default to ``TaskPriority/utility`` so the OS parks them
    /// on E-cores and they never contend with the render loop for P-cores
    /// during interactive playback. That trade is wrong for an **offline**
    /// export: there's no live render loop to protect, and the per-frame
    /// residency pre-roll waits on the decode backlog draining — on E-cores it
    /// drains far too slowly (a multi-thousand-node backlog can miss a 20 s
    /// pre-roll budget every frame). Hosts raise this to
    /// ``TaskPriority/high``/``userInitiated`` for the duration of an export so
    /// decode runs on P-cores, then restore ``TaskPriority/utility``. It's kept
    /// export-*gated* rather than always-P-cores precisely because live
    /// playback must not steal P-cores from rendering.
    ///
    /// A default no-op implementation is provided so existing conformers stay
    /// source-compatible; ``CopcStreamingPointCloudSource`` overrides it.
    ///
    /// - Parameter priority: New base ``TaskPriority`` for the decode workers.
    func setDecodeWorkerPriority(_ priority: TaskPriority)

    /// A thread-safe, non-blocking snapshot of the decode pipeline.
    ///
    /// Poll this alongside ``pollLatest()`` to drive progress UI or diagnose
    /// back-pressure. See ``StreamingDecodeStats`` for the monotonic-vs-
    /// instantaneous semantics of each field.
    ///
    /// A default implementation returning an empty snapshot is provided so
    /// existing conformers stay source-compatible;
    /// ``CopcStreamingPointCloudSource`` overrides it.
    ///
    /// - Returns: The current ``StreamingDecodeStats``.
    func decodeStats() -> StreamingDecodeStats

    /// Synchronous, non-blocking: `true` once every wanted chunk (for the most
    /// recently submitted view set at the current budget) is resident and no
    /// decode is in flight — i.e. the frame is fully streamed in. Submitting a
    /// new view (or view set) drops this to `false` until the driver has caught
    /// up. Poll it to drive a "pump until resident" loop (see the offline
    /// pre-roll) without an actor hop or an `await`.
    ///
    /// A default of `true` is provided so non-streaming conformers (test mocks)
    /// never stall such a loop; ``CopcStreamingPointCloudSource`` overrides it.
    var isResidencySettled: Bool { get }

    /// Whether the wanted set was clamped by the slot budget while
    /// frustum-visible candidates were left out. Read alongside
    /// ``isResidencySettled``: settled **and** budget-limited means "everything
    /// the budget allows is resident, but more is visible" — raise the budget to
    /// cover the rest. Default `false`.
    var residencyBudgetLimited: Bool { get }

    /// Pre-clamp residency **demand** in GPU slots: the total slot cost of the
    /// current view set's candidate nodes, measured each score pass *before* the
    /// slot budget clamps the wanted set. This is the source's unclamped appetite
    /// for the current camera(s) — what the wanted set would cost if the budget
    /// were unbounded — expressed in the same whole-slot unit as
    /// ``setBudget(slots:)`` (a node costs `ceil(pointCount / pointsPerBatch)`).
    ///
    /// A node counts toward demand when it is a frustum-visible candidate (every
    /// node under ``ResidencyPolicy/distanceOnly`` and the whole-file shortcut,
    /// where all nodes are candidates). A source whose clouds are entirely out of
    /// every submitted frustum reports `0`; a source in view reports its full
    /// on-screen appetite. Because demand is measured *before* the budget clamp,
    /// it does **not** move when the budget changes — granting a source more
    /// budget changes its resident/wanted set but never its reported demand.
    ///
    /// This makes it the stable weight for a host budget governor that divides a
    /// global streaming budget across several sources *proportionally to demand*:
    /// the four huge in-view clouds report large demand and win most of the
    /// budget, while the many small/out-of-frustum clouds report little and cede
    /// their share. `0` until the first score pass completes. Default `0`.
    var residencyDemandSlots: Int { get }
}

public extension StreamingPointCloudSource {
    /// Default no-op: a source that doesn't support runtime retargeting
    /// simply ignores the new value. See
    /// ``setTargetChunkScreenSize(_:)``.
    func setTargetChunkScreenSize(_ pixels: Float) {}

    /// Default no-op: a source that doesn't distinguish a slot budget simply
    /// ignores it. See ``setBudget(slots:)``.
    func setBudget(slots: Int) {}

    /// Default no-op. See ``setResidencyPolicy(_:)``.
    func setResidencyPolicy(_ policy: ResidencyPolicy) {}

    /// Default no-op. See ``setEnforceHierarchyResidency(_:)``.
    func setEnforceHierarchyResidency(_ enabled: Bool) {}

    /// Default no-op: a source without a decode worker pool ignores the QoS
    /// change. See ``setDecodeWorkerPriority(_:)``.
    func setDecodeWorkerPriority(_ priority: TaskPriority) {}

    /// Default: an empty snapshot for sources without a decode pipeline
    /// (e.g. test mocks). See ``decodeStats()``.
    func decodeStats() -> StreamingDecodeStats { StreamingDecodeStats() }

    /// Default: forward the last view so non-overriding sources still stream
    /// (single-view). ``CopcStreamingPointCloudSource`` overrides it to union.
    func submit(views: [StreamingCameraView]) {
        if let v = views.last { submit(view: v) }
    }

    /// Default: non-streaming sources are always "settled". See
    /// ``isResidencySettled``.
    var isResidencySettled: Bool { true }

    /// Default: non-streaming sources are never budget-limited. See
    /// ``residencyBudgetLimited``.
    var residencyBudgetLimited: Bool { false }

    /// Default: non-streaming sources report no demand (nothing to govern). See
    /// ``residencyDemandSlots``.
    var residencyDemandSlots: Int { 0 }
}

// MARK: - Node metadata snapshot

struct NodeMeta: Sendable {
    let id: ChunkID
    let pointCount: Int
    let minXYZ: SIMD3<Float>   // origin-shifted, Float
    let maxXYZ: SIMD3<Float>
    let center: SIMD3<Float>
    let extent: Float          // longest-axis size
    /// File offset of this node's compressed LAZ block. Drives
    /// offset-adjacency clustering for coalesced prefetch (``NodePrefetch``).
    let offset: UInt64
    /// Compressed byte size of this node's block. Bounds a cluster's read span.
    let byteSize: Int
}

// MARK: - Prefetch clustering

/// Offset-adjacency clustering for coalesced node prefetch.
///
/// COPC stores sibling nodes contiguously, so decoding N adjacent nodes need
/// not pay N seeks / N HTTP round-trips: they can be read as one (or a few)
/// spans. This groups load-priority-ordered nodes into clusters of
/// offset-adjacent siblings — the C++ ``CopcReader/prefetch_nodes`` then reads
/// each cluster's span in one shot and slices it into a per-slot cache that
/// `read_node` consumes.
enum NodePrefetch {
    /// Max byte gap between two consecutive compressed blocks to still cluster
    /// them for one read on a **local** file. Mirrors `kPrefetchGapLocal` in
    /// `copc_bridge.cpp` — keep the two in sync. A local seek is cheap, so we
    /// only bridge a gap smaller than the cost of reading it (256 KB).
    static let gapLocalBytes: UInt64 = 256 * 1024
    /// HTTP counterpart of ``gapLocalBytes``. Mirrors `kPrefetchGapHttp` — a
    /// round-trip dominates, so bridging up to a megabyte of wasted body beats
    /// a second RTT on any plausible link.
    static let gapHttpBytes: UInt64 = 1024 * 1024
    /// Max nodes per cluster. Caps cancellation granularity (a cluster is
    /// popped + prefetched atomically) and per-slot prefetch memory.
    static let maxNodesPerCluster = 8
    /// Max total compressed bytes per cluster. Bounds first-decode latency (a
    /// worker reads the whole cluster span before decoding its first node) and
    /// per-slot prefetch memory. ~16 MB.
    static let maxBytesPerCluster = 16 * 1024 * 1024

    /// Gap threshold for the given transport.
    static func gapBytes(isRemote: Bool) -> UInt64 {
        isRemote ? gapHttpBytes : gapLocalBytes
    }

    /// Group load-priority-ordered nodes into offset-adjacent clusters,
    /// preserving overall load priority.
    ///
    /// - Parameters:
    ///   - ordered: nodes in load-priority order (best to load first), each
    ///     with its compressed-block file `offset` and byte `size`.
    ///   - gapBytes: max gap between consecutive blocks to keep them in one
    ///     cluster (see ``gapBytes(isRemote:)``).
    ///   - maxNodes: hard cap on nodes per cluster.
    ///   - maxBytes: hard cap on total compressed bytes per cluster.
    /// - Returns: clusters of chunk IDs. Clusters are ordered by their best
    ///   (earliest-in-`ordered`) member; within a cluster, members are ordered
    ///   best-first so the most important node decodes first.
    static func cluster(
        _ ordered: [(id: ChunkID, offset: UInt64, size: Int)],
        gapBytes: UInt64,
        maxNodes: Int = maxNodesPerCluster,
        maxBytes: Int = maxBytesPerCluster
    ) -> [[ChunkID]] {
        if ordered.isEmpty { return [] }

        // Tag each node with its load priority (index in `ordered`) before
        // sorting by offset, so we can restore priority order afterward.
        struct Item { let id: ChunkID; let offset: UInt64; let size: Int; let priority: Int }
        var items = ordered.enumerated().map {
            Item(id: $1.id, offset: $1.offset, size: $1.size, priority: $0)
        }
        items.sort { $0.offset < $1.offset }

        struct Group { var members: [(id: ChunkID, priority: Int)]; var end: UInt64; var bytes: Int; var best: Int }
        var groups: [Group] = []
        for it in items {
            let gap = groups.last.map { it.offset > $0.end ? it.offset - $0.end : 0 }
            if var g = groups.last,
               g.members.count < maxNodes,
               g.bytes + it.size <= maxBytes,
               (gap ?? .max) <= gapBytes {
                g.members.append((it.id, it.priority))
                g.end = max(g.end, it.offset + UInt64(it.size))
                g.bytes += it.size
                g.best = min(g.best, it.priority)
                groups[groups.count - 1] = g
            } else {
                groups.append(Group(members: [(it.id, it.priority)],
                                    end: it.offset + UInt64(it.size),
                                    bytes: it.size,
                                    best: it.priority))
            }
        }

        return groups
            .sorted { $0.best < $1.best }
            .map { $0.members.sorted { $0.priority < $1.priority }.map(\.id) }
    }
}

// MARK: - Publish queue

/// Lock-protected output queue. The driver actor appends; consumers drain
/// via the synchronous `pollLatest`. Decouples actor isolation from the
/// render thread's non-async hot path.
final class UpdateQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var added: [ResidentChunk] = []
    private var removed: [ChunkID] = []
    private var addedBytes = 0

    /// Byte cost of queued-but-undrained `added` chunks. The driver reads
    /// this to stop scheduling decodes while the consumer isn't draining —
    /// otherwise the backlog grows without bound (a stalled consumer under
    /// memory pressure feeds back into more memory pressure).
    var pendingAddedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return addedBytes
    }

    func enqueue(added: [ResidentChunk], removed: [ChunkID]) {
        lock.lock(); defer { lock.unlock() }
        var removed = removed
        if !removed.isEmpty && !self.added.isEmpty {
            // An eviction cancels a queued-but-undrained add of the same
            // chunk: the consumer never saw the add, so drop the payload
            // and swallow the matching removal. Without this, camera
            // thrash accumulates full payloads for already-evicted chunks.
            let rm = Set(removed)
            var swallowed = Set<ChunkID>()
            self.added.removeAll { chunk in
                guard rm.contains(chunk.id) else { return false }
                swallowed.insert(chunk.id)
                addedBytes -= chunk.byteCost
                return true
            }
            if !swallowed.isEmpty { removed.removeAll { swallowed.contains($0) } }
        }
        self.added.append(contentsOf: added)
        for chunk in added { addedBytes += chunk.byteCost }
        self.removed.append(contentsOf: removed)
    }

    func drain() -> StreamingUpdate? {
        lock.lock(); defer { lock.unlock() }
        if added.isEmpty && removed.isEmpty { return nil }
        let u = StreamingUpdate(added: added, removed: removed)
        added.removeAll(keepingCapacity: true)
        removed.removeAll(keepingCapacity: true)
        addedBytes = 0
        return u
    }
}

// MARK: - Decode-stats box

/// Lock-protected backing store for ``StreamingDecodeStats``.
///
/// Mutated only from the driver actor (which serializes all transitions) and
/// read synchronously off the render/main thread via
/// ``CopcStreamingPointCloudSource/decodeStats()`` — the `NSLock` guards that
/// cross-thread read against a concurrent write, mirroring ``UpdateQueue``.
///
/// The instantaneous counters (`pending`, `active`) are driven by the exact
/// decode-lifecycle transitions and clamped at zero defensively; the
/// cumulative counters (`chunks`, `points`) only ever increase and survive
/// ``reset()`` (called on close).
final class DecodeStatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var active = 0
    private var chunks: UInt64 = 0
    private var points: UInt64 = 0

    /// `n` nodes were just scheduled for decode (enqueued, not yet decoding).
    func scheduled(_ n: Int) { lock.withLock { pending += n } }

    /// `n` still-pending nodes were cancelled before a worker picked them up.
    func cancelledPending(_ n: Int) { lock.withLock { pending = max(0, pending - n) } }

    /// A worker began decoding a node: one pending request becomes active.
    func decodeBegan() { lock.withLock { pending = max(0, pending - 1); active += 1 } }

    /// A worker finished a decode. Decrements the active count and, on
    /// success, bumps the cumulative chunk/point totals.
    func decodeEnded(points p: Int, success: Bool) {
        lock.withLock {
            active = max(0, active - 1)
            if success { chunks &+= 1; points &+= UInt64(max(0, p)) }
        }
    }

    /// Clear the instantaneous counters (on shutdown). Cumulative totals kept.
    func reset() { lock.withLock { pending = 0; active = 0 } }

    /// A consistent snapshot of all four counters.
    func snapshot() -> StreamingDecodeStats {
        lock.withLock {
            StreamingDecodeStats(
                pendingRequests: pending,
                inFlightDecodes: active,
                decodedChunks: chunks,
                decodedPoints: points
            )
        }
    }
}

// MARK: - Residency settle box

/// Sync, lock-guarded snapshot of "is the frame fully streamed", mirroring
/// ``DecodeStatsBox``. The driver actor writes it at the end of every tick;
/// ``CopcStreamingPointCloudSource/isResidencySettled`` reads it without an
/// actor hop so a render-thread pre-roll can pump until residency catches up.
///
/// ``markUnsettled()`` is called the instant a new view set is submitted, so a
/// consumer that submitted this frame never mistakes the *previous* frame's
/// settled state for its own before the driver has re-evaluated.
final class ResidencySettleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var budgetLimited = false
    private var wanted = 0
    private var resident = 0
    /// Pre-clamp residency *demand* in GPU slots: the total slot cost of the
    /// current view set's candidate nodes, computed each score pass BEFORE the
    /// slot budget clamps the wanted set. Published here (mirroring the settle
    /// snapshot) so a host budget governor can read it synchronously off the
    /// render/main thread. See ``CopcStreamingPointCloudSource/residencyDemandSlots``.
    private var demandSlots = 0

    /// Called on `submit(view/views:)` so the next `isSettled` read reflects the
    /// new target, not the stale one, until a tick re-publishes.
    func markUnsettled() { lock.withLock { settled = false } }

    /// Published by the driver at the end of each tick.
    func update(settled: Bool, budgetLimited: Bool, wanted: Int, resident: Int, demandSlots: Int) {
        lock.withLock {
            self.settled = settled
            self.budgetLimited = budgetLimited
            self.wanted = wanted
            self.resident = resident
            self.demandSlots = demandSlots
        }
    }

    var isSettled: Bool { lock.withLock { settled } }
    var isBudgetLimited: Bool { lock.withLock { budgetLimited } }
    var demand: Int { lock.withLock { demandSlots } }
    func snapshot() -> (settled: Bool, budgetLimited: Bool, wanted: Int, resident: Int, demand: Int) {
        lock.withLock { (settled, budgetLimited, wanted, resident, demandSlots) }
    }
}

// MARK: - Job queue

/// Lock-protected FIFO of pending decode jobs.
///
/// The driver actor's tick enqueues **clusters** (`[ChunkID]`) of
/// offset-adjacent nodes; persistent slot workers `await pop()` to drain
/// them one cluster at a time. A worker prefetches a whole cluster's
/// compressed blocks in one coalesced read, then decodes each member. When
/// the queue is empty, `pop()` suspends on a continuation and resumes when
/// the next `enqueue` lands or `close()` is called. Closing returns `nil`
/// from any waiting `pop` so workers can exit cleanly.
///
/// The queue is non-actor so the driver can enqueue without an extra
/// actor hop; concurrency control is a single `NSLock`.
final class JobQueue: @unchecked Sendable {
    /// A parked ``pop()`` caller. Identified so ``onCancel`` can find and remove
    /// exactly this waiter. The continuation is *claimed* (set to `nil` under
    /// ``lock``) by whichever of {enqueue-handoff, cancel, close} reaches it
    /// first; the loser sees `nil` and does nothing — this is how the
    /// resume-exactly-once invariant is upheld across the cancel race.
    private final class Waiter {
        let id: UInt64
        var continuation: CheckedContinuation<[ChunkID]?, Never>?
        init(id: UInt64, continuation: CheckedContinuation<[ChunkID]?, Never>) {
            self.id = id
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var pending: [[ChunkID]] = []
    private var waiters: [Waiter] = []
    private var closed = false
    private var nextWaiterID: UInt64 = 0

    func enqueue<S: Sequence>(_ clusters: S) where S.Element == [ChunkID] {
        var handoffs: [(CheckedContinuation<[ChunkID]?, Never>, [ChunkID])] = []
        lock.withLock {
            if closed { return }
            var leftover: [[ChunkID]] = []
            for cluster in clusters {
                if cluster.isEmpty { continue }
                // Waiters still in the array have NOT been cancelled (`onCancel`
                // removes a cancelled waiter under this same lock before enqueue
                // can pick it), so handing off here never targets a cancelled
                // worker at decision time. Claim the continuation so a cancel
                // racing *after* this point finds nothing to resume.
                if let w = waiters.first, let c = w.continuation {
                    waiters.removeFirst()
                    w.continuation = nil
                    handoffs.append((c, cluster))
                } else {
                    leftover.append(cluster)
                }
            }
            if !leftover.isEmpty { pending.append(contentsOf: leftover) }
        }
        for (c, cluster) in handoffs { c.resume(returning: cluster) }
    }

    func pop() async -> [ChunkID]? {
        let id = lock.withLock { () -> UInt64 in
            nextWaiterID &+= 1
            return nextWaiterID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<[ChunkID]?, Never>) in
                // Resolve immediately if closed, already-cancelled, or a cluster
                // is ready; otherwise park the continuation in `waiters`. The
                // `Task.isCancelled` check closes the race where `onCancel` fired
                // before this continuation was installed: it runs under the same
                // lock as `onCancel`'s removal, so the two are serialized and the
                // continuation is resumed exactly once. No await under the lock.
                enum Action { case resume([ChunkID]?), wait }
                let action: Action = lock.withLock {
                    if closed { return .resume(nil) }
                    if Task.isCancelled { return .resume(nil) }
                    if !pending.isEmpty { return .resume(pending.removeFirst()) }
                    waiters.append(Waiter(id: id, continuation: c))
                    return .wait
                }
                switch action {
                case .resume(let v): c.resume(returning: v)
                case .wait: break
                }
            }
        } onCancel: {
            // Cancelled while parked: claim and remove our own waiter, then
            // resume it with `nil` so the worker exits promptly. If enqueue/close
            // already claimed it (removed from `waiters`), we find nothing and do
            // nothing — resume-exactly-once holds.
            let cont: CheckedContinuation<[ChunkID]?, Never>? = lock.withLock {
                guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                let w = waiters.remove(at: idx)
                let c = w.continuation
                w.continuation = nil
                return c
            }
            cont?.resume(returning: nil)
        }
    }

    /// Return a cluster to the head of the queue. Used by a worker that popped a
    /// cluster but then observed its own cancellation (it raced an enqueue
    /// hand-off) — rather than decode on a slot the incoming pool is about to
    /// reuse, it hands the cluster back so no queued work is lost. Prepends to
    /// `pending` (never to a waiter): cancellation is always pool-wide, so any
    /// other current waiter is a cancelled sibling that would only bounce it
    /// back; the fresh pool drains `pending`. Dropped if the queue is closed
    /// (teardown).
    func requeue(_ cluster: [ChunkID]) {
        if cluster.isEmpty { return }
        lock.withLock {
            if closed { return }
            pending.insert(cluster, at: 0)
        }
    }

    /// Drop the given IDs from any pending clusters. Removing an ID shrinks
    /// its cluster; an emptied cluster disappears. Already-popped clusters
    /// (in-flight on a worker) are not affected.
    func remove(_ ids: Set<ChunkID>) {
        if ids.isEmpty { return }
        lock.withLock {
            for i in pending.indices {
                pending[i].removeAll { ids.contains($0) }
            }
            pending.removeAll { $0.isEmpty }
        }
    }

    func close() {
        let toResume: [CheckedContinuation<[ChunkID]?, Never>] = lock.withLock {
            closed = true
            let conts = waiters.compactMap { w -> CheckedContinuation<[ChunkID]?, Never>? in
                let c = w.continuation
                w.continuation = nil
                return c
            }
            waiters.removeAll()
            pending.removeAll()
            return conts
        }
        for w in toResume { w.resume(returning: nil) }
    }
}

// MARK: - COPC source

/// Concrete COPC-backed implementation of ``StreamingPointCloudSource``.
///
/// On ``open(_:options:)`` the file's octree hierarchy is parsed into an
/// in-memory snapshot and a pool of
/// ``StreamingOptions/decodeConcurrency`` `FileReader` instances is
/// opened against the file. copc-lib's `FileReader` owns an `fstream`
/// that isn't thread-safe, so the driver assigns each concurrent decode
/// a distinct reader slot — this is how the actor delegates parallel
/// work without contending on a single reader.
///
/// A detached driver `Task` wakes at
/// ``StreamingOptions/driverTickInterval``, scores nodes against the
/// latest camera + budget, dispatches up to
/// ``StreamingOptions/maxInFlightLoads`` loads per tick (running them in
/// batches of ``StreamingOptions/decodeConcurrency`` in parallel), and
/// publishes residency deltas to a lock-protected queue that
/// ``pollLatest()`` drains.
///
/// Aggregate decode parallelism across all open sources is additionally
/// bounded by the process-wide ``StreamingDecodeGate``: a worker acquires a
/// shared slot before each LAZ decode, so N sources never run more than the
/// gate's limit of concurrent decodes in total.
///
/// - Important: Call ``close()`` when finished to release the file handle
///   and stop the driver Task.
public final class CopcStreamingPointCloudSource: StreamingPointCloudSource, @unchecked Sendable {
    /// File-level metadata. Stable after ``open(_:options:)`` returns.
    public let info: StreamingSourceInfo

    private let driver: StreamingDriver
    private let queue: UpdateQueue
    private let jobs: JobQueue
    /// Lock-protected decode-pipeline counters, written by the driver/workers
    /// and read synchronously by ``decodeStats()``.
    private let statsBox: DecodeStatsBox
    /// Lock-protected residency-settle snapshot, written by the driver each tick
    /// and read synchronously by ``isResidencySettled`` / ``residencyBudgetLimited``.
    private let settleBox: ResidencySettleBox
    private let handleBox: SendableCopcReader
    private let originShift: SIMD3<Double>
    private let workerCount: Int
    /// Resolved extra-dimension extraction descriptors (parallel to
    /// ``extraNames``), passed to `read_node` on every decode. Empty for the
    /// default position+color-only path.
    private let extraDescs: [CopcExtractDesc]
    /// Names of the requested extra dimensions, in the same order as
    /// ``extraDescs`` — used to key each chunk's `extraScalars`.
    private let extraNames: [String]
    /// File-wide RGB rescale shift (8 = 16-bit→8-bit, 0 = already 8-bit), decided
    /// once at open from the root node so dark nodes aren't mis-scaled per-node.
    /// `nil` when the file has no RGB.
    private let rgbShiftBits: UInt32?
    private var driverTask: Task<Void, Never>?
    /// Serializes decode-worker-pool lifecycle (initial spawn, cancel-and-
    /// respawn on a QoS switch, teardown) and guards the mutable handles below.
    /// The class is `@unchecked Sendable`, so — as with ``JobQueue`` /
    /// ``DecodeStatsBox`` — mutable cross-thread state needs an explicit lock;
    /// ``setDecodeWorkerPriority(_:)`` can race ``close()`` otherwise.
    private let workerLock = NSLock()
    /// Live decode-worker task handles. Guarded by ``workerLock``.
    private var workerTasks: [Task<Void, Never>] = []
    /// Current *applied* base QoS of the live decode workers. Guarded by
    /// ``workerLock``.
    private var decodeWorkerPriority: TaskPriority = .utility
    /// Latest *requested* QoS awaiting the switch coordinator, or `nil` when no
    /// switch is outstanding. Latest-wins: a request that arrives mid-switch just
    /// overwrites this and the running coordinator picks it up on its next lap.
    /// Guarded by ``workerLock``.
    private var pendingWorkerPriority: TaskPriority?
    /// `true` while a switch coordinator Task is draining-and-respawning the
    /// pool. Ensures only one coordinator runs at a time (no overlapping pools).
    /// Guarded by ``workerLock``.
    private var switchInProgress = false
    /// `true` once ``startDriver()`` has spawned the pool; a QoS switch before
    /// start is a no-op. Guarded by ``workerLock``.
    private var driverStarted = false
    /// `true` once ``close()`` has begun teardown; a QoS switch after close is a
    /// no-op and the coordinator will not respawn. Guarded by ``workerLock``.
    private var isClosed = false

    private init(
        info: StreamingSourceInfo,
        driver: StreamingDriver,
        queue: UpdateQueue,
        jobs: JobQueue,
        statsBox: DecodeStatsBox,
        settleBox: ResidencySettleBox,
        handle: SendableCopcReader,
        originShift: SIMD3<Double>,
        workerCount: Int,
        extraDescs: [CopcExtractDesc],
        extraNames: [String],
        rgbShiftBits: UInt32?
    ) {
        self.info = info
        self.driver = driver
        self.queue = queue
        self.jobs = jobs
        self.statsBox = statsBox
        self.settleBox = settleBox
        self.handleBox = handle
        self.originShift = originShift
        self.workerCount = workerCount
        self.extraDescs = extraDescs
        self.extraNames = extraNames
        self.rgbShiftBits = rgbShiftBits
    }

    /// Open a COPC file and parse its octree hierarchy.
    ///
    /// Does not load any point data. If ``StreamingOptions/prefetchRoot``
    /// is `true`, the first ``pollLatest()`` will block until the root +
    /// depth-1 nodes are ready.
    ///
    /// - Parameters:
    ///   - url: Local file URL to a COPC LAZ file.
    ///   - options: Streaming configuration.
    /// - Returns: A live source with its driver Task already started.
    /// - Throws: ``StreamingSourceError/openFailed(_:)`` if the file isn't
    ///   a COPC LAZ; ``StreamingSourceError/malformedHierarchy(_:)`` if the
    ///   COPC hierarchy can't be parsed.
    public static func open(
        _ url: URL,
        options: StreamingOptions = .init()
    ) async throws -> CopcStreamingPointCloudSource {
        let poolSize = Int32(max(1, options.decodeConcurrency))
        guard let reader = CopcReader.open(std.string(url.path), poolSize) else {
            throw StreamingSourceError.openFailed(url)
        }
        return makeSource(reader: reader, options: options, isRemote: false)
    }

    /// Open a COPC file streamed over HTTP and parse its octree hierarchy.
    ///
    /// Identical to ``open(_:options:)`` except the point data is pulled from a
    /// remote `http(s)://` URL via HTTP range requests — only the octree nodes
    /// the renderer asks for are fetched, with no full download. Works on macOS
    /// and iOS (the path talks to copc-lib directly, bypassing GDAL/curl).
    ///
    /// Opening issues a few synchronous network requests (to read the LAS
    /// header + COPC hierarchy), so this runs off the calling actor.
    ///
    /// - Parameters:
    ///   - url: An `http://` or `https://` URL to a COPC LAZ file. Plain
    ///     `http://` requires an App Transport Security exception in the host
    ///     app's Info.plist.
    ///   - options: Streaming configuration.
    /// - Returns: A live source with its driver Task already started.
    /// - Throws: ``StreamingSourceError/openFailed(_:)`` if the URL can't be
    ///   opened as a COPC LAZ (bad URL, network error, non-COPC payload, or a
    ///   server that doesn't support range requests).
    public static func open(
        remoteURL url: URL,
        options: StreamingOptions = .init()
    ) async throws -> CopcStreamingPointCloudSource {
        let poolSize = Int32(max(1, options.decodeConcurrency))
        // open_http issues blocking HEAD/GETs while reading the header +
        // hierarchy (same as the local path's synchronous file open).
        guard let reader = CopcReader.open_http(std.string(url.absoluteString), poolSize) else {
            throw StreamingSourceError.openFailed(url)
        }
        return makeSource(reader: reader, options: options, isRemote: true)
    }

    /// Build a live streaming source from an already-opened COPC reader.
    /// Shared by ``open(_:options:)`` and ``open(remoteURL:options:)`` — the
    /// only difference between them is how the reader is constructed and, for
    /// prefetch, the coalescing gap threshold (`isRemote`).
    private static func makeSource(
        reader: CopcReader,
        options: StreamingOptions,
        isRemote: Bool
    ) -> CopcStreamingPointCloudSource {
        let bMin = reader.bounds_min()
        let bMax = reader.bounds_max()
        let originShift = SIMD3<Double>(
            (bMin[0] + bMax[0]) * 0.5,
            (bMin[1] + bMax[1]) * 0.5,
            (bMin[2] + bMax[2]) * 0.5
        )

        let nodeCount = reader.node_count()
        let totalPoints = reader.total_points()

        var nodes: [NodeMeta] = []
        nodes.reserveCapacity(Int(nodeCount))
        var maxDepth = 0
        // Per-depth node/slot histogram, published on `StreamingSourceInfo` so a
        // host can size a pool for a depth-limited pin from that prefix's real
        // cost. Grown on demand — the hierarchy isn't walked in depth order.
        let pointsPerBatch = ChunkPacker.defaultPointsPerBatch
        var nodesAtDepth: [Int] = []
        var slotsAtDepth: [Int] = []
        for i in 0..<nodeCount {
            var n = CopcNodeInfo()
            if !reader.node_at(i, &n) { continue }
            let mn = SIMD3<Float>(
                Float(n.min_x - originShift.x),
                Float(n.min_y - originShift.y),
                Float(n.min_z - originShift.z)
            )
            let mx = SIMD3<Float>(
                Float(n.max_x - originShift.x),
                Float(n.max_y - originShift.y),
                Float(n.max_z - originShift.z)
            )
            let center = (mn + mx) * 0.5
            let extent = max(mx.x - mn.x, max(mx.y - mn.y, mx.z - mn.z))
            nodes.append(NodeMeta(
                id: ChunkID(depth: Int(n.depth), x: Int(n.x), y: Int(n.y), z: Int(n.z)),
                pointCount: Int(n.point_count),
                minXYZ: mn, maxXYZ: mx,
                center: center, extent: extent,
                offset: n.offset, byteSize: Int(n.byte_size)
            ))
            let depth = Int(n.depth)
            maxDepth = max(maxDepth, depth)
            if nodesAtDepth.count <= depth {
                let pad = depth + 1 - nodesAtDepth.count
                nodesAtDepth.append(contentsOf: repeatElement(0, count: pad))
                slotsAtDepth.append(contentsOf: repeatElement(0, count: pad))
            }
            nodesAtDepth[depth] += 1
            // A node occupies whole slots — the same `ceil` the driver charges
            // admission in, so an empty node (0 points) costs nothing.
            slotsAtDepth[depth] += (Int(n.point_count) + pointsPerBatch - 1) / pointsPerBatch
        }

        let bounds = Bounds(
            min: SIMD3<Float>(Float(bMin[0]), Float(bMin[1]), Float(bMin[2])),
            max: SIMD3<Float>(Float(bMax[0]), Float(bMax[1]), Float(bMax[2]))
        )

        // Resolve the streamable dimension schema: standard LAS dims present
        // for this point format + custom Extra Bytes fields. Then build the
        // requested extraction descriptors (opt-in — empty unless requested).
        let standard = StandardLasDim.present(forPointFormat: reader.point_format_id())
        var ebNames: [String] = []
        var ebDescByName: [String: CopcExtractDesc] = [:]
        for i in 0..<reader.eb_field_count() {
            var f = CopcEbFieldInfo()
            guard reader.eb_field_at(i, &f) else { continue }
            let name = withUnsafeBytes(of: f.name) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard f.size > 0, !name.isEmpty else { continue }  // skip undocumented/array EB
            var d = CopcExtractDesc()
            d.kind = 1
            d.byte_offset = f.byte_offset
            d.data_type = f.data_type
            d.size = f.size
            d.scale = f.scale
            d.offset_value = f.offset_value
            ebNames.append(name)
            ebDescByName[name] = d
        }
        let availableDimensions = standard.map(\.name) + ebNames

        let requestedNames: [String]
        if options.requestAllAvailableDimensions {
            requestedNames = availableDimensions
        } else {
            let avail = Set(availableDimensions)
            requestedNames = options.extraDimensions.filter { avail.contains($0) }
        }
        let standardByName = Dictionary(uniqueKeysWithValues: standard.map { ($0.name, $0) })
        var extraDescs: [CopcExtractDesc] = []
        var extraNames: [String] = []
        for name in requestedNames {
            if let std = standardByName[name] {
                var d = CopcExtractDesc()
                d.kind = 0
                d.code = std.rawValue
                extraDescs.append(d)
                extraNames.append(name)
            } else if let d = ebDescByName[name] {
                extraDescs.append(d)
                extraNames.append(name)
            }
        }

        let info = StreamingSourceInfo(
            bounds: bounds,
            originShift: originShift,
            totalPoints: UInt64(totalPoints),
            maxDepth: maxDepth,
            pointsPerBatch: pointsPerBatch,
            bytesPerPoint: 17,
            availableDimensions: availableDimensions,
            extraBytesPerPoint: 4 * extraNames.count,
            nodesAtDepth: nodesAtDepth,
            slotsAtDepth: slotsAtDepth
        )

        let queue = UpdateQueue()
        let jobs = JobQueue()
        let statsBox = DecodeStatsBox()
        let settleBox = ResidencySettleBox()
        let handleBox = SendableCopcReader(reader: reader)
        let driver = StreamingDriver(
            handle: handleBox,
            nodes: nodes,
            originShift: originShift,
            options: options,
            queue: queue,
            jobs: jobs,
            statsBox: statsBox,
            settleBox: settleBox,
            budgetBytesPerPoint: 17 + 4 * extraNames.count,
            pointsPerBatch: info.pointsPerBatch,
            isRemote: isRemote
        )

        // Decide the RGB rescale ONCE for the whole file (see ``rgbShiftBits``).
        let rgbShift = computeGlobalRgbShift(reader: reader)

        let workerCount = max(1, options.decodeConcurrency)

        // Size the process-wide decode gate so this source's own workers are
        // never throttled below its configured `decodeConcurrency`. The gate's
        // default floor (`activeProcessorCount - 2`) otherwise silently caps a
        // high-concurrency source (e.g. 18 workers pegged at 16). An explicit
        // `decodeGateLimit` sets a hard aggregate ceiling instead. See
        // ``StreamingOptions/decodeGateLimit``.
        if let explicit = options.decodeGateLimit {
            StreamingDecodeGate.shared.setLimit(explicit)
        } else {
            StreamingDecodeGate.shared.ensureLimitAtLeast(workerCount)
        }

        let source = CopcStreamingPointCloudSource(
            info: info,
            driver: driver,
            queue: queue,
            jobs: jobs,
            statsBox: statsBox,
            settleBox: settleBox,
            handle: handleBox,
            originShift: originShift,
            workerCount: workerCount,
            extraDescs: extraDescs,
            extraNames: extraNames,
            rgbShiftBits: rgbShift
        )
        source.startDriver()
        return source
    }

    /// Decide the 8-bit-vs-16-bit RGB rescale once, globally, from the **root**
    /// node. The root is the coarsest LOD — it samples the whole cloud, so it
    /// contains the bright points needed to detect a true 16-bit file (max >
    /// 255 → shift 8). Deciding this per node mis-classifies uniformly-dark
    /// nodes as 8-bit and renders them oversaturated. Returns `nil` when the
    /// file has no RGB (callers fall back to the per-node heuristic / white).
    private static func computeGlobalRgbShift(reader: CopcReader) -> UInt32? {
        let chunk = reader.read_node(0, 0, 0, 0, 0, nil, 0)
        let count = Int(chunk.point_count())
        guard count > 0, chunk.has_rgb(), let rgb = chunk.__rgb_dataUnsafe() else { return nil }
        var maxVal: UInt16 = 0
        let total = count * 3
        var i = 0
        while i < total {
            if rgb[i] > maxVal { maxVal = rgb[i] }
            i += 1
        }
        return maxVal > 255 ? 8 : 0
    }

    private func startDriver() {
        let driver = self.driver
        let tickInterval = driver.tickInterval
        // Idle backoff: a static camera with a fully-drained pipeline
        // doesn't need a wakeup every `tickInterval` (WABF configures
        // 16ms, i.e. 60Hz). Sleep longer after a tick that did no
        // meaningful work; `submit(view:)` is latest-wins, so a camera
        // move mid-sleep is still picked up on the next wake — worst-case
        // reaction time only grows to `idleInterval` when the system was
        // genuinely idle.
        let idleInterval = max(tickInterval, .milliseconds(100))
        // Driver tick task keeps its own `.utility` QoS — only the decode
        // workers are switched by ``setDecodeWorkerPriority(_:)``.
        let driverTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let didWork = await driver.runOneTick()
                try? await Task.sleep(for: didWork ? tickInterval : idleInterval)
            }
        }

        let workers = spawnDecodeWorkers(priority: .utility)
        workerLock.withLock {
            self.driverTask = driverTask
            self.workerTasks = workers
            self.decodeWorkerPriority = .utility
            self.driverStarted = true
        }
    }

    /// Spawn `workerCount` detached LAZ decode workers at `priority` and return
    /// their handles. Shared by ``startDriver()`` (initial pool at
    /// ``TaskPriority/utility``) and ``setDecodeWorkerPriority(_:)`` (respawn at
    /// a new QoS). Pure factory: it only creates tasks — the caller stores the
    /// handles under ``workerLock``. Each worker owns a reusable pack scratch
    /// and drains ``jobs`` until cancelled or the queue closes.
    private func spawnDecodeWorkers(priority: TaskPriority) -> [Task<Void, Never>] {
        let jobs = self.jobs
        let handleBox = self.handleBox
        let originShift = self.originShift
        let extraDescs = self.extraDescs
        let extraNames = self.extraNames
        let rgbShiftBits = self.rgbShiftBits
        let driver = self.driver
        return (0..<workerCount).map { slot in
            Task.detached(priority: priority) {
                let slotIndex = Int32(slot)
                // One reusable pack scratch per worker: the ~2.5 MB of per-chunk
                // temporaries (morton/radix/LOD-table/bucket buffers) are
                // allocated once here and grown as needed, instead of malloc'd +
                // zero-filled + freed on every chunk across N workers. See
                // ``ChunkPacker/Workspace``.
                let packWorkspace = ChunkPacker.Workspace()
                while !Task.isCancelled {
                    guard let cluster = await jobs.pop() else { break }
                    // Handed a cluster while (or just after) being cancelled — a
                    // rare race with a concurrent `enqueue`. The switch
                    // coordinator is about to reuse this worker's `slotIndex` for
                    // a fresh-pool worker, and this slot maps to per-slot C++
                    // reader state that is NOT safe to touch from two tasks at
                    // once. So do not prefetch/decode: hand the cluster back
                    // (never dropped) and exit. `close()` cancels via
                    // `jobs.close()` → `pop()` returns `nil` above, so this path
                    // is only ever a QoS-switch cancellation.
                    if Task.isCancelled {
                        jobs.requeue(cluster)
                        break
                    }
                    if cluster.isEmpty { continue }
                    // Coalesced prefetch of the whole cluster's compressed
                    // blocks in one (or a few) span reads — pure I/O (seek+read
                    // / ranged GET), so it runs OUTSIDE the decode gate. Skip a
                    // lone node: read_node's own read is already one seek, so
                    // prefetching it would only add a redundant copy.
                    if cluster.count > 1 {
                        let keys = cluster.map { id -> CopcNodeKey in
                            var k = CopcNodeKey()
                            k.depth = Int32(id.depth)
                            k.x = Int32(id.x)
                            k.y = Int32(id.y)
                            k.z = Int32(id.z)
                            return k
                        }
                        keys.withUnsafeBufferPointer { buf in
                            handleBox.reader.prefetch_nodes(buf.baseAddress, Int32(buf.count), slotIndex)
                        }
                    }
                    for id in cluster {
                        // Bound aggregate decode parallelism across all open
                        // sources via the process-wide gate. Acquire per node
                        // (not per cluster) and release the moment the decode is
                        // done — completeLoad doesn't need the slot.
                        // COPC depth 0 (root) and 1 are the coarse-coverage nodes
                        // that put a newly-visible cloud's first points on screen;
                        // take the gate's priority lane so they don't queue behind
                        // far-cloud leaf decodes.
                        await StreamingDecodeGate.shared.acquire(priority: id.depth <= 1)
                        // Past the gate → genuinely decoding now. Moves this
                        // node from "pending" to "in-flight" in the decode
                        // telemetry (``decodeStats()``); the matching
                        // decrement happens in `completeLoad`.
                        await driver.beginDecode(id: id)
                        let chunk = StreamingDriver.decodeAndPack(
                            reader: handleBox.reader,
                            slot: slotIndex,
                            id: id,
                            originShift: originShift,
                            extraDescs: extraDescs,
                            extraNames: extraNames,
                            rgbShiftBits: rgbShiftBits,
                            workspace: packWorkspace
                        )
                        StreamingDecodeGate.shared.release()
                        await driver.completeLoad(id: id, chunk: chunk)
                    }
                }
            }
        }
    }

    /// Live-switch the decode worker pool's QoS (see the protocol doc on
    /// ``StreamingPointCloudSource/setDecodeWorkerPriority(_:)`` for the
    /// export-gating rationale). No-op before ``startDriver()``, after
    /// ``close()``, or when the requested priority is already applied and no
    /// switch is pending.
    ///
    /// **The swap is a full drain barrier: the old pool and the new pool never
    /// run concurrently.** This is mandatory, not an optimisation — each worker's
    /// `slotIndex` maps to a distinct per-slot C++ COPC `Reader` (an `fstream`
    /// that is not safe to touch from two tasks at once). A fresh pool reuses
    /// slots `0..<workerCount`, so it may not start until every old worker has
    /// stopped touching its reader. The actual work runs on a detached
    /// coordinator Task (``runDecodeWorkerSwitch()``); this method only records
    /// the request and starts the coordinator if one isn't already running.
    ///
    /// The swap deliberately does **not** touch ``jobs``: all queued clusters
    /// live in ``JobQueue``'s `pending` array (its own lock), so a pool swap
    /// can't lose them — the new pool drains the exact same queue, plus anything
    /// an old worker handed back via ``JobQueue/requeue(_:)``.
    public func setDecodeWorkerPriority(_ priority: TaskPriority) {
        let startCoordinator: Bool = workerLock.withLock {
            guard driverStarted, !isClosed else { return false }
            // Record the latest wish (latest-wins). A coordinator already draining
            // will pick this up on its next lap, so never start a second one.
            if switchInProgress {
                pendingWorkerPriority = priority
                return false
            }
            // Idle: nothing to do if we're already at the requested QoS.
            guard priority != decodeWorkerPriority else { return false }
            pendingWorkerPriority = priority
            switchInProgress = true
            return true
        }
        guard startCoordinator else { return }
        Task.detached { [self] in await runDecodeWorkerSwitch() }
    }

    /// Drain-and-respawn coordinator for ``setDecodeWorkerPriority(_:)``. Exactly
    /// one instance runs at a time (gated by ``switchInProgress``). Each lap:
    /// cancels the current pool, `await`s **every** old worker's completion (the
    /// barrier — `pop()` returns `nil` on cancel, and a worker that raced a
    /// hand-off requeues and exits, so every task terminates), then spawns the
    /// new pool. Re-checks ``pendingWorkerPriority`` after each lap so a request
    /// that arrived mid-drain is honoured (latest-wins). Never spawns once
    /// ``isClosed`` is observed — ``close()`` owns teardown of whatever pool
    /// exists.
    private func runDecodeWorkerSwitch() async {
        while true {
            let step: (old: [Task<Void, Never>], target: TaskPriority)? = workerLock.withLock {
                // Closed mid-switch: stop. `close()` drains the live pool.
                guard !isClosed else {
                    pendingWorkerPriority = nil
                    switchInProgress = false
                    return nil
                }
                // No outstanding request, or it collapsed to the applied value
                // (e.g. utility→userInitiated→utility while draining): finish.
                guard let target = pendingWorkerPriority, target != decodeWorkerPriority else {
                    pendingWorkerPriority = nil
                    switchInProgress = false
                    return nil
                }
                // Consume the request and snapshot the pool to drain this lap.
                pendingWorkerPriority = nil
                return (workerTasks, target)
            }
            guard let step else { return }

            // Barrier: cancel the old pool and wait for ALL of it to finish
            // before any new worker (which reuses the same slot indices, hence
            // the same C++ readers) can start.
            for w in step.old { w.cancel() }
            for w in step.old { await w.value }

            let finished: Bool = workerLock.withLock {
                // Closed while draining: do not respawn; close() handles the rest.
                guard !isClosed else {
                    pendingWorkerPriority = nil
                    switchInProgress = false
                    return true
                }
                workerTasks = spawnDecodeWorkers(priority: step.target)
                decodeWorkerPriority = step.target
                // Another request arrived mid-drain → loop; else we're done.
                if let next = pendingWorkerPriority, next != decodeWorkerPriority {
                    return false
                }
                pendingWorkerPriority = nil
                switchInProgress = false
                return true
            }
            if finished { return }
        }
    }

    public func submit(view: StreamingCameraView) {
        settleBox.markUnsettled()
        Task { await driver.setViews([view]) }
    }

    public func submit(views: [StreamingCameraView]) {
        guard !views.isEmpty else { return }
        settleBox.markUnsettled()
        Task { await driver.setViews(views) }
    }

    public var isResidencySettled: Bool { settleBox.isSettled }
    public var residencyBudgetLimited: Bool { settleBox.isBudgetLimited }
    public var residencyDemandSlots: Int { settleBox.demand }

    public func setBudget(_ bytes: Int) {
        // A budget change can grow the wanted set, so treat it like a resubmit:
        // don't let a pre-roll read the pre-change "settled" as done.
        settleBox.markUnsettled()
        // Convert the byte budget to whole GPU slots. Conservative: a slot
        // holds `pointsPerBatch` points at `bytesPerPoint (+ extraBytesPerPoint)`
        // bytes each, so `bytes / bytesPerSlot` is the number of *full* slots the
        // byte figure buys — partial-batch waste is now charged, where byte
        // accounting used to ignore it. Floored at 1 so a non-zero budget never
        // rounds down to "nothing resident".
        let bytesPerSlot = info.pointsPerBatch * (info.bytesPerPoint + info.extraBytesPerPoint)
        let slots = max(1, bytes / bytesPerSlot)
        Task { await driver.setBudget(slots: slots) }
    }

    public func setBudget(slots: Int) {
        // Resubmit-like, exactly as `setBudget(_:)`: a budget change can grow the
        // wanted set, so drop the stale "settled" flag until the next tick.
        settleBox.markUnsettled()
        Task { await driver.setBudget(slots: slots) }
    }

    public func setTargetChunkScreenSize(_ pixels: Float) {
        Task { await driver.setTargetScreenSize(pixels) }
    }

    public func setResidencyPolicy(_ policy: ResidencyPolicy) {
        // A policy change can grow the wanted set (e.g. distanceOnly admits
        // off-frustum chunks), so treat it like a resubmit for pre-roll loops.
        settleBox.markUnsettled()
        Task { await driver.setResidencyPolicy(policy) }
    }

    public func setEnforceHierarchyResidency(_ enabled: Bool) {
        settleBox.markUnsettled()
        Task { await driver.setEnforceHierarchyResidency(enabled) }
    }

    public func decodeStats() -> StreamingDecodeStats {
        statsBox.snapshot()
    }

    public func pollLatest() -> StreamingUpdate? {
        queue.drain()
    }

    public func nextUpdate() async -> StreamingUpdate? {
        queue.drain()
    }

    public func cancel(_ chunkIDs: [ChunkID]) {
        Task { await driver.cancel(chunkIDs) }
    }

    public func close() {
        // Snapshot handles + latch `isClosed` under the lock so a concurrent
        // `setDecodeWorkerPriority(_:)` either wins (its fresh pool is the one we
        // then tear down) or no-ops — never leaves an un-awaited pool behind.
        let (driverTask, workers): (Task<Void, Never>?, [Task<Void, Never>]) = workerLock.withLock {
            isClosed = true
            return (self.driverTask, self.workerTasks)
        }
        driverTask?.cancel()
        let jobs = self.jobs
        let driver = self.driver
        // Order: stop accepting new tick work, close the job queue (which
        // wakes any idle workers with `nil`), wait for in-flight workers
        // to finish their current chunk, then close the COPC handle.
        // Skipping the worker drain would race the C-side `fstream`
        // close against an ongoing decode.
        Task.detached {
            jobs.close()
            for w in workers { await w.value }
            await driver.shutdown()
        }
    }

    /// Test-only diagnostic snapshot of the driver's last tick. Stable
    /// shape across releases is not guaranteed — this is for benches,
    /// tests, and ad-hoc consumer-side logging only.
    public func _debugSnapshot() async -> StreamingDebugSnapshot {
        await driver.snapshot()
    }
}

// MARK: - Debug snapshot

/// Diagnostic snapshot returned by
/// ``CopcStreamingPointCloudSource/_debugSnapshot()``. Field shape is
/// **not** part of the stable public API; it's for benches, tests, and
/// ad-hoc consumer logging. Counts reflect the last completed driver
/// tick, except for the depth buckets which are sampled live from the
/// current `resident` and `cachedWanted` sets.
public struct StreamingDebugSnapshot: Sendable {
    /// Nodes scored on the most recent miss tick (post-frustum-cull
    /// under ``ResidencyPolicy/frustumFirstThenHalo``; all nodes under
    /// ``ResidencyPolicy/distanceOnly`` and the whole-file shortcut).
    public let candidates: Int
    /// Size of the wanted set computed on the most recent miss tick.
    public let wanted: Int
    /// Number of chunks currently resident on the driver.
    public let resident: Int
    /// Number of decode jobs that have been enqueued and not yet
    /// completed.
    public let inFlight: Int
    /// Nodes that passed the frustum-intersection test on the most
    /// recent miss tick. Only populated under
    /// ``ResidencyPolicy/frustumFirstThenHalo``; `0` under
    /// ``ResidencyPolicy/distanceOnly`` and the whole-file shortcut.
    public let frustumVisible: Int
    /// Total octree node count for the open file.
    public let totalNodes: Int
    /// Cumulative wanted-set cache hits since the source was opened.
    public let cacheHits: Int
    /// Cumulative wanted-set cache misses since the source was opened.
    public let cacheMisses: Int
    /// Resident chunk count bucketed by COPC depth, indexed by depth
    /// (`residentByDepth[0]` = root level). Length = maxDepth + 1.
    /// Useful for diagnosing LOD-selection bugs: a heavy leaf-depth
    /// bucket with empty coarse buckets indicates the wanted-set
    /// scorer is favouring close-camera detail and starving coverage.
    public let residentByDepth: [Int]
    /// Wanted chunk count bucketed by COPC depth. Same indexing as
    /// ``residentByDepth``.
    public let wantedByDepth: [Int]

    /// Create a debug snapshot. Exposed so a mock source can synthesize one;
    /// the shape is not part of the stable contract (see the type doc).
    public init(
        candidates: Int,
        wanted: Int,
        resident: Int,
        inFlight: Int,
        frustumVisible: Int,
        totalNodes: Int,
        cacheHits: Int,
        cacheMisses: Int,
        residentByDepth: [Int],
        wantedByDepth: [Int]
    ) {
        self.candidates = candidates
        self.wanted = wanted
        self.resident = resident
        self.inFlight = inFlight
        self.frustumVisible = frustumVisible
        self.totalNodes = totalNodes
        self.cacheHits = cacheHits
        self.cacheMisses = cacheMisses
        self.residentByDepth = residentByDepth
        self.wantedByDepth = wantedByDepth
    }
}

// MARK: - Driver actor

/// `@unchecked Sendable` wrapper for the imported COPC `Reader` reference
/// so it can be captured by concurrent decode tasks. Safe because:
///   1. The reader is read-only after open (hierarchy/header are
///      immutable).
///   2. Each concurrent caller targets a distinct `slot` in the reader
///      pool, so per-reader `fstream` state is never shared.
struct SendableCopcReader: @unchecked Sendable {
    let reader: CopcReader
}

actor StreamingDriver {
    private let handleBox: SendableCopcReader
    private var reader: CopcReader { handleBox.reader }
    private let nodes: [NodeMeta]
    private let nodeIndexByID: [ChunkID: Int]
    private let allNodeIDs: Set<ChunkID>
    /// Total slot cost of every node in the file (Σ ``slotCost(_:)``). When
    /// this fits the slot budget the whole-file shortcut engages. Slot- (not
    /// byte-) denominated so it compares apples-to-apples with the GPU slot
    /// pool the wanted set must physically fit.
    private let totalNodeSlots: Int
    /// Renderer batch granularity (points per fixed-size GPU slot). A node
    /// costs `ceil(pointCount / pointsPerBatch)` whole slots — a partial final
    /// batch still burns a full slot — so making residency admission
    /// slot-denominated guarantees "wanted set fits the pool" by construction.
    /// See ``slotCost(_:)``.
    private let pointsPerBatch: Int
    /// Estimated bytes per point: 17 (positions + colors + levels) plus 4 per
    /// requested extra dimension. No longer part of residency admission (that
    /// is slot-denominated now); retained only to convert the slot budget back
    /// to an approximate host-memory figure for the publish-queue backlog cap
    /// in ``runOneTick()``.
    private let budgetBytesPerPoint: Int
    private let maxNodeDepth: Int
    private let originShift: SIMD3<Double>
    /// `var` (not `let`) so the two cheap-to-retune scoring inputs
    /// (``StreamingOptions/residencyPolicy`` and
    /// ``StreamingOptions/enforceHierarchyResidency``) can be swapped live via
    /// ``setResidencyPolicy(_:)`` / ``setEnforceHierarchyResidency(_:)``. The
    /// scoring pass reads `options.residencyPolicy` / `.enforceHierarchyResidency`
    /// each tick, so a mutation takes effect on the next re-score. All other
    /// fields are open-time-only and never mutated here.
    private var options: StreamingOptions
    private let queue: UpdateQueue
    private let jobs: JobQueue
    /// Decode-pipeline telemetry shared with the owning source (read via
    /// ``CopcStreamingPointCloudSource/decodeStats()``). Written only from
    /// this actor's serialized transitions.
    private let statsBox: DecodeStatsBox
    /// Residency-settle snapshot shared with the owning source (read via
    /// ``CopcStreamingPointCloudSource/isResidencySettled``). Published at the
    /// end of every ``runOneTick()``.
    private let settleBox: ResidencySettleBox
    /// `true` when the source is HTTP-backed. Selects the prefetch coalescing
    /// gap threshold (an HTTP round-trip justifies a wider gap than a local
    /// seek). See ``NodePrefetch/gapBytes(isRemote:)``.
    private let isRemote: Bool
    let tickInterval: Duration

    /// Nodes pinned permanently resident (`depth <= alwaysResidentDepth`),
    /// empty when ``StreamingOptions/alwaysResidentDepth`` is `nil`/negative.
    /// Always closed under parent (a depth prefix of a connected COPC tree),
    /// so it composes cleanly with the hierarchy-residency invariant.
    private let pinnedIDs: Set<ChunkID>
    /// Total slot cost of ``pinnedIDs`` (charged before scored residency).
    private let pinnedSlots: Int
    /// Pinned IDs sorted coarse-first (depth ascending), used to seed the
    /// wanted-set load order so coarse coverage is scheduled before detail.
    private let pinnedOrdered: [ChunkID]

    /// Live, runtime-adjustable target on-screen chunk size for the scorer.
    /// Seeded from ``StreamingOptions/targetChunkScreenSize`` and updated by
    /// ``setTargetScreenSize(_:)``. Always clamped `>= 1`.
    private var currentTargetScreenSize: Float

    /// Nodes a worker has started decoding but not yet reported complete.
    /// Drives the pending-vs-in-flight split in ``StreamingDecodeStats`` and
    /// lets ``cancel(_:)`` account only the still-pending (not-yet-decoding)
    /// cancellations against ``DecodeStatsBox/pending``.
    private var decoding: Set<ChunkID> = []

    /// Current target view set (union). A single-camera frame is `[view]`;
    /// multi-projection / look-ahead frames carry several. Empty until the first
    /// submit.
    private var latestViews: [StreamingCameraView] = []
    /// Slot budget: the maximum number of fixed-size GPU slots the resident
    /// wanted set may occupy. `.max` = unbounded (whole-file mode). Set via
    /// ``setBudget(slots:)``.
    private var budgetSlots: Int = .max

    /// Residency bookkeeping only — deliberately does NOT retain the decoded
    /// ``ResidentChunk`` payload. The payload is handed to the consumer via
    /// the publish queue and never read again driver-side; retaining it here
    /// duplicated the entire resident set (~budget bytes) in host memory.
    private struct ResidentEntry {
        var ticksSinceWanted: Int
    }
    private var resident: [ChunkID: ResidentEntry] = [:]
    private var inFlight: Set<ChunkID> = []
    private var closed = false

    /// Number of currently-resident children per node, keyed by parent ID.
    /// Maintained on every admit/evict so leaf-first eviction can test
    /// "has a resident child" in O(1). Only meaningful when
    /// ``StreamingOptions/enforceHierarchyResidency`` is on.
    private var residentChildCount: [ChunkID: Int] = [:]
    /// Decoded-but-not-yet-published chunks held back because their parent
    /// is not resident yet. Guarantees the published resident set stays
    /// closed under parent even though decodes complete out of order.
    /// Bounded by the in-flight fan-out (a handful of chains), unlike the
    /// full resident set which is deliberately never retained here. Only
    /// used when ``StreamingOptions/enforceHierarchyResidency`` is on.
    private var pendingResident: [ChunkID: ResidentChunk] = [:]

    // Wanted-set cache. `wanted` depends only on the camera view, the
    // budget, and the immutable node hierarchy — eviction and in-flight
    // residency state don't change it. Caching avoids the O(nodes)
    // frustum scan + sort on every tick when the camera and budget are
    // unchanged (static frames, idle periods).
    private var cachedViews: [StreamingCameraView] = []
    private var cachedBudgetSlots: Int = .min
    /// Whether the cached wanted set was clamped by the budget with
    /// frustum-visible candidates excluded (see ``computeWantedSet(views:budget:)``).
    /// Republished to the settle box each tick.
    private var cachedBudgetLimited = false
    private var cachedWanted: Set<ChunkID> = []
    /// Wanted IDs in *load-priority order* (best to load first). Under
    /// the SSE scorer this is admission order from the budget-fill pass
    /// (highest score first, then halo). Under whole-file mode it is
    /// sorted by depth ASC so coarse coverage decodes before any leaf
    /// detail — otherwise a renderer drawing during the streaming-in
    /// phase sees patchy leaves before the root arrives.
    private var cachedWantedSorted: [ChunkID] = []
    private var cachedCandidates: Int = 0
    /// Pre-clamp demand (total candidate slot cost) from the last score pass.
    /// Cached alongside the wanted set so a cache-hit tick republishes the same
    /// demand to the settle box without re-scoring. See
    /// ``CopcStreamingPointCloudSource/residencyDemandSlots``.
    private var cachedDemandSlots: Int = 0

    init(
        handle: SendableCopcReader,
        nodes: [NodeMeta],
        originShift: SIMD3<Double>,
        options: StreamingOptions,
        queue: UpdateQueue,
        jobs: JobQueue,
        statsBox: DecodeStatsBox = DecodeStatsBox(),
        settleBox: ResidencySettleBox = ResidencySettleBox(),
        budgetBytesPerPoint: Int = 17,
        pointsPerBatch: Int = ChunkPacker.defaultPointsPerBatch,
        isRemote: Bool = false
    ) {
        self.handleBox = handle
        self.nodes = nodes
        self.nodeIndexByID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        self.allNodeIDs = Set(nodes.lazy.map(\.id))
        self.budgetBytesPerPoint = budgetBytesPerPoint
        // Slot cost = ceil(pointCount / pointsPerBatch); clamp granularity to
        // >= 1 so the ceil-division is well-defined.
        let ppb = max(1, pointsPerBatch)
        self.pointsPerBatch = ppb
        self.totalNodeSlots = nodes.reduce(0) { $0 + ($1.pointCount + ppb - 1) / ppb }
        self.maxNodeDepth = nodes.reduce(0) { max($0, $1.id.depth) }
        self.originShift = originShift
        self.options = options
        self.queue = queue
        self.jobs = jobs
        self.statsBox = statsBox
        self.settleBox = settleBox
        self.isRemote = isRemote
        self.tickInterval = options.driverTickInterval
        self.currentTargetScreenSize = max(options.targetChunkScreenSize, 1)

        // Resolve the pinned (always-resident) set once from the immutable
        // hierarchy. `nil` or a negative depth disables pinning.
        if let d = options.alwaysResidentDepth, d >= 0 {
            let pinned = nodes.filter { $0.id.depth <= d }
            self.pinnedIDs = Set(pinned.map(\.id))
            self.pinnedSlots = pinned.reduce(0) { $0 + ($1.pointCount + ppb - 1) / ppb }
            self.pinnedOrdered = pinned.sorted { $0.id.depth < $1.id.depth }.map(\.id)
        } else {
            self.pinnedIDs = []
            self.pinnedSlots = 0
            self.pinnedOrdered = []
        }
    }

    func setViews(_ vs: [StreamingCameraView]) { latestViews = vs }
    /// Single-view convenience (used by tests and the single-camera path).
    func setView(_ v: StreamingCameraView) { latestViews = [v] }
    /// Set the residency slot budget (max GPU slots the wanted set may occupy).
    /// Slot-denominated so the wanted set physically fits the renderer's slot
    /// pool. See ``budgetSlots`` / ``slotCost(_:)``.
    func setBudget(slots: Int) { budgetSlots = slots }

    /// Retarget the screen-space-error scorer at runtime. Invalidates the
    /// wanted-set cache so the next tick re-scores against the new target;
    /// resident chunks are untouched until they naturally leave the wanted
    /// set. Clamped `>= 1` to match the scorer's own guard.
    func setTargetScreenSize(_ v: Float) {
        let clamped = max(v, 1)
        guard clamped != currentTargetScreenSize else { return }
        currentTargetScreenSize = clamped
        cachedViews = []   // force a wanted-set recompute next tick
    }

    /// Swap the wanted-set construction strategy at runtime. Re-scores next
    /// tick; resident chunks are untouched until they fall out of the new
    /// wanted set. See ``StreamingOptions/residencyPolicy``.
    func setResidencyPolicy(_ p: ResidencyPolicy) {
        guard options.residencyPolicy != p else { return }
        options.residencyPolicy = p
        cachedViews = []   // force a wanted-set recompute next tick
    }

    /// Toggle the parent-closed residency invariant at runtime. Re-scores next
    /// tick. See ``StreamingOptions/enforceHierarchyResidency``.
    func setEnforceHierarchyResidency(_ on: Bool) {
        guard options.enforceHierarchyResidency != on else { return }
        options.enforceHierarchyResidency = on
        cachedViews = []   // force a wanted-set recompute next tick
    }

    /// Worker hook: a node moved from the pending queue into active decode.
    func beginDecode(id: ChunkID) {
        if closed { return }
        if decoding.insert(id).inserted { statsBox.decodeBegan() }
    }

    func cancel(_ ids: [ChunkID]) {
        let set = Set(ids)
        // Only still-pending (not-yet-decoding) cancellations release a
        // pending slot in the telemetry; actively-decoding nodes still run to
        // completion and are accounted by `completeLoad`.
        var pendingCancelled = 0
        for id in ids where inFlight.contains(id) && !decoding.contains(id) {
            pendingCancelled += 1
        }
        for id in ids { inFlight.remove(id) }
        if pendingCancelled > 0 { statsBox.cancelledPending(pendingCancelled) }
        jobs.remove(set)
    }

    func shutdown() {
        if closed { return }
        closed = true
        reader.close()
        resident.removeAll()
        inFlight.removeAll()
        residentChildCount.removeAll()
        pendingResident.removeAll()
        decoding.removeAll()
        statsBox.reset()
    }

    /// Called by a worker task once a chunk has been decoded.
    ///
    /// Decoupled from the tick loop: a slow decode no longer stalls
    /// subsequent ticks. Cancelled or evicted chunks (those removed
    /// from `inFlight` after being scheduled) are dropped here.
    func completeLoad(id: ChunkID, chunk: ResidentChunk?) {
        if closed { return }
        // Decode telemetry: a node that a worker began decoding has now
        // finished (whether or not it is still wanted). Success = it produced
        // a chunk; cumulative point total comes from the chunk itself.
        if decoding.remove(id) != nil {
            statsBox.decodeEnded(points: chunk?.totalPointCount ?? 0, success: chunk != nil)
        }
        let wasInFlight = inFlight.remove(id) != nil
        guard wasInFlight, let chunk else { return }
        guard options.enforceHierarchyResidency else {
            markResident(id)
            queue.enqueue(added: [chunk], removed: [])
            return
        }
        // Hierarchy invariant: a child may not be published as resident
        // before its parent. Decodes complete out of order, so hold this
        // chunk until its parent is resident, then release parent-first.
        pendingResident[id] = chunk
        flushPending()
    }

    /// Mark `id` resident and maintain the parent's resident-child count.
    private func markResident(_ id: ChunkID) {
        resident[id] = ResidentEntry(ticksSinceWanted: 0)
        if let p = id.parent { residentChildCount[p, default: 0] += 1 }
    }

    /// Remove `id` from residency and maintain the parent's resident-child
    /// count. Callers guarantee `id` itself has no resident children
    /// (leaf-first eviction).
    private func removeResident(_ id: ChunkID) {
        resident.removeValue(forKey: id)
        residentChildCount.removeValue(forKey: id)
        guard let p = id.parent, let c = residentChildCount[p] else { return }
        if c <= 1 { residentChildCount.removeValue(forKey: p) }
        else { residentChildCount[p] = c - 1 }
    }

    /// Release held-back chunks whose parent is now resident, in
    /// parent-before-child order, and publish them as one `added` delta.
    ///
    /// Runs to a fixpoint: releasing a parent can unblock its children in a
    /// later pass. The published array is sorted by depth ascending so a
    /// consumer applying it in order never sees a child before its parent.
    private func flushPending() {
        guard !pendingResident.isEmpty else { return }
        var released: [ResidentChunk] = []
        var progressed = true
        while progressed {
            progressed = false
            for id in Array(pendingResident.keys) {
                let parentResident = id.parent.map { resident[$0] != nil } ?? true
                guard parentResident, let chunk = pendingResident.removeValue(forKey: id)
                else { continue }
                markResident(id)
                released.append(chunk)
                progressed = true
            }
        }
        if !released.isEmpty {
            released.sort { $0.id.depth < $1.id.depth }
            queue.enqueue(added: released, removed: [])
        }
    }

    /// Diagnostic counts for tests. Reset on each tick.
    private(set) var lastTickCandidates: Int = 0
    private(set) var lastTickWanted: Int = 0
    private(set) var lastTickResident: Int = 0
    private(set) var lastTickInFlight: Int = 0
    /// Nodes that passed the frustum test under
    /// ``ResidencyPolicy/frustumFirstThenHalo``. 0 under
    /// ``ResidencyPolicy/distanceOnly`` (no frustum computed) and 0
    /// when the whole-file shortcut engaged.
    private(set) var lastTickFrustumVisible: Int = 0
    /// Cumulative wanted-set cache hits / misses since driver start.
    private(set) var wantedCacheHits: Int = 0
    private(set) var wantedCacheMisses: Int = 0

    func snapshot() -> StreamingDebugSnapshot {
        let maxDepth = self.maxNodeDepth
        var residentByDepth = [Int](repeating: 0, count: maxDepth + 1)
        for id in resident.keys {
            let d = id.depth
            if d < residentByDepth.count { residentByDepth[d] &+= 1 }
        }
        var wantedByDepth = [Int](repeating: 0, count: maxDepth + 1)
        for id in cachedWanted {
            let d = id.depth
            if d < wantedByDepth.count { wantedByDepth[d] &+= 1 }
        }
        return StreamingDebugSnapshot(
            candidates: lastTickCandidates,
            wanted: lastTickWanted,
            resident: lastTickResident,
            inFlight: lastTickInFlight,
            frustumVisible: lastTickFrustumVisible,
            totalNodes: nodes.count,
            cacheHits: wantedCacheHits,
            cacheMisses: wantedCacheMisses,
            residentByDepth: residentByDepth,
            wantedByDepth: wantedByDepth
        )
    }

    // MARK: Test hooks (internal; not part of the public contract)
    //
    // The hierarchy-residency unit tests drive the driver against a
    // synthetic hierarchy without a decode pipeline, so they need to read
    // the otherwise-private wanted/resident/in-flight state. `completeLoad`,
    // `runOneTick`, `setView`, and `setBudget` are already internal.
    func _wantedSetForTest(view: StreamingCameraView, budget: Int)
    -> (set: Set<ChunkID>, ordered: [ChunkID]) {
        let r = computeWantedSet(views: [view], budget: budget)
        return (r.set, r.ordered)
    }

    /// Multi-view variant of ``_wantedSetForTest(view:budget:)``. Also surfaces
    /// the pre-clamp ``demand`` so a governance test can assert demand-vs-budget
    /// behaviour without a live driver tick.
    func _wantedSetForTest(views: [StreamingCameraView], budget: Int)
    -> (set: Set<ChunkID>, ordered: [ChunkID], budgetLimited: Bool, demand: Int) {
        computeWantedSet(views: views, budget: budget)
    }
    var _residentIDsForTest: Set<ChunkID> { Set(resident.keys) }
    var _inFlightIDsForTest: Set<ChunkID> { inFlight }
    var _pinnedIDsForTest: Set<ChunkID> { pinnedIDs }
    var _targetScreenSizeForTest: Float { currentTargetScreenSize }
    func _statsSnapshotForTest() -> StreamingDecodeStats { statsBox.snapshot() }

    /// Runs one residency-policy pass. Returns whether the tick did any
    /// meaningful work (wanted-set recompute, eviction, or scheduling) —
    /// ``CopcStreamingPointCloudSource/startDriver()`` uses this to back
    /// off the tick cadence when the camera and resident set are static.
    @discardableResult
    func runOneTick() -> Bool {
        if closed { return false }
        guard !latestViews.isEmpty else {
            // No target submitted → nothing wanted → trivially settled, so a
            // pre-roll that (defensively) submitted no views never spins. No
            // views → no candidates → zero demand.
            settleBox.update(settled: true, budgetLimited: false, wanted: 0,
                             resident: resident.count, demandSlots: 0)
            return false
        }
        let views = latestViews

        // 1. Score nodes against the camera(s) + budget — cached when the
        //    (view set, budget) pair is unchanged from the previous tick.
        let wanted: Set<ChunkID>
        let wantedOrdered: [ChunkID]
        let budgetLimited: Bool
        let demand: Int
        let wasCacheMiss: Bool
        if cachedViews == views, cachedBudgetSlots == budgetSlots {
            wanted = cachedWanted
            wantedOrdered = cachedWantedSorted
            budgetLimited = cachedBudgetLimited
            demand = cachedDemandSlots
            lastTickCandidates = cachedCandidates
            wantedCacheHits &+= 1
            wasCacheMiss = false
        } else {
            let computed = computeWantedSet(views: views, budget: budgetSlots)
            wanted = computed.set
            wantedOrdered = computed.ordered
            budgetLimited = computed.budgetLimited
            demand = computed.demand
            cachedViews = views
            cachedBudgetSlots = budgetSlots
            cachedWanted = wanted
            cachedWantedSorted = wantedOrdered
            cachedBudgetLimited = budgetLimited
            cachedDemandSlots = demand
            cachedCandidates = lastTickCandidates
            wantedCacheMisses &+= 1
            wasCacheMiss = true
        }
        lastTickWanted = wanted.count
        lastTickResident = resident.count
        lastTickInFlight = inFlight.count

        // Publish the settle state for this tick's target. `settled` = every
        // wanted chunk is resident and nothing is mid-decode; `budgetLimited`
        // qualifies it (settled+limited = "all the budget allows is in, but more
        // is visible"). Deferred to a closure so every early return still
        // publishes a consistent snapshot after this tick's evict/schedule work.
        func publishSettle() {
            let settled = inFlight.isEmpty && !wanted.contains { resident[$0] == nil }
            settleBox.update(settled: settled, budgetLimited: budgetLimited,
                             wanted: wanted.count, resident: resident.count,
                             demandSlots: demand)
        }

        var tickRemoved: [ChunkID] = []

        // 2. Evict (with hysteresis). Iterate a snapshot of the *keys*, not the
        //    dictionary itself: a `for (id, var entry) in resident { resident[id]
        //    = … }` pins the storage via the live iterator, so the first write
        //    each tick copy-on-writes the WHOLE dict (O(resident.count)
        //    ResidentEntry copies + retains). That fires every tick — even on a
        //    static camera where nothing changes — and dominates driver CPU on
        //    large resident sets. `Array(resident.keys)` is a separate buffer, so
        //    `resident` stays uniquely-referenced and writes mutate in place.
        //    Also skip the no-op write when a wanted entry is already current.
        let enforce = options.enforceHierarchyResidency
        for id in Array(resident.keys) {
            guard var entry = resident[id] else { continue }
            if wanted.contains(id) {
                if entry.ticksSinceWanted != 0 {
                    entry.ticksSinceWanted = 0
                    resident[id] = entry
                }
            } else {
                // Pinned nodes are permanently resident and never evicted.
                // They are always in `wanted` (seeded by `computeWantedSet`),
                // so this branch is normally unreachable for them — the guard
                // is defensive against a future scorer change.
                if pinnedIDs.contains(id) { continue }
                entry.ticksSinceWanted += 1
                if entry.ticksSinceWanted >= options.evictionDelayTicks {
                    // Leaf-first: never evict a node while a descendant is
                    // still resident — that would re-open the density hole
                    // the invariant exists to prevent. Keep it resident and
                    // retry once its children have been evicted. A node's
                    // ancestors are always co-wanted (the wanted set is
                    // closed under parent), so this only ever defers the
                    // eviction of a node whose whole subtree is leaving.
                    if enforce && (residentChildCount[id] ?? 0) > 0 {
                        resident[id] = entry
                    } else {
                        tickRemoved.append(id)
                        removeResident(id)
                    }
                } else {
                    resident[id] = entry
                }
            }
        }

        // Drop held-back chunks that are no longer wanted (camera moved on
        // before their parent chain materialized) — the consumer never saw
        // them, so there is nothing to evict.
        if enforce && !pendingResident.isEmpty {
            for id in Array(pendingResident.keys) where !wanted.contains(id) {
                pendingResident.removeValue(forKey: id)
            }
            // A parent that landed between decode completions may have
            // unblocked stragglers; release them now.
            flushPending()
        }

        if !tickRemoved.isEmpty {
            // Publish descendants before ancestors so a consumer applying
            // `removed` in array order never frees a parent out from under a
            // still-resident child.
            if enforce { tickRemoved.sort { $0.depth > $1.depth } }
            queue.enqueue(added: [], removed: tickRemoved)
        }

        // 3. Enqueue new decode jobs in load-priority order (best chunks
        //    first per the wanted-set scorer; coarse-first under
        //    whole-file mode). Cap at maxInFlightLoads per tick.
        //    Persistent worker tasks consume the queue; completed
        //    chunks publish to ``UpdateQueue`` from
        //    ``completeLoad(id:chunk:)``, so a slow decode does not
        //    stall subsequent ticks.
        // Backpressure: if the consumer isn't draining the publish queue
        // (stalled frame loop, memory pressure), stop scheduling decodes —
        // decoded-but-unconsumed chunks are pure memory growth. Resumes
        // automatically on the next tick after a drain. Counts as an
        // active tick (not idle): work is pending behind the consumer's
        // drain, so we want to retry at the fast cadence and resume
        // promptly once the queue drains, rather than backing off while
        // genuinely busy.
        // Convert the slot budget back to an approximate host-memory figure to
        // size the backlog cap (clamped to [64 MB, 512 MB]). Saturate to
        // Int.max instead of trapping when the budget is effectively unbounded
        // (`.max` slots): the clamp collapses it to 512 MB either way.
        let budgetBytesApprox = budgetSlots
            .multipliedReportingOverflow(by: pointsPerBatch * budgetBytesPerPoint)
        let budgetBytesEquiv = budgetBytesApprox.overflow ? Int.max : budgetBytesApprox.partialValue
        let backlogCap = min(max(64 << 20, budgetBytesEquiv / 4), 512 << 20)
        if queue.pendingAddedBytes >= backlogCap { publishSettle(); return true }

        var toLoad: [ChunkID] = []
        var markedEmpty = false
        toLoad.reserveCapacity(options.maxInFlightLoads)
        for id in wantedOrdered {
            if resident[id] != nil { continue }
            if inFlight.contains(id) { continue }
            // A 0-point node carries no geometry: `read_node` returns 0 points, so
            // `decodeAndPack` yields nil and the node can never become resident via
            // the normal decode path. Left alone it blocks the "all wanted
            // resident" settle check forever AND orphans its real children in
            // `pendingResident` (they wait for this parent to land). Resolve it up
            // front instead of scheduling a decode that returns nil every tick:
            // mark it resident with an empty entry (publishes no queue delta, so
            // the consumer has nothing to upload) so the settle check passes and
            // `flushPending` releases its held children. Done regardless of the
            // `maxInFlightLoads` cap since it schedules no decode work.
            if let idx = nodeIndexByID[id], nodes[idx].pointCount == 0 {
                markResident(id)
                markedEmpty = true
                continue
            }
            if toLoad.count == options.maxInFlightLoads { continue }
            toLoad.append(id)
        }
        // Newly-resident empties may have unblocked children queued in
        // `pendingResident` — release them before publishing this tick's settle.
        if markedEmpty { flushPending() }
        if toLoad.isEmpty {
            // Nothing new to schedule this tick — still "active" if the
            // wanted set changed, something was evicted, or wanted chunks
            // remain non-resident (queued behind the maxInFlightLoads cap
            // or still decoding). Only a pure no-op tick backs off.
            let pendingWantedWork = wanted.contains { resident[$0] == nil }
            publishSettle()
            return wasCacheMiss || !tickRemoved.isEmpty || markedEmpty || pendingWantedWork
        }
        for id in toLoad { inFlight.insert(id) }
        statsBox.scheduled(toLoad.count)
        // Group the load-priority-ordered nodes into offset-adjacent clusters so
        // a worker can prefetch each cluster's compressed blocks in one coalesced
        // read instead of one seek / round-trip per node. Clustering preserves
        // load priority (clusters ordered by their best member). See ``NodePrefetch``.
        let toLoadNodes = toLoad.compactMap { id -> (id: ChunkID, offset: UInt64, size: Int)? in
            guard let idx = nodeIndexByID[id] else { return nil }
            let n = nodes[idx]
            return (id, n.offset, n.byteSize)
        }
        let clusters = NodePrefetch.cluster(
            toLoadNodes,
            gapBytes: NodePrefetch.gapBytes(isRemote: isRemote)
        )
        jobs.enqueue(clusters)
        // Just scheduled loads → wanted chunks are still non-resident / in flight,
        // so this publishes settled == false.
        publishSettle()
        return true
    }

    private func computeWantedSet(views: [StreamingCameraView], budget: Int)
    -> (set: Set<ChunkID>, ordered: [ChunkID], budgetLimited: Bool, demand: Int) {
        // Whole-file shortcut: if every node's slots fit in the budget, every
        // node is wanted. Skip the frustum scan and sort entirely, but
        // produce a depth-ASC load order so coarse coverage arrives
        // before any leaf-depth detail during streaming-in. Every node is a
        // candidate here, so the pre-clamp demand is the whole file's slot cost.
        if totalNodeSlots <= budget {
            lastTickCandidates = nodes.count
            lastTickFrustumVisible = 0
            let ordered = nodes.sorted { $0.id.depth < $1.id.depth }.map(\.id)
            return (allNodeIDs, ordered, false, totalNodeSlots)
        }

        struct Scored { let id: ChunkID; let score: Float; let slots: Int }
        var visible: [Scored] = []
        var hidden: [Scored] = []
        visible.reserveCapacity(nodes.count)

        // Screen-space-error scorer: each candidate is judged by how
        // close its projected on-screen size matches
        // ``StreamingOptions/targetChunkScreenSize``. The previous
        // 1/distance heuristic biased the wanted set toward fine
        // leaf-depth chunks near the camera and starved coarse
        // ancestors that would have provided coverage of far regions —
        // producing the "pockets of detail, vast black in between"
        // failure mode the test fixtures and rendered consumers hit.
        //
        // For each node:
        //   screenPx = extent * view.pixelScale / distance
        //   ratio    = screenPx / target
        //   err      = |log2(ratio)|        (0 = perfect match)
        //   score    = 1 / (1 + err)        (peaks at err = 0)
        //
        // A coarse node far from the camera and a fine node close to
        // it both hit `err ≈ 0` at their natural depth; the chunks
        // that win the budget race are the ones at the *right* level
        // for their distance, not just the closest ones.
        //
        // Multi-view: the wanted set is the UNION over all submitted views.
        // A node is a candidate if it is frustum-visible in *any* view, and
        // its score is the BEST (max) it achieves across the views that see
        // it — so a chunk seen edge-on by one screen but head-on by another
        // is admitted at the detail the head-on screen needs. Per-view
        // pixelScale / ortho-ness / frustum planes are precomputed once.
        let target = currentTargetScreenSize

        struct ViewEval {
            let position: SIMD3<Float>
            let pixelScale: Float
            let isOrthographic: Bool
            let planes: FrustumPlanes
        }
        let evals: [ViewEval] = views.map { view in
            // Ortho detection: for projection·view built from a rigid view
            // matrix and an orthographic projection, the w-row collapses to
            // (0,0,0,1) — there's no perspective divide. Apparent on-screen
            // size under ortho is therefore distance-independent (no
            // foreshortening), so dividing by distance would skew the wanted
            // set toward whichever chunks sit near the camera. `pixelScale`
            // is already pixels-per-world-unit there (see its doc comment).
            let m = view.viewProjection
            let isOrtho =
                abs(m.columns.0.w) < 1e-6 && abs(m.columns.1.w) < 1e-6 &&
                abs(m.columns.2.w) < 1e-6 && abs(m.columns.3.w - 1) < 1e-3
            return ViewEval(position: view.position,
                            pixelScale: max(view.pixelScale, 1e-6),
                            isOrthographic: isOrtho,
                            planes: FrustumPlanes(viewProjection: m))
        }

        func score(_ node: NodeMeta, in eval: ViewEval) -> Float {
            let screenPx: Float
            if eval.isOrthographic {
                screenPx = max(node.extent * eval.pixelScale, 1e-6)
            } else {
                let distance = simd_length(node.center - eval.position) + 1e-3
                screenPx = max(node.extent * eval.pixelScale / distance, 1e-6)
            }
            let err = abs(log2(screenPx / target))
            return 1 / (1 + err)
        }

        // Pre-clamp demand: total slot cost of the candidate set that could feed
        // the wanted set BEFORE the budget clamps it — the frustum-visible nodes
        // (every node under .distanceOnly and the whole-file shortcut above). The
        // off-frustum halo is opportunistic leftover-budget fill, not appetite
        // the camera is actually asking for, so it is deliberately excluded: a
        // source with nothing in any submitted frustum reports demand 0 and a
        // host governor hands it only the floor. Accumulated here for near-zero
        // extra cost (we already touch every candidate to score it). Pinned
        // always-resident nodes are a niche feature and are not added — demand
        // tracks the view set's appetite, and pinned coverage is charged to the
        // budget independently.
        var demandSlots = 0
        switch options.residencyPolicy {
        case .distanceOnly:
            // No frustum gate — everything is a candidate; score = best over views.
            for node in nodes {
                var best: Float = 0
                for e in evals { best = max(best, score(node, in: e)) }
                let slots = slotCost(node.pointCount)
                demandSlots += slots
                visible.append(Scored(id: node.id, score: best, slots: slots))
            }
        case .frustumFirstThenHalo:
            // Candidate if visible in ANY view; score = best over the views
            // that actually see it (fall back to best overall if none — only
            // possible for a node placed in `hidden`, where score is unused
            // for admission ordering until the halo pass).
            for node in nodes {
                var best: Float = 0
                var seen = false
                for e in evals where e.planes.intersects(min: node.minXYZ, max: node.maxXYZ) {
                    seen = true
                    best = max(best, score(node, in: e))
                }
                let slots = slotCost(node.pointCount)
                if seen {
                    demandSlots += slots
                    visible.append(Scored(id: node.id, score: best, slots: slots))
                } else {
                    // Not in any frustum: halo candidate, scored by its best
                    // over all views (proximity, for filling leftover budget).
                    var haloBest: Float = 0
                    for e in evals { haloBest = max(haloBest, score(node, in: e)) }
                    hidden.append(Scored(id: node.id, score: haloBest, slots: slots))
                }
            }
        }
        lastTickCandidates = visible.count + hidden.count
        // `visible` carries everything under .distanceOnly (frustum not
        // computed); only meaningful under .frustumFirstThenHalo.
        lastTickFrustumVisible = (options.residencyPolicy == .frustumFirstThenHalo)
            ? visible.count : 0

        // Pass 1: nearest visible chunks fill the budget. Admission
        // order doubles as load order (best chunks first).
        visible.sort { $0.score > $1.score }
        var wanted = Set<ChunkID>()
        var ordered: [ChunkID] = []
        ordered.reserveCapacity(visible.count + hidden.count + pinnedOrdered.count)
        var used = 0
        let enforce = options.enforceHierarchyResidency

        // Seed the pinned (always-resident) prefix first: pinned nodes are
        // wanted unconditionally and charged to the budget before any scored
        // node, and scheduled coarse-first. If the pinned set alone meets or
        // exceeds the budget, the scored admission below finds no headroom and
        // clamps to zero — the pins are honored regardless of budget. The
        // pinned prefix is closed under parent, so it also anchors every
        // scored node's ancestor-chain climb (which stops at the first
        // already-wanted node).
        if !pinnedIDs.isEmpty {
            wanted.formUnion(pinnedIDs)
            ordered.append(contentsOf: pinnedOrdered)
            used += pinnedSlots
        }

        // Admit a candidate, keeping the wanted set closed under parent.
        //
        // With the invariant on, a candidate drags in its missing ancestor
        // chain (root-first). Ancestors are charged to the slot budget first —
        // they cover more area per slot — and the candidate's own level is
        // only admitted if it still fits after them. When the full chain
        // won't fit, the longest root-anchored prefix that does fit is
        // admitted and the deeper tail is deferred (never admitted orphaned,
        // so a finer node never appears without the coarse coverage behind
        // it). With the invariant off this degrades to the original
        // single-node budget admit.
        func admit(_ id: ChunkID) {
            if wanted.contains(id) { return }
            guard enforce else {
                let s = nodeSlots(id)
                if used + s <= budget {
                    wanted.insert(id); ordered.append(id); used += s
                }
                return
            }
            var chain: [ChunkID] = []
            var cur: ChunkID? = id
            while let c = cur, !wanted.contains(c) {
                guard nodeIndexByID[c] != nil else {
                    // Candidate itself absent → nothing to admit; a missing
                    // ancestor (shouldn't happen in a connected COPC tree)
                    // just stops the climb.
                    if c == id { return }
                    break
                }
                chain.append(c)
                cur = c.parent
            }
            for node in chain.reversed() {   // root-first
                let s = nodeSlots(node)
                if used + s > budget { break }
                wanted.insert(node); ordered.append(node); used += s
            }
        }

        for c in visible { admit(c.id) }

        // Budget-limited iff a frustum-visible candidate didn't make the wanted
        // set — i.e. the budget clamped coverage the camera(s) can actually see.
        // Computed before the halo pass (halo nodes are off-screen fill, not a
        // coverage shortfall). Drives the offline pre-roll's budget auto-raise.
        let budgetLimited = visible.contains { !wanted.contains($0.id) }

        // Pass 2 (halo): fill remaining headroom from nearest non-visible
        // chunks. Only reachable under .frustumFirstThenHalo; under
        // .distanceOnly the hidden array is empty.
        if !hidden.isEmpty && used < budget {
            hidden.sort { $0.score > $1.score }
            for c in hidden { admit(c.id) }
        }

        return (wanted, ordered, budgetLimited, demandSlots)
    }

    /// GPU slot cost of a single node's payload, or `0` if the node is not in
    /// the hierarchy. Mirrors the `Scored.slots` accounting.
    private func nodeSlots(_ id: ChunkID) -> Int {
        guard let idx = nodeIndexByID[id] else { return 0 }
        return slotCost(nodes[idx].pointCount)
    }

    /// Slots a node of `pointCount` points occupies in the renderer's GPU pool.
    ///
    /// The pool allocates whole `pointsPerBatch`-sized slots, so a node costs
    /// `ceil(pointCount / pointsPerBatch)` slots — a partial final batch still
    /// burns a full slot. Charging slots (rather than bytes) is what makes
    /// "wanted set fits the pool" hold by construction: byte accounting was
    /// systematically optimistic vs the pool because it ignored partial-batch
    /// waste. A **0-point node costs 0 slots** (`ceil(0) == 0`), which keeps the
    /// 0-point auto-resolve path in ``runOneTick()`` free of budget pressure.
    private func slotCost(_ pointCount: Int) -> Int {
        (pointCount + pointsPerBatch - 1) / pointsPerBatch
    }

    /// Decode + pack a single COPC node into a render-ready chunk.
    ///
    /// `nonisolated` and `static` so it can run on a cooperative thread
    /// outside the actor. Thread-safety is achieved by giving every
    /// concurrent caller a distinct `slot` into the file reader pool
    /// established in ``CopcStreamingPointCloudSource/open(_:options:)``.
    nonisolated static func decodeAndPack(
        reader: CopcReader,
        slot: Int32,
        id: ChunkID,
        originShift: SIMD3<Double>,
        extraDescs: [CopcExtractDesc],
        extraNames: [String],
        rgbShiftBits: UInt32?,
        workspace: ChunkPacker.Workspace? = nil
    ) -> ResidentChunk? {
        // The decoded chunk is ~Copyable; do everything that touches it inside
        // the descriptor buffer's scope so the C++ ChunkData stays alive while
        // ChunkPacker reads its raw pointers.
        extraDescs.withUnsafeBufferPointer { descBuf -> ResidentChunk? in
            let chunk = reader.read_node(
                Int32(id.depth), Int32(id.x), Int32(id.y), Int32(id.z),
                slot, descBuf.baseAddress, Int32(descBuf.count)
            )
            let count = Int(chunk.point_count())
            guard count > 0 else { return nil }

            // xyz_data() / rgb_data() / extra_data() return raw const pointers
            // into the ChunkData's std::vector storage; the chunk stays alive
            // on this frame so the pointers remain valid through ChunkPacker.
            let extraDimCount = Int(chunk.extra_dim_count())
            let packed = ChunkPacker.pack(
                positionsXYZ: chunk.__xyz_dataUnsafe()!,
                rgb16: chunk.__rgb_dataUnsafe()!,
                count: count,
                hasRgb: chunk.has_rgb(),
                originShift: originShift,
                extra: extraDimCount > 0 ? chunk.__extra_dataUnsafe() : nil,
                extraCount: extraDimCount,
                extraNames: extraNames,
                rgbShiftBits: rgbShiftBits,
                workspace: workspace
            )

            return ResidentChunk(
                id: id,
                batches: packed.batches,
                xyzLow: packed.xyzLow,
                xyzMed: packed.xyzMed,
                xyzHigh: packed.xyzHigh,
                colors: packed.colors,
                levels: packed.levels,
                extraScalars: packed.extraScalars
            )
        }
    }
}

// MARK: - Frustum

/// 6-plane frustum extracted from a view-projection matrix (Gribb-Hartmann),
/// adapted for Metal's clip-space z convention (z ∈ [0, w], not OpenGL's
/// [-w, w]).
struct FrustumPlanes: Sendable {
    let planes: [SIMD4<Float>]  // ax + by + cz + d >= 0 means "inside"

    init(viewProjection m: simd_float4x4) {
        // simd_float4x4 is column-major; rows are .columns[col][row].
        // Reconstruct rows:
        let r0 = SIMD4<Float>(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        let r1 = SIMD4<Float>(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        let r2 = SIMD4<Float>(m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z)
        let r3 = SIMD4<Float>(m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)

        // Metal clips z to [0, w] (not OpenGL's [-w, w]), so the near
        // half-space is `r2` alone — `r3 + r2` is the OpenGL near plane
        // and never culls anything under Metal's convention (under ortho,
        // w≡1 makes it `1 + z ≥ 0`, always true). Under reversed-Z the
        // same pair still bounds the same clip-space slab.
        planes = [
            r3 + r0, r3 - r0,   // left, right
            r3 + r1, r3 - r1,   // bottom, top
            r2, r3 - r2,        // near (z ≥ 0, Metal clip), far (z ≤ w)
        ]
    }

    /// Conservative AABB-vs-frustum test. Returns true if the AABB may
    /// intersect the frustum (no false negatives).
    func intersects(min mn: SIMD3<Float>, max mx: SIMD3<Float>) -> Bool {
        for p in planes {
            let positive = SIMD3<Float>(
                p.x >= 0 ? mx.x : mn.x,
                p.y >= 0 ? mx.y : mn.y,
                p.z >= 0 ? mx.z : mn.z
            )
            if p.x * positive.x + p.y * positive.y + p.z * positive.z + p.w < 0 {
                return false
            }
        }
        return true
    }
}
