import Foundation
import simd

/// Packs a decoded COPC node into the renderer's bit-packed buffers.
///
/// Mirrors `PackedPointCloudFixtures.pack` in Satin-ComputeRasteriser:
/// Morton-orders the input, splits into render batches of `pointsPerBatch`,
/// quantizes each batch's positions into 30-bit-per-axis fixed-point against
/// the per-batch AABB, and assigns per-point LOD levels via density-aware
/// voxel occupancy (the per-chunk local variant — global accuracy requires
/// a sidecar; see `docs/streaming.md`).
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

    /// Pack a single COPC node's worth of points.
    /// - Parameters:
    ///   - positionsXYZ: count * 3 doubles, world-space
    ///   - rgb16: count * 3 uint16, LAS-convention 16-bit color (may be all-zero)
    ///   - count: point count
    ///   - hasRgb: whether `rgb16` is meaningful (else white is used)
    ///   - originShift: subtract from positions before quantizing (file-bounds-center)
    ///   - pointsPerBatch: renderer batch size; default 10240
    ///   - lodLevels: 1..8
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
        coarseVoxelDivisions: Int = defaultCoarseVoxelDivisions
    ) -> Output {
        precondition(count > 0)

        var positions = [SIMD3<Float>](repeating: .zero, count: count)
        for i in 0..<count {
            let dx = positionsXYZ[3*i+0] - originShift.x
            let dy = positionsXYZ[3*i+1] - originShift.y
            let dz = positionsXYZ[3*i+2] - originShift.z
            positions[i] = SIMD3<Float>(Float(dx), Float(dy), Float(dz))
        }

        var boundsMin = SIMD3<Float>(repeating:  .greatestFiniteMagnitude)
        var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in positions {
            boundsMin = simd_min(boundsMin, p)
            boundsMax = simd_max(boundsMax, p)
        }

        let order = mortonOrder(positions: positions, boundsMin: boundsMin, boundsMax: boundsMax)
        let sortedPositions = order.map { positions[$0] }

        let levels = computeLODLevels(
            positions: sortedPositions,
            boundsMin: boundsMin,
            boundsMax: boundsMax,
            lodLevels: max(1, min(lodLevels, 8)),
            coarseVoxelDivisions: max(1, coarseVoxelDivisions)
        )

        var batches: [StreamingRasterBatch] = []
        var xyzLow  = [UInt32](repeating: 0, count: count)
        var xyzMed  = [UInt32](repeating: 0, count: count)
        var xyzHigh = [UInt32](repeating: 0, count: count)

        let batchSize = max(pointsPerBatch, 1)
        var first = 0
        while first < count {
            let end = min(first + batchSize, count)
            var batchMin = SIMD3<Float>(repeating:  .greatestFiniteMagnitude)
            var batchMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for i in first..<end {
                batchMin = simd_min(batchMin, sortedPositions[i])
                batchMax = simd_max(batchMax, sortedPositions[i])
            }
            let size = simd_max(batchMax - batchMin, SIMD3<Float>(repeating: 1e-6))
            let stepsMinusOne = Float(steps30Bit - 1)

            for i in first..<end {
                let n = simd_clamp(
                    (sortedPositions[i] - batchMin) / size,
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

                xyzLow[i]  = xL | (yL << 10) | (zL << 20)
                xyzMed[i]  = xM | (yM << 10) | (zM << 20)
                xyzHigh[i] = xH | (yH << 10) | (zH << 20)
            }

            batches.append(StreamingRasterBatch(
                state: 1,
                min: batchMin,
                max: batchMax,
                numPoints: UInt32(end - first),
                firstPoint: UInt32(first),
                fileIndex: 0
            ))
            first = end
        }

        // Pack colors. LAS RGB is 16-bit per channel; rescale to 8-bit.
        // No alpha channel in COPC, so set A = 255.
        var colors = [UInt32](repeating: 0, count: count)
        if hasRgb {
            // 8-bit-vs-16-bit RGB rescale. Prefer a GLOBAL shift decided once for
            // the whole file (passed in via `rgbShiftBits`): deciding it per node
            // mis-classifies uniformly-dark nodes — every channel ≤ 255 in a true
            // 16-bit file — as "8-bit", emitting their tiny values un-shifted and
            // rendering them oversaturated (square patches of wrong colour). Fall
            // back to the per-node heuristic only when no global shift was supplied.
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
            for (dstIndex, srcIndex) in order.enumerated() {
                let r = UInt32(rgb16[3*srcIndex+0]) >> shift
                let g = UInt32(rgb16[3*srcIndex+1]) >> shift
                let b = UInt32(rgb16[3*srcIndex+2]) >> shift
                colors[dstIndex] = (r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16) | (UInt32(255) << 24)
            }
        } else {
            for i in 0..<count { colors[i] = 0xFFFFFFFF }
        }

        // Permute requested extra scalars into Morton order (dim-major input:
        // extra[d*count + srcIndex]) so each dim lines up with the packed
        // positions/colors. Each output blob is `count` Float32.
        var extraScalars: [String: Data] = [:]
        if let extra, extraCount > 0, extraCount == extraNames.count {
            for (d, name) in extraNames.enumerated() {
                let base = d * count
                var col = [Float](repeating: 0, count: count)
                for (dstIndex, srcIndex) in order.enumerated() {
                    col[dstIndex] = extra[base + srcIndex]
                }
                extraScalars[name] = packedData(col)
            }
        }

        return Output(
            batches: batches,
            xyzLow:  packedData(xyzLow),
            xyzMed:  packedData(xyzMed),
            xyzHigh: packedData(xyzHigh),
            colors:  packedData(colors),
            levels:  Data(levels),
            extraScalars: extraScalars
        )
    }
}

// Copy a Swift array into `Data` with an explicit buffer-pointer scope.
// Passing an array straight to `Data(buffer: UnsafeBufferPointer(start:count:))`
// trips Swift 6's [#TemporaryPointers] warning — the implicit array→pointer
// conversion yields a pointer valid only for that one call. `Data(buffer:)`
// copies synchronously so it's safe in practice, but the explicit scope is the
// correct, warning-free idiom.
@inline(__always)
private func packedData<T>(_ array: [T]) -> Data {
    array.withUnsafeBufferPointer { Data(buffer: $0) }
}

// Morton-order so consecutive entries are spatially close — gives tight
// per-batch AABBs and better cache coherency for threadgroup reads in the
// rasterizer.
private func mortonOrder(
    positions: [SIMD3<Float>],
    boundsMin: SIMD3<Float>,
    boundsMax: SIMD3<Float>
) -> [Int] {
    let count = positions.count
    let extent = simd_max(boundsMax - boundsMin, SIMD3<Float>(repeating: 1e-6))
    let scale = SIMD3<Float>(repeating: 1023.0) / extent

    var keys = [UInt32](repeating: 0, count: count)
    for i in 0..<count {
        let nrm = simd_clamp((positions[i] - boundsMin) * scale, .zero, SIMD3<Float>(repeating: 1023.0))
        let qx = UInt32(nrm.x), qy = UInt32(nrm.y), qz = UInt32(nrm.z)
        keys[i] = (mortonSpread10(qx) << 2) | (mortonSpread10(qy) << 1) | mortonSpread10(qz)
    }
    var indices = Array(0..<count)
    indices.sort { keys[$0] < keys[$1] }
    return indices
}

private func computeLODLevels(
    positions: [SIMD3<Float>],
    boundsMin: SIMD3<Float>,
    boundsMax: SIMD3<Float>,
    lodLevels: Int,
    coarseVoxelDivisions: Int
) -> [UInt8] {
    let count = positions.count
    let maxLevel = UInt8(lodLevels - 1)
    var levels = [UInt8](repeating: maxLevel, count: count)
    guard lodLevels > 1 else { return levels }

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

    var occupied = Set<UInt64>()
    for level in 0..<(lodLevels - 1) {
        let voxelSize = baseVoxel * powf(0.5, Float(level))
        let invVoxel = 1.0 / max(voxelSize, 1e-6)
        occupied.removeAll(keepingCapacity: true)
        for i in 0..<count {
            if levels[i] != maxLevel { continue }
            let local = (positions[i] - boundsMin) * invVoxel
            if occupied.insert(cellKey(local)).inserted {
                levels[i] = UInt8(level)
            }
        }
    }
    return levels
}

private func mortonSpread10(_ value: UInt32) -> UInt32 {
    var x = value & 0x3ff
    x = (x | (x << 16)) & 0x030000ff
    x = (x | (x << 8))  & 0x0300f00f
    x = (x | (x << 4))  & 0x030c30c3
    x = (x | (x << 2))  & 0x09249249
    return x
}
