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

// Eye at a corner of the bounds looking outward through a narrow FOV
// — engineered so the frustum excludes most of the file's AABB. Used
// to exercise the halo / distance-only paths.
private func narrowCornerView(for bounds: Bounds, originShift: SIMD3<Double>) -> (SIMD3<Float>, simd_float4x4) {
    let centerWorld = (bounds.min + bounds.max) * 0.5
    let center = SIMD3<Float>(
        centerWorld.x - Float(originShift.x),
        centerWorld.y - Float(originShift.y),
        centerWorld.z - Float(originShift.z)
    )
    let span = simd_length(bounds.max - bounds.min)
    // Eye far outside the scene, looking back toward center but with a
    // tight FOV so most off-axis chunks fall outside the frustum.
    let eye = center + SIMD3<Float>(span * 3, 0, 0)
    let f = simd_normalize(center - eye)
    let s = simd_normalize(simd_cross(f, SIMD3<Float>(0, 1, 0)))
    let u = simd_cross(s, f)
    let view = simd_float4x4(
        SIMD4<Float>( s.x,  u.x, -f.x, 0),
        SIMD4<Float>( s.y,  u.y, -f.y, 0),
        SIMD4<Float>( s.z,  u.z, -f.z, 0),
        SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye),  simd_dot(f, eye), 1)
    )
    let fov: Float = .pi / 36   // 5°
    let aspect: Float = 1
    let near: Float = 1
    let far = span * 8
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

/// Wait until `predicate(snapshot)` is true or `timeout` elapses.
/// Drains poll updates in the loop so the driver isn't blocked by a
/// full UpdateQueue.
private func waitForSnapshot(
    on source: CopcStreamingPointCloudSource,
    timeout: TimeInterval = 5,
    predicate: (StreamingDebugSnapshot) -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
        _ = source.pollLatest()
        let snap = await source._debugSnapshot()
        if predicate(snap) { return }
    }
}

@Test func streamingSource_wholeFileMode_engagesWhenBudgetExceedsFile() async throws {
    guard let url = loadFixture() else {
        Issue.record("test.copc.laz fixture missing")
        return
    }
    let source = try await CopcStreamingPointCloudSource.open(url, options: .init(
        prefetchRoot: false,
        evictionDelayTicks: 100,
        driverTickInterval: .milliseconds(10)
    ))
    defer { source.close() }

    // Pick any view — the whole-file shortcut should ignore the frustum.
    let (eye, vp) = narrowCornerView(for: source.info.bounds, originShift: source.info.originShift)
    source.setBudget(Int.max)
    source.submit(view: StreamingCameraView(position: eye, viewProjection: vp, pixelScale: 1000))

    await waitForSnapshot(on: source) { $0.wanted == $0.totalNodes && $0.totalNodes > 0 }
    let snap = await source._debugSnapshot()
    #expect(snap.totalNodes > 0)
    #expect(snap.wanted == snap.totalNodes,
            "whole-file mode should mark every node wanted regardless of frustum")
    #expect(snap.frustumVisible == 0,
            "whole-file shortcut should skip the frustum scan (frustumVisible=0)")
}

@Test func streamingSource_halo_fillsBudgetBeyondFrustumVisible() async throws {
    guard let url = loadFixture() else {
        Issue.record("test.copc.laz fixture missing")
        return
    }
    let source = try await CopcStreamingPointCloudSource.open(url, options: .init(
        prefetchRoot: false,
        evictionDelayTicks: 100,
        driverTickInterval: .milliseconds(10),
        residencyPolicy: .frustumFirstThenHalo
    ))
    defer { source.close() }

    // Narrow corner view → some nodes outside the frustum.
    // Budget must be smaller than totalBytes (otherwise the whole-file
    // shortcut bypasses the policy) but larger than the frustum-visible
    // bytes (so headroom exists for halo to fill).
    let (eye, vp) = narrowCornerView(for: source.info.bounds, originShift: source.info.originShift)
    source.setBudget(30 * 1_048_576)   // 30 MB; fixture is ~36 MB packed
    source.submit(view: StreamingCameraView(position: eye, viewProjection: vp, pixelScale: 1000))

    await waitForSnapshot(on: source) { $0.cacheMisses > 0 && $0.wanted > 0 }
    let snap = await source._debugSnapshot()
    #expect(snap.frustumVisible > 0, "narrow view should admit some chunks via the frustum")
    #expect(snap.frustumVisible < snap.totalNodes,
            "narrow view should exclude some chunks from the frustum")
    #expect(snap.wanted > snap.frustumVisible,
            "halo pass should fill remaining budget with non-frustum chunks (wanted=\(snap.wanted) frustumVisible=\(snap.frustumVisible))")
}

@Test func streamingSource_distanceOnly_takesNoFrustumPath() async throws {
    guard let url = loadFixture() else {
        Issue.record("test.copc.laz fixture missing")
        return
    }
    let source = try await CopcStreamingPointCloudSource.open(url, options: .init(
        prefetchRoot: false,
        evictionDelayTicks: 100,
        driverTickInterval: .milliseconds(10),
        residencyPolicy: .distanceOnly
    ))
    defer { source.close() }

    let (eye, vp) = narrowCornerView(for: source.info.bounds, originShift: source.info.originShift)
    source.setBudget(20 * 1_048_576)   // same as halo test, to keep paths comparable
    source.submit(view: StreamingCameraView(position: eye, viewProjection: vp, pixelScale: 1000))

    await waitForSnapshot(on: source) { $0.cacheMisses > 0 && $0.wanted > 0 }
    let snap = await source._debugSnapshot()
    #expect(snap.wanted > 0)
    // `frustumVisible` is only populated under .frustumFirstThenHalo;
    // distanceOnly should never set it.
    #expect(snap.frustumVisible == 0,
            "distanceOnly mode should not compute a frustum-visible count")
    // Every node is a candidate (no frustum cull) but only a budget-
    // capped subset is wanted.
    #expect(snap.candidates == snap.totalNodes,
            "distanceOnly should treat every node as a candidate (candidates=\(snap.candidates) totalNodes=\(snap.totalNodes))")
}

@Test func streamingSource_wantedSet_stableAcrossTicksWhenViewUnchanged() async throws {
    guard let url = loadFixture() else {
        Issue.record("test.copc.laz fixture missing")
        return
    }
    let source = try await CopcStreamingPointCloudSource.open(url, options: .init(
        prefetchRoot: false,
        evictionDelayTicks: 100,
        driverTickInterval: .milliseconds(10)
    ))
    defer { source.close() }

    let (eye, vp) = narrowCornerView(for: source.info.bounds, originShift: source.info.originShift)
    source.setBudget(20 * 1_048_576)
    source.submit(view: StreamingCameraView(position: eye, viewProjection: vp, pixelScale: 1000))

    // Wait for the first computeWantedSet call.
    await waitForSnapshot(on: source) { $0.cacheMisses > 0 }
    let firstWanted = (await source._debugSnapshot()).wanted

    // Wait for additional ticks. The view hasn't changed, so every
    // subsequent tick should be a cache hit and `wanted` shouldn't drift.
    let startMisses = (await source._debugSnapshot()).cacheMisses
    try await Task.sleep(for: .milliseconds(500))
    let snap = await source._debugSnapshot()
    #expect(snap.cacheHits > 0, "static view should produce cache hits")
    #expect(snap.cacheMisses == startMisses,
            "no new misses expected while view+budget are unchanged (start=\(startMisses) now=\(snap.cacheMisses))")
    #expect(snap.wanted == firstWanted,
            "wanted-set count should be stable across cache hits (first=\(firstWanted) later=\(snap.wanted))")
}

// Eye placed near a corner of the scene (close enough that fine-depth
// chunks project near the target screen size). Companion to
// `narrowCornerView` which sits far away.
private func nearCornerView(for bounds: Bounds, originShift: SIMD3<Double>) -> (SIMD3<Float>, simd_float4x4) {
    let centerWorld = (bounds.min + bounds.max) * 0.5
    let center = SIMD3<Float>(
        centerWorld.x - Float(originShift.x),
        centerWorld.y - Float(originShift.y),
        centerWorld.z - Float(originShift.z)
    )
    let span = simd_length(bounds.max - bounds.min)
    // Eye just outside one corner — fine-depth chunks here project to
    // ~target screen size, coarse chunks are over-detailed.
    let corner = SIMD3<Float>(
        bounds.min.x - Float(originShift.x),
        bounds.min.y - Float(originShift.y),
        bounds.min.z - Float(originShift.z)
    )
    let eye = corner + SIMD3<Float>(-span * 0.02, -span * 0.02, span * 0.02)
    let f = simd_normalize(center - eye)
    let s = simd_normalize(simd_cross(f, SIMD3<Float>(0, 1, 0)))
    let u = simd_cross(s, f)
    let view = simd_float4x4(
        SIMD4<Float>( s.x,  u.x, -f.x, 0),
        SIMD4<Float>( s.y,  u.y, -f.y, 0),
        SIMD4<Float>( s.z,  u.z, -f.z, 0),
        SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye),  simd_dot(f, eye), 1)
    )
    let fov: Float = .pi / 3   // 60°
    let aspect: Float = 1
    let near: Float = max(span * 0.001, 0.01)
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

@Test func streamingSource_lodScorer_admitsCoarseRootWhenCameraIsFar() async throws {
    guard let url = loadFixture() else {
        Issue.record("test.copc.laz fixture missing")
        return
    }
    let source = try await CopcStreamingPointCloudSource.open(url, options: .init(
        prefetchRoot: false,
        evictionDelayTicks: 100,
        driverTickInterval: .milliseconds(10),
        residencyPolicy: .frustumFirstThenHalo,
        targetChunkScreenSize: 256
    ))
    defer { source.close() }

    let (eye, vp) = narrowCornerView(for: source.info.bounds, originShift: source.info.originShift)
    source.setBudget(8 * 1_048_576)
    source.submit(view: StreamingCameraView(position: eye, viewProjection: vp, pixelScale: 1000))

    await waitForSnapshot(on: source) { $0.cacheMisses > 0 && $0.wanted > 0 }
    let snap = await source._debugSnapshot()
    #expect(snap.wantedByDepth[0] >= 1,
            "with the camera far from the data, the depth-0 root should be wanted for coverage")
    let coarseWanted = snap.wantedByDepth.prefix(3).reduce(0, +)
    let deepWanted = snap.wantedByDepth.dropFirst(3).reduce(0, +)
    #expect(coarseWanted > deepWanted,
            "far camera should bias the wanted set toward coarse depths (coarse=\(coarseWanted) deep=\(deepWanted))")
}

@Test func streamingSource_lodScorer_admitsFineDetailWhenCameraIsNear() async throws {
    guard let url = loadFixture() else {
        Issue.record("test.copc.laz fixture missing")
        return
    }
    let source = try await CopcStreamingPointCloudSource.open(url, options: .init(
        prefetchRoot: false,
        evictionDelayTicks: 100,
        driverTickInterval: .milliseconds(10),
        residencyPolicy: .frustumFirstThenHalo,
        targetChunkScreenSize: 256
    ))
    defer { source.close() }

    let (eye, vp) = nearCornerView(for: source.info.bounds, originShift: source.info.originShift)
    source.setBudget(8 * 1_048_576)
    source.submit(view: StreamingCameraView(position: eye, viewProjection: vp, pixelScale: 1000))

    await waitForSnapshot(on: source) { $0.cacheMisses > 0 && $0.wanted > 0 }
    let snap = await source._debugSnapshot()
    let deepWanted = snap.wantedByDepth.dropFirst(snap.wantedByDepth.count / 2).reduce(0, +)
    #expect(deepWanted >= 1,
            "near camera should pull at least one deep-depth chunk into the wanted set (wantedByDepth=\(snap.wantedByDepth))")
}

// Diagnostic: dump the residency depth distribution under a narrow
// camera + tight budget. Always passes; the print output is the value.
// Run via:
//   swift test --filter streamingSource_depthDistribution
@Test func streamingSource_depthDistribution_diagnostic() async throws {
    guard let url = loadFixture() else {
        Issue.record("test.copc.laz fixture missing")
        return
    }
    let source = try await CopcStreamingPointCloudSource.open(url, options: .init(
        maxInFlightLoads: 16,
        decodeConcurrency: 4,
        prefetchRoot: false,
        evictionDelayTicks: 100,
        driverTickInterval: .milliseconds(10),
        residencyPolicy: .frustumFirstThenHalo
    ))
    defer { source.close() }

    let (eye, vp) = narrowCornerView(for: source.info.bounds, originShift: source.info.originShift)
    source.setBudget(8 * 1_048_576)   // 8 MB — tight enough to force selection on a 36 MB fixture
    source.submit(view: StreamingCameraView(position: eye, viewProjection: vp, pixelScale: 1000))

    // Let residency converge on the wanted set.
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
        _ = source.pollLatest()
        let snap = await source._debugSnapshot()
        if snap.resident == snap.wanted && snap.inFlight == 0 && snap.wanted > 0 { break }
    }

    let snap = await source._debugSnapshot()
    print("--- depth distribution diagnostic ---")
    print("totalNodes:     \(snap.totalNodes) (maxDepth=\(snap.residentByDepth.count - 1))")
    print("frustumVisible: \(snap.frustumVisible)")
    print("wanted:         \(snap.wanted)")
    print("resident:       \(snap.resident)")
    for d in 0..<snap.residentByDepth.count {
        let total = snap.totalNodes
        let r = snap.residentByDepth[d]
        let w = snap.wantedByDepth[d]
        print(String(format: "  depth %d: resident=%-4d wanted=%-4d (of %d total)", d, r, w, total))
    }
    #expect(snap.resident > 0)
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
    // Budget intentionally < total file bytes — otherwise the whole-file
    // shortcut admits every node and nothing can ever be evicted on
    // camera move.
    let (eye1, vp1) = wideViewMatrix(for: source.info.bounds, originShift: source.info.originShift)
    source.setBudget(2 * 1_048_576)   // 2 MB; fixture is ~36 MB packed
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
