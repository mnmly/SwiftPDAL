import Testing
import Foundation
import simd
import CxxCOPC
import CxxStdlib
@testable import SwiftPDAL

// Unit tests for the three additive live-source APIs:
//   * `StreamingOptions.alwaysResidentDepth` — native coarse pinning (#2)
//   * `decodeStats()` / `DecodeStatsBox`      — decode-queue telemetry (#3)
//   * `setTargetChunkScreenSize(_:)`          — runtime scorer retarget (#4)
//
// Like the hierarchy-residency tests, these drive `StreamingDriver` against a
// synthetic octree (no decode pipeline). A COPC reader handle is required to
// construct the driver but never used by the logic under test.

// MARK: - Helpers

private func api_openReader() -> SendableCopcReader? {
    guard let path = Bundle.module.path(forResource: "test.copc", ofType: "laz"),
          let reader = swiftpdal.copc.Reader.open(std.string(path), 1)
    else { return nil }
    return SendableCopcReader(reader: reader)
}

private func api_node(
    _ id: ChunkID, points: Int, extent: Float, center: SIMD3<Float> = .zero
) -> NodeMeta {
    let half = SIMD3<Float>(repeating: extent * 0.5)
    return NodeMeta(
        id: id, pointCount: points,
        minXYZ: center - half, maxXYZ: center + half,
        center: center, extent: extent, offset: 0, byteSize: points * 8
    )
}

private func api_chunk(_ id: ChunkID, points: Int) -> ResidentChunk {
    let b = StreamingRasterBatch(
        state: 1, min: .zero, max: .zero,
        numPoints: UInt32(points), firstPoint: 0, fileIndex: 0
    )
    return ResidentChunk(
        id: id, batches: [b],
        xyzLow: Data(), xyzMed: Data(), xyzHigh: Data(),
        colors: Data(), levels: Data()
    )
}

// A root→leaf chain plus siblings so `totalNodeBytes` exceeds the test
// budgets (otherwise the whole-file shortcut bypasses the scorer). Distinct
// extents let the retarget test flip which depth the scorer prefers.
private let a_d0   = ChunkID(depth: 0, x: 0, y: 0, z: 0)
private let a_d1   = ChunkID(depth: 1, x: 0, y: 0, z: 0)
private let a_d1s  = ChunkID(depth: 1, x: 1, y: 0, z: 0)
private let a_d2   = ChunkID(depth: 2, x: 0, y: 0, z: 0)
private let a_leaf = ChunkID(depth: 3, x: 0, y: 0, z: 0)

private func api_chainNodes(points: Int = 100) -> [NodeMeta] {
    [
        api_node(a_d0, points: points, extent: 8),
        api_node(a_d1, points: points, extent: 4),
        api_node(a_d1s, points: points, extent: 4),
        api_node(a_d2, points: points, extent: 2),
        api_node(a_leaf, points: points, extent: 1),
        api_node(ChunkID(depth: 2, x: 2, y: 0, z: 0), points: points, extent: 2),
        api_node(ChunkID(depth: 3, x: 4, y: 0, z: 0), points: points, extent: 1.3),
        api_node(ChunkID(depth: 3, x: 5, y: 0, z: 0), points: points, extent: 1.3),
    ]
}

private func api_view() -> StreamingCameraView {
    StreamingCameraView(
        position: .zero, viewProjection: matrix_identity_float4x4,
        pixelScale: 1, depthTolerance: 1
    )
}

private func api_options(
    enforce: Bool = true,
    targetChunkScreenSize: Float = 1,
    alwaysResidentDepth: Int? = nil,
    evictionDelayTicks: Int = 100,
    maxInFlightLoads: Int = 100
) -> StreamingOptions {
    StreamingOptions(
        maxInFlightLoads: maxInFlightLoads,
        decodeConcurrency: 1,
        prefetchRoot: false,
        evictionDelayTicks: evictionDelayTicks,
        driverTickInterval: .milliseconds(10),
        residencyPolicy: .distanceOnly,
        targetChunkScreenSize: targetChunkScreenSize,
        enforceHierarchyResidency: enforce,
        alwaysResidentDepth: alwaysResidentDepth
    )
}

/// `pointsPerBatch` defaults to the synthetic node point count (100) so each
/// node costs exactly one GPU slot — slot budgets below therefore read
/// directly in "nodes", the way the old byte budgets read as multiples of a
/// node's 1700-byte footprint (8 nodes → 13600 bytes → 8 slots; the pinned
/// depth<=1 prefix of 3 nodes → 5100 bytes → 3 slots).
private func api_makeDriver(
    nodes: [NodeMeta], options: StreamingOptions, pointsPerBatch: Int = 100
) -> (StreamingDriver, UpdateQueue)? {
    guard let handle = api_openReader() else { return nil }
    let queue = UpdateQueue()
    let jobs = JobQueue()
    let driver = StreamingDriver(
        handle: handle, nodes: nodes, originShift: .zero,
        options: options, queue: queue, jobs: jobs,
        budgetBytesPerPoint: 17, pointsPerBatch: pointsPerBatch, isRemote: false
    )
    return (driver, queue)
}

// MARK: - #2 Native coarse pinning

@Test func pinning_resolvesDepthPrefix_andAlwaysWanted() async throws {
    guard let (driver, _) = api_makeDriver(
        nodes: api_chainNodes(), options: api_options(alwaysResidentDepth: 1)
    ) else { Issue.record("fixture reader unavailable"); return }

    // depth<=1 → root + both depth-1 nodes.
    let pinned = await driver._pinnedIDsForTest
    #expect(pinned == Set([a_d0, a_d1, a_d1s]),
            "alwaysResidentDepth=1 should pin exactly the depth<=1 nodes (got \(pinned))")

    // Budget below the whole-file total (8 slots) but comfortably above the
    // pinned set (3 slots): the scorer runs, and every pinned node is wanted
    // regardless of what the scorer picks. 6 slots leaves 3 for scored fill.
    let w = await driver._wantedSetForTest(view: api_view(), budget: 6)
    #expect(pinned.isSubset(of: w.set), "pinned nodes must always be wanted")
    // Pinned nodes are scheduled coarse-first (before any scored node).
    let firstThree = Set(w.ordered.prefix(3))
    #expect(firstThree == pinned, "pinned nodes should lead the load order (got \(w.ordered))")
}

@Test func pinning_clampsScoredToZero_whenPinnedMeetsOrExceedsBudget() async throws {
    guard let (driver, _) = api_makeDriver(
        nodes: api_chainNodes(), options: api_options(alwaysResidentDepth: 1)
    ) else { Issue.record("fixture reader unavailable"); return }
    let pinned = await driver._pinnedIDsForTest   // 3 nodes → 3 slots

    // Budget smaller than the pinned footprint (2 < 3 slots): pins are still
    // all wanted (honored regardless of budget), and no scored node is admitted.
    let tiny = await driver._wantedSetForTest(view: api_view(), budget: 2)
    #expect(tiny.set == pinned,
            "with pinned > budget, wanted must be exactly the pinned set (got \(tiny.set))")

    // Budget exactly the pinned footprint (3 slots): same result (no headroom).
    let exact = await driver._wantedSetForTest(view: api_view(), budget: 3)
    #expect(exact.set == pinned,
            "with pinned == budget, scored residency clamps to zero (got \(exact.set))")
}

@Test func pinning_neverEvicted_norRescheduled_atZeroBudget() async throws {
    guard let (driver, queue) = api_makeDriver(
        nodes: api_chainNodes(),
        options: api_options(alwaysResidentDepth: 1, evictionDelayTicks: 1)
    ) else { Issue.record("fixture reader unavailable"); return }
    let pinned = await driver._pinnedIDsForTest

    // Make the chain resident: schedule, then complete loads root-first.
    await driver.setView(api_view())
    await driver.setBudget(slots: 6)   // pinned (3) + scored fill, under the 8-slot file
    _ = await driver.runOneTick()
    let scheduled = await driver._inFlightIDsForTest
    for id in scheduled.sorted(by: { $0.depth < $1.depth }) {
        await driver.completeLoad(id: id, chunk: api_chunk(id, points: 100))
        _ = queue.drain()
    }
    var resident = await driver._residentIDsForTest
    #expect(pinned.isSubset(of: resident), "pinned nodes should be resident after loading")

    // Drop the budget to zero and tick until non-pinned drains. Pinned nodes
    // must never be evicted or re-scheduled.
    await driver.setBudget(slots: 0)
    for _ in 0..<12 {
        _ = await driver.runOneTick()
        if let u = queue.drain() {
            for r in u.removed {
                #expect(!pinned.contains(r), "a pinned node was evicted: \(r)")
            }
        }
        let inFlight = await driver._inFlightIDsForTest
        #expect(inFlight.isDisjoint(with: pinned),
                "a pinned node was re-scheduled: \(inFlight.intersection(pinned))")
    }
    resident = await driver._residentIDsForTest
    #expect(pinned.isSubset(of: resident), "pinned nodes must stay resident at zero budget")
    #expect(resident == pinned, "only pinned nodes should remain resident at zero budget (got \(resident))")
}

// MARK: - #3 Decode-queue telemetry

@Test func decodeStats_boxTransitions_areExactAndClamped() {
    let box = DecodeStatsBox()
    box.scheduled(3)
    #expect(box.snapshot().pendingRequests == 3)

    box.decodeBegan()
    var s = box.snapshot()
    #expect(s.pendingRequests == 2 && s.inFlightDecodes == 1)

    box.decodeEnded(points: 100, success: true)
    s = box.snapshot()
    #expect(s.inFlightDecodes == 0)
    #expect(s.decodedChunks == 1 && s.decodedPoints == 100)

    box.cancelledPending(1)
    #expect(box.snapshot().pendingRequests == 1)

    // A failed decode still decrements active but doesn't bump cumulative.
    box.decodeBegan()
    box.decodeEnded(points: 0, success: false)
    s = box.snapshot()
    #expect(s.inFlightDecodes == 0 && s.decodedChunks == 1 && s.decodedPoints == 100)

    // Over-decrement clamps at zero rather than going negative.
    box.decodeEnded(points: 0, success: false)
    box.cancelledPending(99)
    s = box.snapshot()
    #expect(s.pendingRequests == 0 && s.inFlightDecodes == 0)

    // reset() clears instantaneous counters but preserves cumulative totals.
    box.scheduled(5); box.decodeBegan()
    box.reset()
    s = box.snapshot()
    #expect(s.pendingRequests == 0 && s.inFlightDecodes == 0)
    #expect(s.decodedChunks == 1 && s.decodedPoints == 100)
}

@Test func decodeStats_driverWiring_pendingActiveAndCumulative() async throws {
    guard let (driver, _) = api_makeDriver(
        nodes: api_chainNodes(), options: api_options(alwaysResidentDepth: nil)
    ) else { Issue.record("fixture reader unavailable"); return }

    await driver.setView(api_view())
    await driver.setBudget(slots: 6)   // scorer runs (under the 8-slot file); root is dragged in
    _ = await driver.runOneTick()   // schedules the wanted chain into inFlight

    let scheduledCount = await driver._inFlightIDsForTest.count
    var s = await driver._statsSnapshotForTest()
    #expect(s.pendingRequests == scheduledCount,
            "scheduling should mark every in-flight node pending (\(s.pendingRequests) vs \(scheduledCount))")
    #expect(s.inFlightDecodes == 0, "nothing is decoding until a worker begins")

    // Simulate a worker beginning + finishing a decode.
    await driver.beginDecode(id: a_d0)
    s = await driver._statsSnapshotForTest()
    #expect(s.pendingRequests == scheduledCount - 1 && s.inFlightDecodes == 1)

    await driver.completeLoad(id: a_d0, chunk: api_chunk(a_d0, points: 100))
    s = await driver._statsSnapshotForTest()
    #expect(s.inFlightDecodes == 0)
    #expect(s.decodedChunks == 1 && s.decodedPoints == 100)

    // Cancelling still-pending nodes releases their pending slots.
    let remaining = await driver._inFlightIDsForTest
    await driver.cancel(Array(remaining))
    s = await driver._statsSnapshotForTest()
    #expect(s.pendingRequests == 0,
            "cancelling all pending nodes should zero the pending count (got \(s.pendingRequests))")
}

// MARK: - #4 Runtime-adjustable target chunk screen size

@Test func retarget_updatesValue_clamps_andReScoresNextPass() async throws {
    // Enforcement OFF so admission is single-node and the top-scored node is
    // unambiguous — isolates the retarget effect from ancestor expansion.
    guard let (driver, _) = api_makeDriver(
        nodes: api_chainNodes(), options: api_options(enforce: false, targetChunkScreenSize: 1)
    ) else { Issue.record("fixture reader unavailable"); return }

    #expect(await driver._targetScreenSizeForTest == 1)

    // Budget fits a single node (1 slot). At target=1 the extent-1 leaf is the
    // unique best match.
    let small = await driver._wantedSetForTest(view: api_view(), budget: 1)
    #expect(small.set.contains(a_leaf) && !small.set.contains(a_d0),
            "target=1 should prefer the fine leaf (got \(small.set))")

    // Retarget to 8: now the extent-8 root is the best match. The next scoring
    // pass reflects it — no restart, no re-open.
    await driver.setTargetScreenSize(8)
    #expect(await driver._targetScreenSizeForTest == 8)
    let big = await driver._wantedSetForTest(view: api_view(), budget: 1)
    #expect(big.set.contains(a_d0) && !big.set.contains(a_leaf),
            "target=8 should prefer the coarse root after retarget (got \(big.set))")

    // Values are clamped to >= 1.
    await driver.setTargetScreenSize(0.25)
    #expect(await driver._targetScreenSizeForTest == 1, "target must clamp to >= 1")
}

@Test func retarget_invalidatesWantedCache() async throws {
    guard let (driver, _) = api_makeDriver(
        nodes: api_chainNodes(), options: api_options(enforce: false, targetChunkScreenSize: 1)
    ) else { Issue.record("fixture reader unavailable"); return }

    await driver.setView(api_view())
    await driver.setBudget(slots: 1)
    _ = await driver.runOneTick()                 // populates the wanted cache (miss)
    _ = await driver.runOneTick()                 // cache hit (same view+budget)
    let hitsBefore = await driver.snapshot().cacheHits
    let missesBefore = await driver.snapshot().cacheMisses

    // Retargeting must force a recompute on the next tick (a cache miss).
    await driver.setTargetScreenSize(8)
    _ = await driver.runOneTick()
    let missesAfter = await driver.snapshot().cacheMisses
    #expect(missesAfter == missesBefore + 1,
            "retarget should invalidate the wanted-set cache (misses \(missesBefore)→\(missesAfter))")
    _ = hitsBefore
}
