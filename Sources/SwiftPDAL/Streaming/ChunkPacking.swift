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
            // Detect 8-bit-stored-as-16-bit (common): if max(channel) <= 255, no shift.
            var maxVal: UInt16 = 0
            for i in 0..<count {
                let r = rgb16[3*i+0], g = rgb16[3*i+1], b = rgb16[3*i+2]
                if r > maxVal { maxVal = r }
                if g > maxVal { maxVal = g }
                if b > maxVal { maxVal = b }
            }
            let shift: UInt32 = maxVal > 255 ? 8 : 0
            for (dstIndex, srcIndex) in order.enumerated() {
                let r = UInt32(rgb16[3*srcIndex+0]) >> shift
                let g = UInt32(rgb16[3*srcIndex+1]) >> shift
                let b = UInt32(rgb16[3*srcIndex+2]) >> shift
                colors[dstIndex] = (r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16) | (UInt32(255) << 24)
            }
        } else {
            for i in 0..<count { colors[i] = 0xFFFFFFFF }
        }

        return Output(
            batches: batches,
            xyzLow:  Data(buffer: UnsafeBufferPointer(start: xyzLow,  count: count)),
            xyzMed:  Data(buffer: UnsafeBufferPointer(start: xyzMed,  count: count)),
            xyzHigh: Data(buffer: UnsafeBufferPointer(start: xyzHigh, count: count)),
            colors:  Data(buffer: UnsafeBufferPointer(start: colors,  count: count)),
            levels:  Data(levels)
        )
    }
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

    var occupied: Set<SIMD3<Int32>> = []
    for level in 0..<(lodLevels - 1) {
        let voxelSize = baseVoxel * powf(0.5, Float(level))
        let invVoxel = 1.0 / max(voxelSize, 1e-6)
        occupied.removeAll(keepingCapacity: true)
        for i in 0..<count {
            if levels[i] != maxLevel { continue }
            let local = (positions[i] - boundsMin) * invVoxel
            let cell = SIMD3<Int32>(
                Int32(local.x.rounded(.down)),
                Int32(local.y.rounded(.down)),
                Int32(local.z.rounded(.down))
            )
            if occupied.insert(cell).inserted {
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
