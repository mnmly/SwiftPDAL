import Testing
import Foundation
import simd
@testable import SwiftPDAL

// `StreamingSourceInfo.nodesAtDepth` / `slotsAtDepth` and their prefix-sum
// accessors — the numbers a host sizes a *depth-limited* pin's GPU pool from
// (see `StreamingOptions.alwaysResidentDepth`). Before these existed the only
// available figure was the whole tree's node count, so a shallow pin was
// charged for every node in the file.

private func histogramFixture() -> URL? {
    Bundle.module.path(forResource: "test.copc", ofType: "laz").map {
        URL(fileURLWithPath: $0)
    }
}

@Test("Depth histogram covers every node exactly once")
func depthHistogramIsComplete() async throws {
    guard let url = histogramFixture() else {
        Issue.record("fixture missing"); return
    }
    let source = try await CopcStreamingPointCloudSource.open(url, options: .init())
    let info = source.info
    let totalNodes = await source._debugSnapshot().totalNodes

    #expect(info.nodesAtDepth.count == info.maxDepth + 1)
    #expect(info.slotsAtDepth.count == info.maxDepth + 1)
    #expect(info.nodesAtDepth.reduce(0, +) == totalNodes)

    // Every node rounds up to whole slots, so the exact total sits between the
    // packed estimate and that estimate plus one wasted slot per node.
    let packed = (Int(info.totalPoints) + info.pointsPerBatch - 1) / info.pointsPerBatch
    let total = try #require(info.totalSlots)
    #expect(total >= packed)
    #expect(total <= packed + totalNodes)
}

@Test("Prefix sums are monotonic and clamp at both ends")
func depthPrefixSumsClamp() async throws {
    guard let url = histogramFixture() else {
        Issue.record("fixture missing"); return
    }
    let source = try await CopcStreamingPointCloudSource.open(url, options: .init())
    let info = source.info
    let total = try #require(info.totalSlots)

    #expect(info.slotsThroughDepth(-1) == 0)
    #expect(info.nodesThroughDepth(-1) == 0)
    // A pin depth above the file's own depth pins everything, per
    // `alwaysResidentDepth`'s contract.
    #expect(info.slotsThroughDepth(info.maxDepth) == total)
    #expect(info.slotsThroughDepth(info.maxDepth + 8) == total)

    var previous = 0
    for depth in 0...info.maxDepth {
        let through = try #require(info.slotsThroughDepth(depth))
        #expect(through >= previous)
        previous = through
    }
}

@Test("A shallow pin costs a fraction of the whole hierarchy")
func shallowPinIsCheap() async throws {
    guard let url = histogramFixture() else {
        Issue.record("fixture missing"); return
    }
    let source = try await CopcStreamingPointCloudSource.open(url, options: .init())
    let info = source.info
    // Only meaningful on a fixture with something below the root.
    try #require(info.maxDepth >= 1)

    let root = try #require(info.slotsThroughDepth(0))
    let total = try #require(info.totalSlots)
    let totalNodes = await source._debugSnapshot().totalNodes
    #expect(root > 0)
    #expect(root < total)
    // The regression this guards: sizing a depth-0 pin off the whole tree's
    // node count (the pre-histogram bound) over-charges it by the entire file.
    #expect(try #require(info.nodesThroughDepth(0)) < totalNodes)
}

@Test("A source that publishes no histogram answers nil, not zero")
func absentHistogramIsNil() {
    // The memberwise init's defaults — how a mock/test source is built. A zero
    // here would read as "this pin costs nothing" and silently size a pool to
    // the floor; `nil` makes the caller fall back to its own estimate.
    let info = StreamingSourceInfo(
        bounds: Bounds(min: .zero, max: SIMD3<Float>(repeating: 1)),
        originShift: .zero,
        totalPoints: 1000,
        maxDepth: 4,
        pointsPerBatch: 100,
        bytesPerPoint: 17,
        availableDimensions: []
    )
    #expect(info.slotsThroughDepth(2) == nil)
    #expect(info.nodesThroughDepth(2) == nil)
    #expect(info.totalSlots == nil)
}
