import Foundation
import simd
import CxxCOPC

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
    /// VRAM footprint.
    public let bytesPerPoint: Int
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
    public var padding3: UInt32 = 0
    public var padding4: UInt32 = 0
    public var padding5: UInt32 = 0
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

    /// Total points in this chunk (sum of `batches[i].numPoints`).
    public var totalPointCount: Int { batches.reduce(0) { $0 + Int($1.numPoints) } }
    /// Approximate GPU byte cost: `totalPointCount * 17` (positions +
    /// colors + levels). Use this to track budget against
    /// ``StreamingSourceInfo/bytesPerPoint``.
    public var byteCost: Int { totalPointCount * 17 }
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
public enum ResidencyPolicy: Sendable {
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
    /// decompression is single-threaded per chunk.
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
    public init(
        maxInFlightLoads: Int = 4,
        decodeConcurrency: Int = 4,
        lodMode: LODMode = .perChunk,
        prefetchRoot: Bool = true,
        evictionDelayTicks: Int = 5,
        driverTickInterval: Duration = .milliseconds(100),
        residencyPolicy: ResidencyPolicy = .frustumFirstThenHalo
    ) {
        self.maxInFlightLoads = maxInFlightLoads
        self.decodeConcurrency = decodeConcurrency
        self.lodMode = lodMode
        self.prefetchRoot = prefetchRoot
        self.evictionDelayTicks = evictionDelayTicks
        self.driverTickInterval = driverTickInterval
        self.residencyPolicy = residencyPolicy
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
/// and byte budget, and returns ready-to-upload chunks. The protocol is
/// deliberately small so the renderer package stays free of PDAL /
/// LASzip / copc-lib dependencies.
///
/// ## Usage
///
/// ```swift
/// let source = try await CopcStreamingPointCloudSource.open(url)
/// source.setBudget(2 << 30)              // 2 GB
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

    /// Update the byte budget for resident payloads (positions + colors
    /// + levels). Takes effect on the next driver tick.
    ///
    /// - Parameter bytes: Maximum total payload bytes. Resident chunks
    ///   will not exceed this budget.
    func setBudget(_ bytes: Int)

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
}

// MARK: - Node metadata snapshot

struct NodeMeta: Sendable {
    let id: ChunkID
    let pointCount: Int
    let minXYZ: SIMD3<Float>   // origin-shifted, Float
    let maxXYZ: SIMD3<Float>
    let center: SIMD3<Float>
    let extent: Float          // longest-axis size
}

// MARK: - Publish queue

/// Lock-protected output queue. The driver actor appends; consumers drain
/// via the synchronous `pollLatest`. Decouples actor isolation from the
/// render thread's non-async hot path.
final class UpdateQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var added: [ResidentChunk] = []
    private var removed: [ChunkID] = []

    func enqueue(added: [ResidentChunk], removed: [ChunkID]) {
        lock.lock(); defer { lock.unlock() }
        self.added.append(contentsOf: added)
        self.removed.append(contentsOf: removed)
    }

    func drain() -> StreamingUpdate? {
        lock.lock(); defer { lock.unlock() }
        if added.isEmpty && removed.isEmpty { return nil }
        let u = StreamingUpdate(added: added, removed: removed)
        added.removeAll(keepingCapacity: true)
        removed.removeAll(keepingCapacity: true)
        return u
    }
}

// MARK: - Job queue

/// Lock-protected FIFO of pending decode jobs.
///
/// The driver actor's tick enqueues ``ChunkID``s; persistent slot
/// workers `await pop()` to drain them. When the queue is empty,
/// `pop()` suspends on a continuation and resumes when the next
/// `enqueue` lands or `close()` is called. Closing returns `nil` from
/// any waiting `pop` so workers can exit cleanly.
///
/// The queue is non-actor so the driver can enqueue without an extra
/// actor hop; concurrency control is a single `NSLock`.
final class JobQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ChunkID] = []
    private var waiters: [CheckedContinuation<ChunkID?, Never>] = []
    private var closed = false

    func enqueue<S: Sequence>(_ ids: S) where S.Element == ChunkID {
        var handoffs: [(CheckedContinuation<ChunkID?, Never>, ChunkID)] = []
        lock.withLock {
            if closed { return }
            var leftover: [ChunkID] = []
            for id in ids {
                if !waiters.isEmpty {
                    handoffs.append((waiters.removeFirst(), id))
                } else {
                    leftover.append(id)
                }
            }
            if !leftover.isEmpty { pending.append(contentsOf: leftover) }
        }
        for (w, id) in handoffs { w.resume(returning: id) }
    }

    func pop() async -> ChunkID? {
        return await withCheckedContinuation { (c: CheckedContinuation<ChunkID?, Never>) in
            // Resolve immediately if we have a job (or are closed);
            // otherwise park the continuation in `waiters` and let
            // enqueue/close resume it later. Either way, no await
            // happens while holding the lock.
            enum Action { case resume(ChunkID?), wait }
            let action: Action = lock.withLock {
                if closed { return .resume(nil) }
                if !pending.isEmpty { return .resume(pending.removeFirst()) }
                waiters.append(c)
                return .wait
            }
            switch action {
            case .resume(let v): c.resume(returning: v)
            case .wait: break
            }
        }
    }

    /// Drop any pending jobs matching the given IDs. Already-popped
    /// jobs (in-flight on a worker) are not affected.
    func remove(_ ids: Set<ChunkID>) {
        if ids.isEmpty { return }
        lock.withLock {
            pending.removeAll { ids.contains($0) }
        }
    }

    func close() {
        let toResume: [CheckedContinuation<ChunkID?, Never>] = lock.withLock {
            closed = true
            let w = waiters
            waiters.removeAll()
            pending.removeAll()
            return w
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
/// - Important: Call ``close()`` when finished to release the file handle
///   and stop the driver Task.
public final class CopcStreamingPointCloudSource: StreamingPointCloudSource, @unchecked Sendable {
    /// File-level metadata. Stable after ``open(_:options:)`` returns.
    public let info: StreamingSourceInfo

    private let driver: StreamingDriver
    private let queue: UpdateQueue
    private let jobs: JobQueue
    private let handleBox: SendableCopcHandle
    private let originShift: SIMD3<Double>
    private let workerCount: Int
    private var driverTask: Task<Void, Never>?
    private var workerTasks: [Task<Void, Never>] = []

    private init(
        info: StreamingSourceInfo,
        driver: StreamingDriver,
        queue: UpdateQueue,
        jobs: JobQueue,
        handle: SendableCopcHandle,
        originShift: SIMD3<Double>,
        workerCount: Int
    ) {
        self.info = info
        self.driver = driver
        self.queue = queue
        self.jobs = jobs
        self.handleBox = handle
        self.originShift = originShift
        self.workerCount = workerCount
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
        guard let handle: copc_handle = url.path.withCString({ swiftpdal_copc_open($0, poolSize) }) else {
            throw StreamingSourceError.openFailed(url)
        }

        var minXYZ = [Double](repeating: 0, count: 3)
        var maxXYZ = [Double](repeating: 0, count: 3)
        guard swiftpdal_copc_bounds(handle, &minXYZ, &maxXYZ) == 0 else {
            swiftpdal_copc_close(handle)
            throw StreamingSourceError.malformedHierarchy("bounds")
        }
        let originShift = SIMD3<Double>(
            (minXYZ[0] + maxXYZ[0]) * 0.5,
            (minXYZ[1] + maxXYZ[1]) * 0.5,
            (minXYZ[2] + maxXYZ[2]) * 0.5
        )

        var nodeCount: Int32 = 0
        _ = swiftpdal_copc_node_count(handle, &nodeCount)

        var totalPoints: Int64 = 0
        _ = swiftpdal_copc_total_points(handle, &totalPoints)

        var nodes: [NodeMeta] = []
        nodes.reserveCapacity(Int(nodeCount))
        var maxDepth = 0
        for i in 0..<nodeCount {
            var n = copc_node_info()
            if swiftpdal_copc_node_at(handle, i, &n) != 0 { continue }
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
                center: center, extent: extent
            ))
            maxDepth = max(maxDepth, Int(n.depth))
        }

        let bounds = Bounds(
            min: SIMD3<Float>(Float(minXYZ[0]), Float(minXYZ[1]), Float(minXYZ[2])),
            max: SIMD3<Float>(Float(maxXYZ[0]), Float(maxXYZ[1]), Float(maxXYZ[2]))
        )

        let info = StreamingSourceInfo(
            bounds: bounds,
            originShift: originShift,
            totalPoints: UInt64(totalPoints),
            maxDepth: maxDepth,
            pointsPerBatch: ChunkPacker.defaultPointsPerBatch,
            bytesPerPoint: 17
        )

        let queue = UpdateQueue()
        let jobs = JobQueue()
        let handleBox = SendableCopcHandle(raw: handle)
        let driver = StreamingDriver(
            handle: handleBox,
            nodes: nodes,
            originShift: originShift,
            options: options,
            queue: queue,
            jobs: jobs
        )

        let workerCount = max(1, options.decodeConcurrency)
        let source = CopcStreamingPointCloudSource(
            info: info,
            driver: driver,
            queue: queue,
            jobs: jobs,
            handle: handleBox,
            originShift: originShift,
            workerCount: workerCount
        )
        source.startDriver()
        return source
    }

    private func startDriver() {
        let driver = self.driver
        let tickInterval = driver.tickInterval
        driverTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await driver.runOneTick()
                try? await Task.sleep(for: tickInterval)
            }
        }

        let jobs = self.jobs
        let handleBox = self.handleBox
        let originShift = self.originShift
        let workers = (0..<workerCount).map { slot in
            Task.detached(priority: .utility) {
                let slotIndex = Int32(slot)
                while !Task.isCancelled {
                    guard let id = await jobs.pop() else { break }
                    let chunk = StreamingDriver.decodeAndPack(
                        handle: handleBox.raw,
                        slot: slotIndex,
                        id: id,
                        originShift: originShift
                    )
                    await driver.completeLoad(id: id, chunk: chunk)
                }
            }
        }
        workerTasks = workers
    }

    public func submit(view: StreamingCameraView) {
        Task { await driver.setView(view) }
    }

    public func setBudget(_ bytes: Int) {
        Task { await driver.setBudget(bytes) }
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
        driverTask?.cancel()
        let jobs = self.jobs
        let workers = self.workerTasks
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

    /// Test-only diagnostic snapshot of the driver's last tick.
    public func _debugSnapshot() async -> (candidates: Int, wanted: Int, resident: Int, inFlight: Int,
                                           cacheHits: Int, cacheMisses: Int) {
        await driver.snapshot()
    }
}

// MARK: - Driver actor

/// `@unchecked Sendable` wrapper for the opaque COPC handle so it can be
/// captured by concurrent decode tasks. Safe because:
///   1. The handle is read-only after open (hierarchy/header are
///      immutable).
///   2. Each concurrent caller targets a distinct `slot` in the reader
///      pool, so per-reader `fstream` state is never shared.
struct SendableCopcHandle: @unchecked Sendable {
    let raw: copc_handle
}

actor StreamingDriver {
    private let handleBox: SendableCopcHandle
    private var handle: copc_handle { handleBox.raw }
    private let nodes: [NodeMeta]
    private let nodeIndexByID: [ChunkID: Int]
    private let allNodeIDs: Set<ChunkID>
    private let totalNodeBytes: Int
    private let originShift: SIMD3<Double>
    private let options: StreamingOptions
    private let queue: UpdateQueue
    private let jobs: JobQueue
    let tickInterval: Duration

    private var latestView: StreamingCameraView?
    private var budgetBytes: Int = .max

    private struct ResidentEntry {
        var chunk: ResidentChunk
        var ticksSinceWanted: Int
    }
    private var resident: [ChunkID: ResidentEntry] = [:]
    private var inFlight: Set<ChunkID> = []
    private var closed = false

    // Wanted-set cache. `wanted` depends only on the camera view, the
    // budget, and the immutable node hierarchy — eviction and in-flight
    // residency state don't change it. Caching avoids the O(nodes)
    // frustum scan + sort on every tick when the camera and budget are
    // unchanged (static frames, idle periods).
    private var cachedView: StreamingCameraView?
    private var cachedBudget: Int = .min
    private var cachedWanted: Set<ChunkID> = []
    private var cachedCandidates: Int = 0

    init(
        handle: SendableCopcHandle,
        nodes: [NodeMeta],
        originShift: SIMD3<Double>,
        options: StreamingOptions,
        queue: UpdateQueue,
        jobs: JobQueue
    ) {
        self.handleBox = handle
        self.nodes = nodes
        self.nodeIndexByID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        self.allNodeIDs = Set(nodes.lazy.map(\.id))
        self.totalNodeBytes = nodes.reduce(0) { $0 + $1.pointCount * 17 }
        self.originShift = originShift
        self.options = options
        self.queue = queue
        self.jobs = jobs
        self.tickInterval = options.driverTickInterval
    }

    func setView(_ v: StreamingCameraView) { latestView = v }
    func setBudget(_ b: Int) { budgetBytes = b }

    func cancel(_ ids: [ChunkID]) {
        let set = Set(ids)
        for id in ids { inFlight.remove(id) }
        jobs.remove(set)
    }

    func shutdown() {
        if closed { return }
        closed = true
        swiftpdal_copc_close(handle)
        resident.removeAll()
        inFlight.removeAll()
    }

    /// Called by a worker task once a chunk has been decoded.
    ///
    /// Decoupled from the tick loop: a slow decode no longer stalls
    /// subsequent ticks. Cancelled or evicted chunks (those removed
    /// from `inFlight` after being scheduled) are dropped here.
    func completeLoad(id: ChunkID, chunk: ResidentChunk?) {
        if closed { return }
        let wasInFlight = inFlight.remove(id) != nil
        guard wasInFlight, let chunk else { return }
        resident[id] = ResidentEntry(chunk: chunk, ticksSinceWanted: 0)
        queue.enqueue(added: [chunk], removed: [])
    }

    /// Diagnostic counts for tests. Reset on each tick.
    private(set) var lastTickCandidates: Int = 0
    private(set) var lastTickWanted: Int = 0
    private(set) var lastTickResident: Int = 0
    private(set) var lastTickInFlight: Int = 0
    /// Cumulative wanted-set cache hits / misses since driver start.
    private(set) var wantedCacheHits: Int = 0
    private(set) var wantedCacheMisses: Int = 0

    func snapshot() -> (candidates: Int, wanted: Int, resident: Int, inFlight: Int,
                        cacheHits: Int, cacheMisses: Int) {
        (lastTickCandidates, lastTickWanted, lastTickResident, lastTickInFlight,
         wantedCacheHits, wantedCacheMisses)
    }

    func runOneTick() {
        if closed { return }
        guard let view = latestView else { return }

        // 1. Score nodes against the camera + budget — cached when the
        //    (view, budget) pair is unchanged from the previous tick.
        let wanted: Set<ChunkID>
        if let cv = cachedView, cv == view, cachedBudget == budgetBytes {
            wanted = cachedWanted
            lastTickCandidates = cachedCandidates
            wantedCacheHits &+= 1
        } else {
            wanted = computeWantedSet(view: view, budget: budgetBytes)
            cachedView = view
            cachedBudget = budgetBytes
            cachedWanted = wanted
            cachedCandidates = lastTickCandidates
            wantedCacheMisses &+= 1
        }
        lastTickWanted = wanted.count
        lastTickResident = resident.count
        lastTickInFlight = inFlight.count

        var tickRemoved: [ChunkID] = []

        // 2. Evict (with hysteresis).
        for (id, var entry) in resident {
            if wanted.contains(id) {
                entry.ticksSinceWanted = 0
                resident[id] = entry
            } else {
                entry.ticksSinceWanted += 1
                if entry.ticksSinceWanted >= options.evictionDelayTicks {
                    tickRemoved.append(id)
                    resident.removeValue(forKey: id)
                } else {
                    resident[id] = entry
                }
            }
        }

        if !tickRemoved.isEmpty {
            queue.enqueue(added: [], removed: tickRemoved)
        }

        // 3. Enqueue new decode jobs for wanted-not-resident-not-in-flight,
        //    capped at maxInFlightLoads per tick. Persistent worker tasks
        //    owned by ``CopcStreamingPointCloudSource`` consume the queue;
        //    completed chunks publish to ``UpdateQueue`` from
        //    ``completeLoad(id:chunk:)`` continuously, so a slow decode
        //    does not stall subsequent ticks.
        let needed = wanted.subtracting(resident.keys).subtracting(inFlight)
        let toLoad = Array(needed.prefix(options.maxInFlightLoads))
        if toLoad.isEmpty { return }
        for id in toLoad { inFlight.insert(id) }
        jobs.enqueue(toLoad)
    }

    private func computeWantedSet(view: StreamingCameraView, budget: Int) -> Set<ChunkID> {
        // Whole-file shortcut: if every node fits in the budget, every
        // node is wanted. Skips the frustum scan and sort entirely.
        if totalNodeBytes <= budget {
            lastTickCandidates = nodes.count
            return allNodeIDs
        }

        struct Scored { let id: ChunkID; let score: Float; let bytes: Int }
        var visible: [Scored] = []
        var hidden: [Scored] = []
        visible.reserveCapacity(nodes.count)

        switch options.residencyPolicy {
        case .distanceOnly:
            // No frustum gate — everything is a candidate.
            for node in nodes {
                let d = simd_length(node.center - view.position) + 1e-3
                visible.append(Scored(id: node.id, score: 1 / d, bytes: node.pointCount * 17))
            }
        case .frustumFirstThenHalo:
            let planes = FrustumPlanes(viewProjection: view.viewProjection)
            for node in nodes {
                let d = simd_length(node.center - view.position) + 1e-3
                let s = Scored(id: node.id, score: 1 / d, bytes: node.pointCount * 17)
                if planes.intersects(min: node.minXYZ, max: node.maxXYZ) {
                    visible.append(s)
                } else {
                    hidden.append(s)
                }
            }
        }
        lastTickCandidates = visible.count + hidden.count

        // Pass 1: nearest visible chunks fill the budget.
        visible.sort { $0.score > $1.score }
        var wanted = Set<ChunkID>()
        var used = 0
        for c in visible {
            if used + c.bytes > budget { continue }
            wanted.insert(c.id)
            used += c.bytes
        }

        // Pass 2 (halo): fill remaining headroom from nearest non-visible
        // chunks. Only reachable under .frustumFirstThenHalo; under
        // .distanceOnly the hidden array is empty.
        if !hidden.isEmpty && used < budget {
            hidden.sort { $0.score > $1.score }
            for c in hidden {
                if used + c.bytes > budget { continue }
                wanted.insert(c.id)
                used += c.bytes
            }
        }

        return wanted
    }

    /// Decode + pack a single COPC node into a render-ready chunk.
    ///
    /// `nonisolated` and `static` so it can run on a cooperative thread
    /// outside the actor. Thread-safety is achieved by giving every
    /// concurrent caller a distinct `slot` into the file reader pool
    /// established in ``CopcStreamingPointCloudSource/open(_:options:)``.
    nonisolated static func decodeAndPack(
        handle: copc_handle,
        slot: Int32,
        id: ChunkID,
        originShift: SIMD3<Double>
    ) -> ResidentChunk? {
        var data = copc_chunk_data()
        let rc = swiftpdal_copc_read_node(
            handle,
            Int32(id.depth), Int32(id.x), Int32(id.y), Int32(id.z),
            slot,
            &data
        )
        guard rc == 0, data.point_count > 0, let xyz = data.xyz, let rgb = data.rgb else {
            if data.xyz != nil || data.rgb != nil { swiftpdal_copc_free_chunk(&data) }
            return nil
        }
        defer { swiftpdal_copc_free_chunk(&data) }

        let packed = ChunkPacker.pack(
            positionsXYZ: xyz,
            rgb16: rgb,
            count: Int(data.point_count),
            hasRgb: data.has_rgb != 0,
            originShift: originShift
        )

        return ResidentChunk(
            id: id,
            batches: packed.batches,
            xyzLow: packed.xyzLow,
            xyzMed: packed.xyzMed,
            xyzHigh: packed.xyzHigh,
            colors: packed.colors,
            levels: packed.levels
        )
    }
}

// MARK: - Frustum

/// 6-plane frustum extracted from a view-projection matrix (Gribb-Hartmann).
struct FrustumPlanes: Sendable {
    let planes: [SIMD4<Float>]  // ax + by + cz + d >= 0 means "inside"

    init(viewProjection m: simd_float4x4) {
        // simd_float4x4 is column-major; rows are .columns[col][row].
        // Reconstruct rows:
        let r0 = SIMD4<Float>(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        let r1 = SIMD4<Float>(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        let r2 = SIMD4<Float>(m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z)
        let r3 = SIMD4<Float>(m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)

        planes = [
            r3 + r0, r3 - r0,   // left, right
            r3 + r1, r3 - r1,   // bottom, top
            r3 + r2, r3 - r2,   // near, far
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
