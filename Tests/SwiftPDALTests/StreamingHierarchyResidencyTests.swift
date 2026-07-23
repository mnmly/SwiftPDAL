import Testing
import Foundation
import simd
import CxxCOPC
import CxxStdlib
@testable import SwiftPDAL

// Tests for the COPC hierarchy residency invariant (see
// `StreamingOptions.enforceHierarchyResidency`): the resident set stays
// closed under parent, admission is top-down, eviction is leaf-first, and
// published deltas are ordered so a consumer applying them in array order
// never observes a violation.
//
// The unit tests drive `StreamingDriver` against a *synthetic* octree — no
// decode pipeline — feeding `completeLoad` in adversarial order to prove the
// ordering guarantees hold regardless of decode-completion order. A COPC
// reader handle is still required to construct the driver; it is opened from
// the bundled fixture but never used by the residency logic under test.

// MARK: - Helpers

/// Returns the first node in `ids` whose parent is absent (a closure
/// violation), or `nil` if the set is closed under parent.
private func firstUnclosed(_ ids: Set<ChunkID>) -> ChunkID? {
    for id in ids where id.depth > 0 {
        guard let p = id.parent, ids.contains(p) else { return id }
    }
    return nil
}

private func synthNode(
    _ id: ChunkID, points: Int, extent: Float, center: SIMD3<Float> = .zero
) -> NodeMeta {
    let half = SIMD3<Float>(repeating: extent * 0.5)
    return NodeMeta(
        id: id, pointCount: points,
        minXYZ: center - half, maxXYZ: center + half,
        center: center, extent: extent, offset: 0, byteSize: points * 8
    )
}

private func synthChunk(_ id: ChunkID, points: Int) -> ResidentChunk {
    let b = StreamingRasterBatch(
        state: 1, min: .zero, max: .zero,
        numPoints: UInt32(points), firstPoint: 0, fileIndex: 0
    )
    return ResidentChunk(
        id: id, batches: [b],
        xyzLow: Data(), xyzMed: Data(), xyzHigh: Data(),
        colors: Data(), levels: Data(), extraScalars: [:]
    )
}

private func openFixtureReader() -> SendableCopcReader? {
    guard let path = Bundle.module.path(forResource: "test.copc", ofType: "laz"),
          let reader = swiftpdal.copc.Reader.open(std.string(path), 1)
    else { return nil }
    return SendableCopcReader(reader: reader)
}

/// `pointsPerBatch` defaults to the synthetic node point count (100) so each
/// chain node costs exactly one GPU slot — this lets the slot budgets below
/// read directly in "nodes", the way the old byte budgets read as multiples
/// of a node's 1700-byte footprint. Override it to exercise partial-batch
/// (`pointCount < pointsPerBatch`) slot rounding.
private func makeDriver(
    nodes: [NodeMeta], options: StreamingOptions, pointsPerBatch: Int = 100
) -> (StreamingDriver, UpdateQueue)? {
    guard let handle = openFixtureReader() else { return nil }
    let queue = UpdateQueue()
    let jobs = JobQueue()
    let driver = StreamingDriver(
        handle: handle, nodes: nodes, originShift: .zero,
        options: options, queue: queue, jobs: jobs,
        budgetBytesPerPoint: 17, pointsPerBatch: pointsPerBatch, isRemote: false
    )
    return (driver, queue)
}

/// A linear root→leaf chain `(0,0,0)` at depths 0..3, plus sibling nodes so
/// `totalNodeBytes` exceeds the test budgets (otherwise the whole-file
/// shortcut bypasses the scorer). `extent` is tuned so the deepest chain
/// node uniquely matches the scorer's target (see `chainView`).
private let d0 = ChunkID(depth: 0, x: 0, y: 0, z: 0)
private let d1 = ChunkID(depth: 1, x: 0, y: 0, z: 0)
private let d2 = ChunkID(depth: 2, x: 0, y: 0, z: 0)
private let leaf = ChunkID(depth: 3, x: 0, y: 0, z: 0)

private func chainNodes(points: Int = 100) -> [NodeMeta] {
    [
        synthNode(d0, points: points, extent: 8),
        synthNode(d1, points: points, extent: 4),
        synthNode(d2, points: points, extent: 2),
        synthNode(leaf, points: points, extent: 1),          // extent == target
        // Siblings (valid parents in-tree) to inflate totalNodeBytes.
        synthNode(ChunkID(depth: 1, x: 1, y: 0, z: 0), points: points, extent: 4),
        synthNode(ChunkID(depth: 2, x: 2, y: 0, z: 0), points: points, extent: 2),
        synthNode(ChunkID(depth: 2, x: 3, y: 0, z: 0), points: points, extent: 2),
        synthNode(ChunkID(depth: 3, x: 4, y: 0, z: 0), points: points, extent: 1.3),
        synthNode(ChunkID(depth: 3, x: 5, y: 0, z: 0), points: points, extent: 1.3),
    ]
}

/// Orthographic identity view + unit pixel scale, so the scorer's screen
/// size collapses to `extent`. With `targetChunkScreenSize = 1`, the chain's
/// depth-3 `leaf` (extent 1) is the unique top-scored candidate.
private func chainView() -> StreamingCameraView {
    StreamingCameraView(
        position: .zero,
        viewProjection: matrix_identity_float4x4,
        pixelScale: 1,
        depthTolerance: 1
    )
}

private func chainOptions(
    evictionDelayTicks: Int = 100,
    maxInFlightLoads: Int = 100,
    enforce: Bool = true
) -> StreamingOptions {
    StreamingOptions(
        maxInFlightLoads: maxInFlightLoads,
        decodeConcurrency: 1,
        prefetchRoot: false,
        evictionDelayTicks: evictionDelayTicks,
        driverTickInterval: .milliseconds(10),
        residencyPolicy: .distanceOnly,
        targetChunkScreenSize: 1,
        enforceHierarchyResidency: enforce
    )
}

// MARK: - Wanted-set admission (closure + budget deferral)

@Test func hierarchy_wantedSet_closedUnderParent_andFitsBudget() async throws {
    // 100-pt nodes @ pointsPerBatch 100 → every node costs exactly 1 slot, so
    // the root→leaf chain is 4 slots and the whole file (9 nodes) is 9 slots.
    guard let (driver, _) = makeDriver(nodes: chainNodes(), options: chainOptions())
    else { Issue.record("fixture reader unavailable"); return }

    // Budget fits the full root→leaf chain (4 slots) but not the whole file
    // (9 slots), so the scorer runs and the top-scored leaf drags in its
    // ancestors. Sits exactly at the chain cost: a 5th node would overflow.
    let big = await driver._wantedSetForTest(view: chainView(), budget: 4)
    #expect(big.set.contains(leaf),
            "the uniquely top-scored leaf should be admitted when its chain fits")
    #expect(big.set.contains(d0), "ancestors of an admitted leaf must be admitted too")
    #expect(firstUnclosed(big.set) == nil,
            "wanted set must be closed under parent (violation at \(String(describing: firstUnclosed(big.set)))")
    #expect(big.set.count <= 4, "admitted slots (\(big.set.count)) must not exceed the 4-slot budget")
    // `ordered` must list ancestors before descendants (load priority).
    var seen = Set<ChunkID>()
    for id in big.ordered {
        if let p = id.parent, big.set.contains(p) {
            #expect(seen.contains(p), "ordered listed \(id) before its parent \(p)")
        }
        seen.insert(id)
    }
}

@Test func hierarchy_wantedSet_defersFineNodeWhenChainDoesNotFit() async throws {
    // 1 slot per node (see the fits-budget test).
    guard let (driver, _) = makeDriver(nodes: chainNodes(), options: chainOptions())
    else { Issue.record("fixture reader unavailable"); return }

    // Budget fits only the root→depth-1 prefix (d0+d1 = 2 slots), not the full
    // 4-slot chain to the leaf. Admission climbs root-first and stops when d2
    // would push to 3 slots, so the leaf is deferred (never admitted orphaned)
    // while the coarse ancestors it needs are admitted.
    let small = await driver._wantedSetForTest(view: chainView(), budget: 2)
    #expect(!small.set.contains(leaf),
            "a leaf whose full ancestor chain doesn't fit must be deferred, not admitted")
    #expect(small.set.contains(d0),
            "the affordable coarse prefix should still be admitted (coverage first)")
    #expect(firstUnclosed(small.set) == nil,
            "deferring the leaf must keep the wanted set closed under parent")
    #expect(small.set.count <= 2, "admitted slots (\(small.set.count)) must not exceed the 2-slot budget")
}

// MARK: - Pre-clamp residency demand

@Test func residencyDemand_reportsUnclampedAppetite() async throws {
    // 9 nodes @ 1 slot each (100-pt nodes, pointsPerBatch 100) → the whole file
    // is 9 slots. `.distanceOnly` (chainOptions default) makes every node a
    // candidate, so the pre-clamp demand is the full 9 slots regardless of the
    // budget the wanted set is clamped to.
    guard let (driver, _) = makeDriver(nodes: chainNodes(), options: chainOptions())
    else { Issue.record("fixture reader unavailable"); return }

    // Unclamped: budget covers the whole file (whole-file shortcut). Demand
    // equals the wanted set's cost — everything the camera wants is admitted.
    let unclamped = await driver._wantedSetForTest(views: [chainView()], budget: 9)
    #expect(unclamped.demand == 9, "unclamped demand should equal the whole-file slot cost")
    #expect(unclamped.set.count == unclamped.demand,
            "unclamped, the wanted set cost (\(unclamped.set.count)) should equal demand (\(unclamped.demand))")

    // Clamped: budget admits only 4 of the 9 candidate slots. Demand still
    // reports the full pre-clamp appetite (9), strictly above the budget — this
    // is the grant-independent weight a host governor divides a global budget by.
    let clamped = await driver._wantedSetForTest(views: [chainView()], budget: 4)
    #expect(clamped.demand == 9, "clamped demand must stay at the pre-clamp appetite (9), not the budget")
    #expect(clamped.demand > 4, "demand should exceed the clamping budget")
    #expect(clamped.set.count <= 4, "the clamped wanted set (\(clamped.set.count)) must fit the 4-slot budget")
}

// MARK: - Admission ordering (adversarial completeLoad, deepest-first)

@Test func hierarchy_publishedAdded_parentBeforeChild_underOutOfOrderDecodes() async throws {
    guard let (driver, queue) = makeDriver(nodes: chainNodes(), options: chainOptions())
    else { Issue.record("fixture reader unavailable"); return }

    await driver.setView(chainView())
    await driver.setBudget(slots: 4)   // fits exactly the 4-slot chain, excludes siblings
    _ = await driver.runOneTick()   // schedules the chain into `inFlight`

    let scheduled = await driver._inFlightIDsForTest
    #expect(scheduled == Set([d0, d1, d2, leaf]),
            "the whole chain should be scheduled (got \(scheduled))")

    // Deliver decode completions deepest-first — the worst case for the
    // invariant. The driver must hold each child until its parent lands.
    var believed = Set<ChunkID>()
    for id in scheduled.sorted(by: { $0.depth > $1.depth }) {
        await driver.completeLoad(id: id, chunk: synthChunk(id, points: 100))
        guard let u = queue.drain() else { continue }
        for r in u.removed { believed.remove(r) }
        var running = believed
        for c in u.added {
            if let p = c.id.parent {
                #expect(running.contains(p),
                        "added published child \(c.id) before its parent \(p)")
            }
            running.insert(c.id)
        }
        believed = running
        #expect(firstUnclosed(believed) == nil,
                "believed-resident set must be closed under parent after every delta")
    }

    #expect(believed == Set([d0, d1, d2, leaf]),
            "all chain nodes should end up published (got \(believed))")
    let resident = await driver._residentIDsForTest
    #expect(firstUnclosed(resident) == nil, "driver resident set must be closed under parent")
}

// MARK: - Eviction ordering (leaf-first, descendant-before-parent)

@Test func hierarchy_eviction_isLeafFirst_andOrdersRemovedDescendantFirst() async throws {
    guard let (driver, queue) = makeDriver(
        nodes: chainNodes(), options: chainOptions(evictionDelayTicks: 1)
    ) else { Issue.record("fixture reader unavailable"); return }

    // Phase 1: make the whole chain resident (feed root-first, cleanly).
    await driver.setView(chainView())
    await driver.setBudget(slots: 4)   // fits exactly the 4-slot chain
    _ = await driver.runOneTick()
    var believed = Set<ChunkID>()
    for id in [d0, d1, d2, leaf] {
        await driver.completeLoad(id: id, chunk: synthChunk(id, points: 100))
        if let u = queue.drain() { for c in u.added { believed.insert(c.id) } }
    }
    #expect(believed == Set([d0, d1, d2, leaf]), "phase 1 should make the chain resident")

    // Phase 2: drop the budget to 0 so nothing is wanted, then tick until
    // the chain drains. Every published `removed` must list descendants
    // before ancestors and never free a node while a child is still resident.
    await driver.setBudget(slots: 0)
    var sawRemoval = false
    for _ in 0..<12 {
        _ = await driver.runOneTick()
        guard let u = queue.drain() else { continue }
        for r in u.removed {
            sawRemoval = true
            #expect(!believed.contains(where: { $0.parent == r }),
                    "evicted \(r) while a child was still resident (not leaf-first)")
            believed.remove(r)
        }
        #expect(firstUnclosed(believed) == nil,
                "believed-resident set must stay closed under parent through eviction")
        if believed.isEmpty { break }
    }
    #expect(sawRemoval, "phase 2 should have evicted chunks")
    #expect(believed.isEmpty, "the whole chain should eventually evict (left: \(believed))")
}

// MARK: - Opt-out restores score-only behavior

@Test func hierarchy_disabled_admitsWithoutAncestorExpansion() async throws {
    guard let (driver, _) = makeDriver(
        nodes: chainNodes(), options: chainOptions(enforce: false)
    ) else { Issue.record("fixture reader unavailable"); return }

    // With enforcement off and a 1-slot budget (fits only one node), the
    // top-scored leaf is admitted alone — its ancestors are NOT dragged in,
    // so the set is not closed under parent (the pre-invariant behavior).
    let w = await driver._wantedSetForTest(view: chainView(), budget: 1)
    #expect(w.set.contains(leaf), "score-only admit should still take the top-scored leaf")
    #expect(!w.set.contains(d0),
            "with enforcement off, admitting the leaf must not pull in its ancestors")
}

// MARK: - Slot rounding (the migration this test suite was re-authored for)

/// Pins the semantic the byte→slot migration exists for: residency is admitted
/// in whole GPU slots, so a node holding FEWER points than `pointsPerBatch`
/// occupies a partial final batch that still burns one whole slot. Under the
/// old byte budget these small nodes were nearly free and the same budget
/// admitted more of them; under slots each costs 1, so the budget clamps by
/// node count, not by bytes.
@Test func hierarchy_slotBudget_partialBatchNodeCostsFullSlot() async throws {
    // pointsPerBatch (1000) >> the 100-pt nodes → every node is a *partial*
    // batch, yet ceil(100/1000) == 1 slot each. The chain is still 4 slots.
    let ppb = 1000
    guard let (driver, _) = makeDriver(
        nodes: chainNodes(), options: chainOptions(), pointsPerBatch: ppb
    ) else { Issue.record("fixture reader unavailable"); return }

    // 2-slot budget → only the root→depth-1 prefix (2 partial-batch nodes)
    // fits; the leaf's chain (4 slots) is clamped out.
    let w = await driver._wantedSetForTest(view: chainView(), budget: 2)

    // Each admitted node cost a full slot despite being a partial batch:
    // ceil(100/1000) == 1, so slot cost == node count.
    let perNodeSlots = (100 + ppb - 1) / ppb
    #expect(perNodeSlots == 1, "a 100-pt node in a 1000-pt batch must round up to one whole slot")
    let slotsUsed = w.set.count * perNodeSlots
    #expect(slotsUsed <= 2, "wanted set (\(slotsUsed) slots) must fit the 2-slot budget")
    #expect(w.set.contains(d0), "coarse coverage is still admitted within budget")
    #expect(!w.set.contains(leaf), "the leaf is clamped out — its chain needs 4 slots")

    // The point: measured in bytes these nodes are tiny. All 9 nodes together
    // are 9 × 100 × 17 = 15300 bytes; even the affordable prefix is only 3400.
    // A byte budget sized to "2 batches" (2 × 1000 × 17 = 34000 bytes) would
    // have admitted the whole chain and then some. Slots — not bytes — clamp.
    let admittedBytes = w.set.count * 100 * 17
    #expect(admittedBytes < 2 * ppb * 17,
            "the admitted nodes' bytes (\(admittedBytes)) fit a 2-batch byte budget; slots still clamped them")
}

// MARK: - Env-gated real-file test

/// Streams a real COPC file with a scripted far→zoom→hold camera and asserts
/// the closed-under-parent invariant after every poll, reporting the
/// ancestors-first arrival ratio (must be 100%). Skips cleanly unless
/// `SWIFTPDAL_TEST_COPC=/path/to/file.copc.laz` is set.
@Test func hierarchy_realFile_ancestorsFirstArrivalRatioIs100() async throws {
    guard let path = ProcessInfo.processInfo.environment["SWIFTPDAL_TEST_COPC"] else {
        return   // not configured — clean skip
    }
    let url = URL(fileURLWithPath: path)
    let source = try await CopcStreamingPointCloudSource.open(url, options: .init(
        maxInFlightLoads: 16,
        decodeConcurrency: 4,
        prefetchRoot: false,
        evictionDelayTicks: 4,
        driverTickInterval: .milliseconds(20),
        residencyPolicy: .frustumFirstThenHalo
    ))
    defer { source.close() }
    source.setBudget(512 << 20)   // 512 MB — well under a multi-GB file → hierarchy streaming

    var believed = Set<ChunkID>()
    var arrivals = 0
    var ancestorsFirst = 0

    func drainAndCheck() {
        while let u = source.pollLatest() {
            for r in u.removed { believed.remove(r) }
            for c in u.added {
                arrivals += 1
                if c.id.parent == nil || believed.contains(c.id.parent!) {
                    ancestorsFirst += 1
                }
                believed.insert(c.id)
            }
            #expect(firstUnclosed(believed) == nil,
                    "closed-under-parent invariant violated on real file")
        }
    }

    let bounds = source.info.bounds
    let shift = source.info.originShift
    let center = SIMD3<Float>(
        (bounds.min.x + bounds.max.x) * 0.5 - Float(shift.x),
        (bounds.min.y + bounds.max.y) * 0.5 - Float(shift.y),
        (bounds.min.z + bounds.max.z) * 0.5 - Float(shift.z)
    )
    let span = simd_length(bounds.max - bounds.min)

    func lookAt(distanceMul: Float) -> simd_float4x4 {
        let eye = center + SIMD3<Float>(0, 0, span * distanceMul)
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, SIMD3<Float>(0, 1, 0)))
        let u = simd_cross(s, f)
        let view = simd_float4x4(
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        )
        let fov: Float = .pi / 3
        let aspect: Float = 1
        let near = max(span * 0.001, 0.01)
        let far = span * 8
        let yScale = 1 / tan(fov * 0.5)
        let zRange = far - near
        let proj = simd_float4x4(
            SIMD4<Float>(yScale / aspect, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, -(far + near) / zRange, -1),
            SIMD4<Float>(0, 0, -2 * far * near / zRange, 0)
        )
        return proj * view
    }

    // Far → zoom in → hold.
    let stages: [Float] = [3.0, 1.6, 0.9, 0.5, 0.5, 0.5]
    for mul in stages {
        let eye = center + SIMD3<Float>(0, 0, span * mul)
        source.submit(view: StreamingCameraView(
            position: eye, viewProjection: lookAt(distanceMul: mul), pixelScale: 800))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            drainAndCheck()
        }
    }
    drainAndCheck()

    print("--- hierarchy real-file arrivals ---")
    print("arrivals: \(arrivals), ancestors-first: \(ancestorsFirst), resident: \(believed.count)")
    #expect(arrivals > 0, "expected some chunks to arrive")
    #expect(ancestorsFirst == arrivals,
            "every arrival must have its parent already resident (\(ancestorsFirst)/\(arrivals))")
    #expect(firstUnclosed(believed) == nil, "final resident set must be closed under parent")
}
