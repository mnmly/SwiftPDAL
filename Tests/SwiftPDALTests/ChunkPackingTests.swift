import Testing
import Foundation
import simd
@testable import SwiftPDAL

// Deterministic LCG so the synthetic chunk is reproducible across runs.
private struct LCG {
    var state: UInt64
    mutating func unitDouble() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) * (1.0 / Double(UInt64(1) << 53))
    }
}

@Test func chunkPacker_bucketsBatchSlicesByLODLevelWithPrefixCounts() {
    let count = 3000
    let pointsPerBatch = 1024 // 3 batches: 1024 + 1024 + 952
    let boxExtent = 10.0
    let originShift = SIMD3<Double>(1000.5, -250.25, 42.0)

    var rng = LCG(state: 0x5EED_5EED)
    var local = [SIMD3<Float>]()
    local.reserveCapacity(count)
    var positionsXYZ = [Double](repeating: 0, count: count * 3)
    for i in 0..<count {
        let p = SIMD3<Double>(
            rng.unitDouble() * boxExtent,
            rng.unitDouble() * boxExtent,
            rng.unitDouble() * boxExtent
        )
        local.append(SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)))
        positionsXYZ[3 * i + 0] = p.x + originShift.x
        positionsXYZ[3 * i + 1] = p.y + originShift.y
        positionsXYZ[3 * i + 2] = p.z + originShift.z
    }

    let rgb16 = [UInt16](repeating: 0, count: count * 3)
    // Sidecar scalar = source point index; Float is exact for count < 2^24.
    let extra = (0..<count).map { Float($0) }

    let output = positionsXYZ.withUnsafeBufferPointer { pos in
        rgb16.withUnsafeBufferPointer { rgb in
            extra.withUnsafeBufferPointer { ext in
                ChunkPacker.pack(
                    positionsXYZ: pos.baseAddress!,
                    rgb16: rgb.baseAddress!,
                    count: count,
                    hasRgb: false,
                    originShift: originShift,
                    extra: ext.baseAddress!,
                    extraCount: 1,
                    extraNames: ["SourceIndex"],
                    pointsPerBatch: pointsPerBatch,
                    lodLevels: 4,
                    // Small division count so levels 0..3 all get populated
                    // in a 3000-point chunk (64^3 voxels would put every
                    // point at level 0).
                    coarseVoxelDivisions: 4
                )
            }
        }
    }

    #expect(output.batches.count >= 2, "fixture must span multiple batches")

    let levels = [UInt8](output.levels)
    #expect(levels.count == count)
    #expect(Set(levels).count >= 3, "fixture must populate several LOD levels")

    let scalars = output.extraScalars["SourceIndex"]!.withUnsafeBytes {
        Array($0.bindMemory(to: Float.self))
    }
    let low = output.xyzLow.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    let med = output.xyzMed.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    let high = output.xyzHigh.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    #expect(scalars.count == count)

    let stepsMinusOne = Float(ChunkPacker.steps30Bit - 1)
    var seenSources = Set<Int>()

    for (batchIndex, batch) in output.batches.enumerated() {
        let first = Int(batch.firstPoint)
        let end = first + Int(batch.numPoints)

        // Levels are non-decreasing within the batch slice.
        var orderViolations = 0
        for i in (first + 1)..<end where levels[i] < levels[i - 1] {
            orderViolations += 1
        }
        #expect(orderViolations == 0, "batch \(batchIndex): levels must be level-ascending")

        // Cumulative counts recounted from the slice match padding3..6.
        var cumulative = [Int](repeating: 0, count: 8)
        for i in first..<end {
            cumulative[Int(levels[i]) & 7] += 1
        }
        for level in 1..<8 {
            cumulative[level] += cumulative[level - 1]
        }
        let packedWords = [batch.padding3, batch.padding4, batch.padding5, batch.padding6]
        for level in 0..<8 {
            let word = packedWords[level / 2]
            let unpacked = Int((word >> (UInt32(level % 2) * 16)) & 0xFFFF)
            #expect(unpacked == cumulative[level],
                    "batch \(batchIndex): cum[\(level)] recount \(cumulative[level]) vs packed \(unpacked)")
        }
        #expect(cumulative[7] == Int(batch.numPoints),
                "batch \(batchIndex): cum[7] must equal numPoints")
        #expect(batch.padding6 != 0,
                "batch \(batchIndex): padding6 == 0 is the legacy sentinel and must not appear")

        // Sidecar alignment + post-reorder quantization: the scalar at i
        // names a source point whose (origin-shifted) position must match
        // the position decoded from the packed words against this batch's
        // AABB, within quantization tolerance.
        let batchMin = SIMD3<Float>(batch.minX, batch.minY, batch.minZ)
        let batchMax = SIMD3<Float>(batch.maxX, batch.maxY, batch.maxZ)
        let size = simd_max(batchMax - batchMin, SIMD3<Float>(repeating: 1e-6))
        var decodeMismatches = 0
        for i in first..<end {
            let src = Int(scalars[i])
            #expect(Float(src) == scalars[i] && src >= 0 && src < count,
                    "batch \(batchIndex): scalar at \(i) is not a valid source index")
            seenSources.insert(src)
            let qx = ((low[i] & 1023) << 20) | ((med[i] & 1023) << 10) | (high[i] & 1023)
            let qy = (((low[i] >> 10) & 1023) << 20) | (((med[i] >> 10) & 1023) << 10) | ((high[i] >> 10) & 1023)
            let qz = (((low[i] >> 20) & 1023) << 20) | (((med[i] >> 20) & 1023) << 10) | ((high[i] >> 20) & 1023)
            let decoded = batchMin + SIMD3<Float>(Float(qx), Float(qy), Float(qz)) / stepsMinusOne * size
            if simd_length(decoded - local[src]) >= 1e-3 {
                decodeMismatches += 1
            }
        }
        #expect(decodeMismatches == 0,
                "batch \(batchIndex): decoded positions must match the source points named by the scalar sidecar")
    }

    #expect(seenSources.count == count, "the pack must be a permutation of the input points")
}
