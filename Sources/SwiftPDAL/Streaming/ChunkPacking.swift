import Foundation
import simd

/// Packs a decoded COPC node into the renderer's bit-packed buffers.
///
/// Mirrors `PackedPointCloudFixtures.pack` in Satin-ComputeRasteriser:
/// Morton-orders the input, splits into render batches of `pointsPerBatch`,
/// quantizes each batch's positions into 30-bit-per-axis fixed-point against
/// the per-batch AABB, and assigns per-point LOD levels via density-aware
/// voxel occupancy (the per-chunk local variant — global accuracy requires
/// a sidecar; see `docs/streaming.md`). Each batch slice is then stored
/// level-ascending (stable within a level, preserving Morton order per
/// bucket) with cumulative level counts packed into
/// `StreamingRasterBatch.padding3...padding6` so the renderer can bound its
/// draw loops to the LOD prefix.
///
/// Renderer-side constants (kept in sync with `ComputeRasteriserTypes.swift`):
/// - `steps30Bit  = 1 << 30 = 1_073_741_824`
/// - `mask10Bit   = (1 << 10) - 1 = 1023`
/// - `pointsPerBatch` baseline = `128 * 80 = 10_240`
enum ChunkPacker {
    static let steps30Bit: UInt32 = 1 << 30
    static let mask10Bit: UInt32  = (1 << 10) - 1
    static let defaultPointsPerBatch: Int = 128 * 80
    static let defaultLODLevels: Int = 4
    static let defaultCoarseVoxelDivisions: Int = 64

    struct Output {
        var batches: [StreamingRasterBatch]
        var xyzLow: Data
        var xyzMed: Data
        var xyzHigh: Data
        var colors: Data
        var levels: Data
        /// Optional per-point scalar dimensions (Float32), Morton-reordered to
        /// match the packed positions/colors. Keyed by dimension name. Empty
        /// unless extra dims were requested.
        var extraScalars: [String: Data] = [:]
    }

    /// Per-worker reusable scratch for ``pack(positionsXYZ:rgb16:count:hasRgb:originShift:extra:extraCount:extraNames:rgbShiftBits:pointsPerBatch:lodLevels:coarseVoxelDivisions:workspace:)``.
    ///
    /// The pack pipeline builds ~`count`-sized temporaries — Morton keys, the
    /// LSD-radix ping-pong buffers, the reordered positions, the LOD
    /// open-addressing table (the largest, `≥ 2·count` `UInt64`), and the
    /// per-batch bucket-sort scratch. Allocating and zero-filling all of that
    /// afresh on every chunk (~2.5 MB for a 24k-point node) was serializing the
    /// decode workers on the allocator lock and saturating memory bandwidth
    /// once several ran at once. A worker holds one `Workspace` and passes it to
    /// every ``pack`` call, so the buffers are allocated once and only ever
    /// grow — never freed between chunks. The buffers hold no state across
    /// calls; each ``pack`` fully overwrites the prefix it uses.
    ///
    /// Not thread-safe: exactly one worker task may use a given instance at a
    /// time (matching the one-slot-per-thread decode contract). Passing `nil`
    /// (the default) makes ``pack`` allocate a throwaway `Workspace`, so the
    /// output is identical whether or not one is supplied.
    final class Workspace {
        var positions:  [SIMD3<Float>] = []
        var ordered:    [SIMD3<Float>] = []
        var keys:       [UInt32] = []
        var order:      [Int] = []
        var radix:      [Int] = []
        var offsets     = [Int](repeating: 0, count: 1024)
        var levels:     [UInt8] = []
        var table:      [UInt64] = []
        var permOrder:  [Int] = []
        var permPos:    [SIMD3<Float>] = []
        var permLvl:    [UInt8] = []

        public init() {}

        /// Grow `array` to at least `n` elements (never shrinks). Only the
        /// `[0..<n]` prefix is ever read/written by ``pack``, so a larger tail
        /// left by a bigger prior chunk is harmless.
        @inline(__always)
        static func grow<T>(_ array: inout [T], to n: Int, fill: T) {
            if array.count < n { array.append(contentsOf: repeatElement(fill, count: n - array.count)) }
        }
    }

    /// Pack a single COPC node's worth of points.
    /// - Parameters:
    ///   - positionsXYZ: count * 3 doubles, world-space
    ///   - rgb16: count * 3 uint16, LAS-convention 16-bit color (may be all-zero)
    ///   - count: point count
    ///   - hasRgb: whether `rgb16` is meaningful (else white is used)
    ///   - originShift: subtract from positions before quantizing (file-bounds-center)
    ///   - pointsPerBatch: renderer batch size; default 10240
    ///   - lodLevels: 1..8
    ///   - workspace: optional per-worker reusable scratch (see ``Workspace``).
    ///     Pass `nil` (default) to allocate throwaway scratch — output is
    ///     identical either way.
    static func pack(
        positionsXYZ: UnsafePointer<Double>,
        rgb16: UnsafePointer<UInt16>,
        count: Int,
        hasRgb: Bool,
        originShift: SIMD3<Double>,
        extra: UnsafePointer<Float>? = nil,
        extraCount: Int = 0,
        extraNames: [String] = [],
        rgbShiftBits: UInt32? = nil,
        pointsPerBatch: Int = defaultPointsPerBatch,
        lodLevels: Int = defaultLODLevels,
        coarseVoxelDivisions: Int = defaultCoarseVoxelDivisions,
        workspace: Workspace? = nil
    ) -> Output {
        precondition(count > 0)
        let ws = workspace ?? Workspace()

        Workspace.grow(&ws.positions, to: count, fill: .zero)
        ws.positions.withUnsafeMutableBufferPointer { p in
            for i in 0..<count {
                let dx = positionsXYZ[3*i+0] - originShift.x
                let dy = positionsXYZ[3*i+1] - originShift.y
                let dz = positionsXYZ[3*i+2] - originShift.z
                p[i] = SIMD3<Float>(Float(dx), Float(dy), Float(dz))
            }
        }

        var boundsMin = SIMD3<Float>(repeating:  .greatestFiniteMagnitude)
        var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        ws.positions.withUnsafeBufferPointer { p in
            for i in 0..<count {
                boundsMin = simd_min(boundsMin, p[i])
                boundsMax = simd_max(boundsMax, p[i])
            }
        }

        // Morton order → `ws.order[0..<count]` (reuses ws.keys / ws.radix /
        // ws.offsets).
        mortonOrder(
            into: ws, count: count, boundsMin: boundsMin, boundsMax: boundsMax)

        // Materialize the positions in Morton order exactly once. Both the LOD
        // pass (which greedily assigns levels while walking points in Morton
        // order — see `computeLODLevels`) and the per-batch quantize pass below
        // consume this ordering; keeping one contiguous copy lets those passes
        // stream sequentially instead of chasing `order` indirectly through the
        // source `positions` several times (a cache pessimization that grows
        // with node size). This is the single reorder; the quantize/colors/extra
        // passes fuse their reorder into the write, so no other temporary is
        // built.
        Workspace.grow(&ws.ordered, to: count, fill: .zero)
        ws.positions.withUnsafeBufferPointer { src in
            ws.order.withUnsafeBufferPointer { ord in
                ws.ordered.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<count { dst[i] = src[ord[i]] }
                }
            }
        }

        // LOD levels → `ws.levels[0..<count]` (reuses ws.table).
        computeLODLevels(
            into: ws, count: count,
            boundsMin: boundsMin, boundsMax: boundsMax,
            lodLevels: max(1, min(lodLevels, 8)),
            coarseVoxelDivisions: max(1, coarseVoxelDivisions)
        )

        // Bucket each batch slice level-ascending (stable, so Morton order is
        // preserved within a level) and compose the permutation into `order`,
        // so the colors and extraScalars gathers below — both of which walk
        // `order` — reorder every sidecar consistently. The renderer's cull
        // pass uses the per-batch cumulative counts (padding3..6) to bound
        // its draw loops to the LOD prefix.
        let batchSize = max(pointsPerBatch, 1)
        precondition(batchSize <= 65535, "pointsPerBatch must fit the uint16 LOD prefix counts")
        bucketSortBatchSlicesByLevel(into: ws, count: count, batchStride: batchSize)

        // Allocate the packed position buffers at their final size and quantize
        // straight into them — one traversal, no intermediate [UInt32] arrays or
        // per-array `Data` copies. Each point is quantized against its batch's
        // AABB, so batches are still built by walking the Morton-ordered points
        // in `pointsPerBatch`-sized runs.
        var batches: [StreamingRasterBatch] = []
        var xyzLow  = Data(count: count * MemoryLayout<UInt32>.stride)
        var xyzMed  = Data(count: count * MemoryLayout<UInt32>.stride)
        var xyzHigh = Data(count: count * MemoryLayout<UInt32>.stride)

        let stepsMinusOne = Float(steps30Bit - 1)

        ws.ordered.withUnsafeBufferPointer { pos in
        ws.levels.withUnsafeBufferPointer { levels in
            xyzLow.withUnsafeMutableBytes { lowRaw in
                xyzMed.withUnsafeMutableBytes { medRaw in
                    xyzHigh.withUnsafeMutableBytes { highRaw in
                        let low  = lowRaw.bindMemory(to: UInt32.self)
                        let med  = medRaw.bindMemory(to: UInt32.self)
                        let high = highRaw.bindMemory(to: UInt32.self)

                        var first = 0
                        while first < count {
                            let end = min(first + batchSize, count)

                            // Per-batch AABB over the Morton-ordered slice (kept
                            // hot in cache for the quantize sub-pass below).
                            var batchMin = SIMD3<Float>(repeating:  .greatestFiniteMagnitude)
                            var batchMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                            for i in first..<end {
                                batchMin = simd_min(batchMin, pos[i])
                                batchMax = simd_max(batchMax, pos[i])
                            }
                            let size = simd_max(batchMax - batchMin, SIMD3<Float>(repeating: 1e-6))

                            for i in first..<end {
                                let n = simd_clamp(
                                    (pos[i] - batchMin) / size,
                                    .zero, SIMD3<Float>(repeating: 0.99999994)
                                )
                                let qx = UInt32(n.x * stepsMinusOne)
                                let qy = UInt32(n.y * stepsMinusOne)
                                let qz = UInt32(n.z * stepsMinusOne)

                                let xL = (qx >> 20) & mask10Bit
                                let yL = (qy >> 20) & mask10Bit
                                let zL = (qz >> 20) & mask10Bit
                                let xM = (qx >> 10) & mask10Bit
                                let yM = (qy >> 10) & mask10Bit
                                let zM = (qz >> 10) & mask10Bit
                                let xH =  qx        & mask10Bit
                                let yH =  qy        & mask10Bit
                                let zH =  qz        & mask10Bit

                                low[i]  = xL | (yL << 10) | (zL << 20)
                                med[i]  = xM | (yM << 10) | (zM << 20)
                                high[i] = xH | (yH << 10) | (zH << 20)
                            }

                            var batch = StreamingRasterBatch(
                                state: 1,
                                min: batchMin,
                                max: batchMax,
                                numPoints: UInt32(end - first),
                                firstPoint: UInt32(first),
                                fileIndex: 0
                            )
                            // Cumulative LOD counts over the (level-sorted)
                            // slice: cum[L] = points with level <= L, packed
                            // two uint16 per padding word. cum[7] == numPoints
                            // > 0, so padding6 != 0 distinguishes bucketed
                            // batches from legacy ones.
                            var cumulative = [Int](repeating: 0, count: 8)
                            for i in first..<end {
                                cumulative[Int(levels[i]) & 7] += 1
                            }
                            for level in 1..<8 {
                                cumulative[level] += cumulative[level - 1]
                            }
                            batch.padding3 = UInt32(cumulative[0]) | (UInt32(cumulative[1]) << 16)
                            batch.padding4 = UInt32(cumulative[2]) | (UInt32(cumulative[3]) << 16)
                            batch.padding5 = UInt32(cumulative[4]) | (UInt32(cumulative[5]) << 16)
                            batch.padding6 = UInt32(cumulative[6]) | (UInt32(cumulative[7]) << 16)
                            batches.append(batch)
                            first = end
                        }
                    }
                }
            }
        }
        }

        // Pack colors straight into the output `Data`. LAS RGB is 16-bit per
        // channel; rescale to 8-bit. No alpha channel in COPC, so set A = 255.
        var colors = Data(count: count * MemoryLayout<UInt32>.stride)
        colors.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt32.self)
            if hasRgb {
                // 8-bit-vs-16-bit RGB rescale. Prefer a GLOBAL shift decided once
                // for the whole file (passed in via `rgbShiftBits`): deciding it
                // per node mis-classifies uniformly-dark nodes — every channel
                // ≤ 255 in a true 16-bit file — as "8-bit", emitting their tiny
                // values un-shifted and rendering them oversaturated (square
                // patches of wrong colour). Fall back to the per-node heuristic
                // only when no global shift was supplied.
                let shift: UInt32
                if let rgbShiftBits {
                    shift = rgbShiftBits
                } else {
                    var maxVal: UInt16 = 0
                    for i in 0..<count {
                        let r = rgb16[3*i+0], g = rgb16[3*i+1], b = rgb16[3*i+2]
                        if r > maxVal { maxVal = r }
                        if g > maxVal { maxVal = g }
                        if b > maxVal { maxVal = b }
                    }
                    shift = maxVal > 255 ? 8 : 0
                }
                ws.order.withUnsafeBufferPointer { order in
                    for dstIndex in 0..<count {
                        let srcIndex = order[dstIndex]
                        let r = UInt32(rgb16[3*srcIndex+0]) >> shift
                        let g = UInt32(rgb16[3*srcIndex+1]) >> shift
                        let b = UInt32(rgb16[3*srcIndex+2]) >> shift
                        dst[dstIndex] = (r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16) | (UInt32(255) << 24)
                    }
                }
            } else {
                for i in 0..<count { dst[i] = 0xFFFFFFFF }
            }
        }

        // Permute requested extra scalars into Morton order (dim-major input:
        // extra[d*count + srcIndex]) so each dim lines up with the packed
        // positions/colors. Each output blob is `count` Float32, written
        // straight into its `Data`.
        var extraScalars: [String: Data] = [:]
        if let extra, extraCount > 0, extraCount == extraNames.count {
            ws.order.withUnsafeBufferPointer { order in
                for (d, name) in extraNames.enumerated() {
                    let base = d * count
                    var colData = Data(count: count * MemoryLayout<Float>.stride)
                    colData.withUnsafeMutableBytes { raw in
                        let col = raw.bindMemory(to: Float.self)
                        for dstIndex in 0..<count {
                            col[dstIndex] = extra[base + order[dstIndex]]
                        }
                    }
                    extraScalars[name] = colData
                }
            }
        }

        // The output `levels` blob is the level-sorted per-point levels; copy
        // just the used prefix out of the (possibly larger) reusable buffer.
        let levelsData = ws.levels.withUnsafeBufferPointer { Data(buffer: UnsafeBufferPointer(rebasing: $0[0..<count])) }

        return Output(
            batches: batches,
            xyzLow:  xyzLow,
            xyzMed:  xyzMed,
            xyzHigh: xyzHigh,
            colors:  colors,
            levels:  levelsData,
            extraScalars: extraScalars
        )
    }
}

// Stable per-batch-slice 8-bucket counting sort by LOD level: within each
// [first, first+batchStride) slice, points are reordered level-ascending while
// preserving Morton order inside each level. The identical permutation is
// applied to `order` so every array derived from it stays consistent with the
// permuted positions/levels. Mirrors `bucketSortBatchSlicesByLevel` in
// Satin-ComputeRasteriser's PackedPointCloudFixtures.
//
// Operates in place on `ws.order` / `ws.ordered` / `ws.levels` (`[0..<count]`),
// reusing `ws.permOrder` / `ws.permPos` / `ws.permLvl` for the per-slice
// scratch.
private func bucketSortBatchSlicesByLevel(
    into ws: ChunkPacker.Workspace,
    count: Int,
    batchStride: Int
) {
    ChunkPacker.Workspace.grow(&ws.permOrder, to: batchStride, fill: 0)
    ChunkPacker.Workspace.grow(&ws.permPos, to: batchStride, fill: .zero)
    ChunkPacker.Workspace.grow(&ws.permLvl, to: batchStride, fill: 0)

    // Bind every workspace buffer to a local unsafe pointer for the hot loops:
    // subscripting a class-stored `Array` (`ws.order[i]`) in a loop pays ARC +
    // exclusivity overhead per access that a raw pointer avoids.
    ws.order.withUnsafeMutableBufferPointer { order in
    ws.ordered.withUnsafeMutableBufferPointer { ordered in
    ws.levels.withUnsafeMutableBufferPointer { levels in
    ws.permOrder.withUnsafeMutableBufferPointer { permOrder in
    ws.permPos.withUnsafeMutableBufferPointer { permPos in
    ws.permLvl.withUnsafeMutableBufferPointer { permLvl in
        var first = 0
        while first < count {
            let end = min(first + batchStride, count)
            let sliceLen = end - first

            var cursors = [Int](repeating: 0, count: 9)
            for i in first..<end {
                cursors[(Int(levels[i]) & 7) + 1] += 1
            }
            for level in 1..<9 {
                cursors[level] += cursors[level - 1]
            }

            // Build the level-ascending permutation of the slice into the
            // reusable scratch, sourcing from the current order/positions/
            // levels, then write it back over the slice.
            for i in first..<end {
                let level = Int(levels[i]) & 7
                let j = cursors[level]
                permOrder[j] = order[i]
                permPos[j]   = ordered[i]
                permLvl[j]   = levels[i]
                cursors[level] += 1
            }
            for j in 0..<sliceLen {
                order[first + j]   = permOrder[j]
                ordered[first + j] = permPos[j]
                levels[first + j]  = permLvl[j]
            }

            first = end
        }
    }}}}}}
}

// Morton-order so consecutive entries are spatially close — gives tight
// per-batch AABBs and better cache coherency for threadgroup reads in the
// rasterizer. Writes the ascending index permutation into `ws.order[0..<count]`,
// reusing `ws.keys` for the Morton keys and `ws.radix` / `ws.offsets` for the
// LSD radix sort.
private func mortonOrder(
    into ws: ChunkPacker.Workspace,
    count: Int,
    boundsMin: SIMD3<Float>,
    boundsMax: SIMD3<Float>
) {
    let extent = simd_max(boundsMax - boundsMin, SIMD3<Float>(repeating: 1e-6))
    let scale = SIMD3<Float>(repeating: 1023.0) / extent

    ChunkPacker.Workspace.grow(&ws.keys, to: count, fill: 0)
    ws.positions.withUnsafeBufferPointer { pos in
        ws.keys.withUnsafeMutableBufferPointer { keys in
            for i in 0..<count {
                let nrm = simd_clamp((pos[i] - boundsMin) * scale, .zero, SIMD3<Float>(repeating: 1023.0))
                let qx = UInt32(nrm.x), qy = UInt32(nrm.y), qz = UInt32(nrm.z)
                keys[i] = (mortonSpread10(qx) << 2) | (mortonSpread10(qy) << 1) | mortonSpread10(qz)
            }
        }
    }
    lsdRadixSortIndices(into: ws, count: count)
}

// Stable LSD radix sort writing the ascending index permutation of
// `ws.keys[0..<count]` into `ws.order[0..<count]`. Morton keys are 30-bit, so
// three 10-bit passes (a 1024-bucket counting sort each, ping-ponging the index
// buffers `ws.order` / `ws.radix`) cover every bit and yield exactly the
// ascending order the previous `indices.sort { keys[$0] < keys[$1] }` produced.
// This replaces that O(P log P) comparison sort — the dominant per-chunk pack
// cost on the decode workers — with O(P) work.
//
// Radix is stable: points sharing a Morton key (i.e. the same coarse voxel)
// keep their input order, whereas the old introsort left them in an arbitrary
// order. That tie ordering is not semantically meaningful, so the packed
// output is unchanged apart from how equal-key points are interleaved.
private func lsdRadixSortIndices(into ws: ChunkPacker.Workspace, count: Int) {
    ChunkPacker.Workspace.grow(&ws.order, to: count, fill: 0)
    ChunkPacker.Workspace.grow(&ws.radix, to: count, fill: 0)

    // Identity into ws.order first — this is the result for the count<=1 early
    // return, and is overwritten by the sort otherwise.
    ws.order.withUnsafeMutableBufferPointer { a in
        for i in 0..<count { a[i] = i }
    }
    guard count > 1 else { return }

    // The sort ping-pongs between ws.radix (initial `src`, seeded identity) and
    // ws.order (initial `dst`). With three passes (odd), the final scatter
    // writes into ws.order, so the sorted permutation lands there — exactly
    // where the rest of `pack` reads it — with no extra copy.
    ws.radix.withUnsafeMutableBufferPointer { r in
        for i in 0..<count { r[i] = i }
    }
    ws.keys.withUnsafeBufferPointer { key in
    ws.offsets.withUnsafeMutableBufferPointer { off in
    ws.radix.withUnsafeMutableBufferPointer { bufSrc in
    ws.order.withUnsafeMutableBufferPointer { bufDst in
        var src = bufSrc.baseAddress!
        var dst = bufDst.baseAddress!
        for pass in 0..<3 {
            let shift = UInt32(pass * 10)

            // Count how many indices fall in each 10-bit bucket.
            for j in 0..<1024 { off[j] = 0 }
            for i in 0..<count {
                off[Int((key[src[i]] >> shift) & 1023)] += 1
            }

            // Exclusive prefix sum → each bucket's starting write offset.
            var running = 0
            for j in 0..<1024 {
                let c = off[j]
                off[j] = running
                running += c
            }

            // Stable scatter: walking `src` in order keeps equal keys in their
            // current relative order.
            for i in 0..<count {
                let idx = src[i]
                let bucket = Int((key[idx] >> shift) & 1023)
                dst[off[bucket]] = idx
                off[bucket] += 1
            }
            swap(&src, &dst)
        }
        // Three swaps: pass 0/2 write ws.order, pass 1 writes ws.radix, so the
        // final result is in ws.order.
    }}}}
}

// Assigns per-point LOD levels into `ws.levels[0..<count]` (from the
// Morton-ordered `ws.ordered`), reusing `ws.table` as the open-addressing
// occupancy set.
private func computeLODLevels(
    into ws: ChunkPacker.Workspace,
    count: Int,
    boundsMin: SIMD3<Float>,
    boundsMax: SIMD3<Float>,
    lodLevels: Int,
    coarseVoxelDivisions: Int
) {
    let maxLevel = UInt8(lodLevels - 1)
    ChunkPacker.Workspace.grow(&ws.levels, to: count, fill: 0)
    ws.levels.withUnsafeMutableBufferPointer { lv in
        for i in 0..<count { lv[i] = maxLevel }
    }
    guard lodLevels > 1 else { return }

    let extent = simd_max(boundsMax - boundsMin, SIMD3<Float>(repeating: 1e-6))
    let longestAxis = max(extent.x, max(extent.y, extent.z))
    let baseVoxel = longestAxis / Float(coarseVoxelDivisions)

    // Voxel-occupancy dedup keyed by a single UInt64 instead of SIMD3<Int32>.
    // Hashing one integer is far cheaper than Swift's per-component Hasher
    // combine over a SIMD3 (the original showed up as Set.insert / Hasher in
    // the streaming-decode CPU profile). Cell components are non-negative
    // (positions ≥ boundsMin) and node-local, comfortably under 21 bits even
    // at the deepest level / largest division count, so the 21-bit-per-axis
    // pack is collision-free over the values that actually occur.
    @inline(__always)
    func cellKey(_ local: SIMD3<Float>) -> UInt64 {
        let cx = UInt64(max(0, Int32(local.x.rounded(.down)))) & 0x1F_FFFF
        let cy = UInt64(max(0, Int32(local.y.rounded(.down)))) & 0x1F_FFFF
        let cz = UInt64(max(0, Int32(local.z.rounded(.down)))) & 0x1F_FFFF
        return (cx << 42) | (cy << 21) | cz
    }

    // Open-addressing hash set of occupied voxel keys, replacing Swift's
    // `Set<UInt64>` — whose SipHash + CoW/uniqueness machinery dominated the
    // streaming-decode CPU profile (~12.5% of total process CPU: Hasher._hash,
    // _Variant.insert, isUniquelyReferenced). One `[UInt64]` table, sized once
    // for the whole call and reused across levels, with Fibonacci hashing and
    // linear probing in an unsafe buffer (no bounds/uniqueness checks in the
    // probe). Mirrors `computeLODLevels` in Satin-ComputeRasteriser's
    // PackedPointCloudFixtures — keep the two in sync.
    //
    // Sentinel is `UInt64.max`: cellKey packs 21 bits/axis into bits 0..62, so
    // bit 63 is always 0 and a real key can never equal the sentinel.
    //
    // Capacity = next power of two ≥ 2·count (load factor ≤ 0.5). Sizing by the
    // total count — not by per-level unclaimed counts — is deliberate: the
    // eligible set shrinks with depth but the number of distinct occupied
    // voxels (the actual live entries) grows, and `count` bounds both at every
    // level, so one allocation stays under 0.5 load throughout. The table is
    // reused across chunks via the workspace; only the `[0..<capacity]` prefix
    // is touched, so a larger tail from a bigger prior chunk is inert.
    let sentinel = UInt64.max
    var capacity = 1
    while capacity < count * 2 { capacity <<= 1 }
    let mask = capacity - 1
    let shift = UInt64(64 - capacity.trailingZeroBitCount)

    ChunkPacker.Workspace.grow(&ws.table, to: capacity, fill: sentinel)
    ws.levels.withUnsafeMutableBufferPointer { lv in
        ws.ordered.withUnsafeBufferPointer { pos in
            ws.table.withUnsafeMutableBufferPointer { t in
                for level in 0..<(lodLevels - 1) {
                    let voxelSize = baseVoxel * powf(0.5, Float(level))
                    let invVoxel = 1.0 / max(voxelSize, 1e-6)
                    // Refill the sentinel over the used prefix at the start of
                    // every level (level 0 included, because the table is
                    // reused across chunks and may carry a prior chunk's keys).
                    for j in 0..<capacity { t[j] = sentinel }
                    for i in 0..<count {
                        if lv[i] != maxLevel { continue }
                        let local = (pos[i] - boundsMin) * invVoxel
                        let key = cellKey(local)
                        var slot = Int((key &* 0x9E37_79B9_7F4A_7C15) >> shift)
                        while true {
                            let cur = t[slot]
                            if cur == sentinel {
                                t[slot] = key
                                lv[i] = UInt8(level)
                                break
                            }
                            if cur == key { break }
                            slot = (slot + 1) & mask
                        }
                    }
                }
            }
        }
    }
}

private func mortonSpread10(_ value: UInt32) -> UInt32 {
    var x = value & 0x3ff
    x = (x | (x << 16)) & 0x030000ff
    x = (x | (x << 8))  & 0x0300f00f
    x = (x | (x << 4))  & 0x030c30c3
    x = (x | (x << 2))  & 0x09249249
    return x
}
