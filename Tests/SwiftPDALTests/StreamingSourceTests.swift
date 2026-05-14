import Testing
import Foundation
import simd
@testable import SwiftPDAL

private func loadFixture() -> URL? {
    guard let path = Bundle.module.path(forResource: "test.copc", ofType: "laz") else {
        return nil
    }
    return URL(fileURLWithPath: path)
}

// Build a VP matrix that views the whole bounds from above. For the spike
// it's enough that the resulting frustum contains the file's AABB.
private func wideViewMatrix(for bounds: Bounds, originShift: SIMD3<Double>) -> (SIMD3<Float>, simd_float4x4) {
    let centerWorld = (bounds.min + bounds.max) * 0.5
    let center = SIMD3<Float>(
        centerWorld.x - Float(originShift.x),
        centerWorld.y - Float(originShift.y),
        centerWorld.z - Float(originShift.z)
    )
    let span = simd_length(bounds.max - bounds.min)
    let eye = center + SIMD3<Float>(0, 0, span)

    // Look-at with up = +Y
    let f = simd_normalize(center - eye)
    let s = simd_normalize(simd_cross(f, SIMD3<Float>(0, 1, 0)))
    let u = simd_cross(s, f)
    let view = simd_float4x4(
        SIMD4<Float>( s.x,  u.x, -f.x, 0),
        SIMD4<Float>( s.y,  u.y, -f.y, 0),
        SIMD4<Float>( s.z,  u.z, -f.z, 0),
        SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye),  simd_dot(f, eye), 1)
    )
    // Generous perspective covering the scene
    let fov: Float = .pi / 2  // 90°
    let aspect: Float = 1
    let near: Float = 1
    let far  = span * 4
    let yScale = 1 / tan(fov * 0.5)
    let zRange = far - near
    let proj = simd_float4x4(
        SIMD4<Float>(yScale / aspect, 0,      0,                  0),
        SIMD4<Float>(0,               yScale, 0,                  0),
        SIMD4<Float>(0,               0,     -(far + near)/zRange, -1),
        SIMD4<Float>(0,               0,     -2*far*near/zRange,  0)
    )
    return (eye, proj * view)
}

@Test func streamingSource_residencyFillsFile() async throws {
    guard let url = loadFixture() else {
        Issue.record("test.copc.laz fixture missing")
        return
    }

    let options = StreamingOptions(
        maxInFlightLoads: 4,
        lodMode: .perChunk,
        prefetchRoot: false,
        evictionDelayTicks: 100,           // disable eviction for this test
        driverTickInterval: .milliseconds(10)
    )
    let source = try await CopcStreamingPointCloudSource.open(url, options: options)
    defer { source.close() }

    #expect(source.info.totalPoints > 0)
    #expect(source.info.maxDepth >= 1)

    let (eye, vp) = wideViewMatrix(for: source.info.bounds, originShift: source.info.originShift)
    source.setBudget(Int.max)
    source.submit(view: StreamingCameraView(position: eye, viewProjection: vp, pixelScale: 1000))

    // Drain incrementally; exit when the driver's resident count reaches
    // the full node set (or timeout). Don't rely on poll-cadence-vs-tick
    // timing — use the driver snapshot as the source of truth.
    var totalResidentPoints = 0
    var distinctChunks = Set<ChunkID>()
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
        if let update = source.pollLatest() {
            for chunk in update.added {
                #expect(chunk.batches.count >= 1)
                #expect(chunk.totalPointCount > 0)
                #expect(chunk.xyzLow.count  == chunk.totalPointCount * 4)
                #expect(chunk.xyzMed.count  == chunk.totalPointCount * 4)
                #expect(chunk.xyzHigh.count == chunk.totalPointCount * 4)
                #expect(chunk.colors.count  == chunk.totalPointCount * 4)
                #expect(chunk.levels.count  == chunk.totalPointCount)
                var cursor = 0
                for b in chunk.batches {
                    #expect(Int(b.firstPoint) == cursor)
                    cursor += Int(b.numPoints)
                }
                #expect(cursor == chunk.totalPointCount)
                if distinctChunks.insert(chunk.id).inserted {
                    totalResidentPoints += chunk.totalPointCount
                }
            }
        }
        let snap = await source._debugSnapshot()
        if snap.resident == snap.wanted && snap.inFlight == 0 && snap.wanted > 0 {
            // Give one more poll for the queue to drain the final batch.
            try await Task.sleep(for: .milliseconds(60))
            if let update = source.pollLatest() {
                for chunk in update.added where distinctChunks.insert(chunk.id).inserted {
                    totalResidentPoints += chunk.totalPointCount
                }
            }
            break
        }
    }

    let snap = await source._debugSnapshot()
    print("--- streaming residency ---")
    print("totalPoints in file: \(source.info.totalPoints)")
    print("resident chunks: \(distinctChunks.count)")
    print("resident points: \(totalResidentPoints)")
    print("originShift: \(source.info.originShift)")
    print("last tick: candidates=\(snap.candidates) wanted=\(snap.wanted) resident=\(snap.resident) inFlight=\(snap.inFlight)")

    // With infinite budget + camera covering whole scene, residency should
    // converge to the full point set.
    #expect(distinctChunks.count > 0)
    #expect(totalResidentPoints == Int(source.info.totalPoints))
}

@Test func streamingSource_evictsWhenCameraLeaves() async throws {
    guard let url = loadFixture() else {
        Issue.record("test.copc.laz fixture missing")
        return
    }

    let options = StreamingOptions(
        maxInFlightLoads: 4,
        lodMode: .perChunk,
        prefetchRoot: false,
        evictionDelayTicks: 2,
        driverTickInterval: .milliseconds(10)
    )
    let source = try await CopcStreamingPointCloudSource.open(url, options: options)
    defer { source.close() }

    // Phase 1: camera covers the scene; let chunks become resident.
    let (eye1, vp1) = wideViewMatrix(for: source.info.bounds, originShift: source.info.originShift)
    source.setBudget(Int.max)
    source.submit(view: StreamingCameraView(position: eye1, viewProjection: vp1, pixelScale: 1000))

    var residentCount = 0
    let phase1Deadline = Date().addingTimeInterval(10)
    while Date() < phase1Deadline {
        try await Task.sleep(for: .milliseconds(50))
        if let u = source.pollLatest() {
            residentCount += u.added.count
            residentCount -= u.removed.count
        }
        if residentCount >= 5 { break }
    }
    #expect(residentCount > 0, "phase 1 should have loaded chunks")

    // Phase 2: move camera far away looking the other direction so the
    // frustum no longer intersects any node AABB.
    let farEye = SIMD3<Float>(1e6, 1e6, 1e6)
    let lookAway = simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))  // identity, won't capture origin
    source.submit(view: StreamingCameraView(position: farEye, viewProjection: lookAway, pixelScale: 1000))

    var removed = 0
    let phase2Deadline = Date().addingTimeInterval(5)
    while Date() < phase2Deadline {
        try await Task.sleep(for: .milliseconds(50))
        if let u = source.pollLatest() {
            removed += u.removed.count
        }
        if removed >= residentCount { break }
    }

    print("--- streaming eviction ---")
    print("phase1 resident: \(residentCount), phase2 removed: \(removed)")
    #expect(removed > 0, "phase 2 should evict at least some chunks")
}
