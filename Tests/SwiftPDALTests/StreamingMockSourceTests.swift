import Testing
import Foundation
import simd
// NOTE: deliberately a NON-`@testable` import. This whole file exercises the
// streaming residency protocol using *only* SwiftPDAL's public API, proving a
// downstream consumer can build a mock `StreamingPointCloudSource` — for its
// own unit tests — without any `internal` access or a real COPC file.
import SwiftPDAL

// MARK: - A downstream-style mock source built from public API only

/// Minimal in-memory `StreamingPointCloudSource` a consumer could write to
/// unit-test its adapter without opening a COPC file. Every type it touches
/// (`StreamingSourceInfo`, `ResidentChunk`, `StreamingRasterBatch`,
/// `StreamingUpdate`, `StreamingDecodeStats`) is constructed through a public
/// initializer.
final class MockStreamingSource: StreamingPointCloudSource, @unchecked Sendable {
    let info: StreamingSourceInfo

    private let lock = NSLock()
    private var queuedUpdates: [StreamingUpdate] = []
    private(set) var submittedViews: [StreamingCameraView] = []
    private(set) var lastBudget: Int?
    private(set) var lastTargetScreenSize: Float?
    private(set) var cancelledIDs: [ChunkID] = []
    private(set) var closed = false
    private var stats: StreamingDecodeStats

    init(info: StreamingSourceInfo, stats: StreamingDecodeStats = .init()) {
        self.info = info
        self.stats = stats
    }

    /// Queue an update the next `pollLatest()`/`nextUpdate()` will return.
    func enqueue(_ update: StreamingUpdate) {
        lock.withLock { queuedUpdates.append(update) }
    }

    func setStats(_ s: StreamingDecodeStats) { lock.withLock { stats = s } }

    func submit(view: StreamingCameraView) { lock.withLock { submittedViews.append(view) } }
    func setBudget(_ bytes: Int) { lock.withLock { lastBudget = bytes } }

    func pollLatest() -> StreamingUpdate? {
        lock.withLock { queuedUpdates.isEmpty ? nil : queuedUpdates.removeFirst() }
    }
    func nextUpdate() async -> StreamingUpdate? { pollLatest() }
    func cancel(_ chunkIDs: [ChunkID]) { lock.withLock { cancelledIDs.append(contentsOf: chunkIDs) } }
    func close() { lock.withLock { closed = true } }

    // Overrides of the protocol's defaulted members — proves they dispatch
    // dynamically through `any StreamingPointCloudSource`.
    func setTargetChunkScreenSize(_ pixels: Float) { lock.withLock { lastTargetScreenSize = pixels } }
    func decodeStats() -> StreamingDecodeStats { lock.withLock { stats } }
}

// MARK: - Public-API construction helpers

private func makeInfo() -> StreamingSourceInfo {
    StreamingSourceInfo(
        bounds: Bounds(min: SIMD3<Float>(repeating: -1), max: SIMD3<Float>(repeating: 1)),
        originShift: SIMD3<Double>(0, 0, 0),
        totalPoints: 1_000,
        maxDepth: 4,
        pointsPerBatch: 256,
        bytesPerPoint: 17,
        availableDimensions: ["Classification", "Intensity"]
    )
}

private func makeChunk(_ id: ChunkID, points: Int) -> ResidentChunk {
    let batch = StreamingRasterBatch(
        state: 1,
        min: SIMD3<Float>(repeating: -1),
        max: SIMD3<Float>(repeating: 1),
        numPoints: UInt32(points),
        firstPoint: 0,
        fileIndex: 0
    )
    // Buffers sized as the real decoder would size them, from public docs:
    // 4 bytes/point for each xyz fragment + colors, 1 byte/point for levels.
    return ResidentChunk(
        id: id,
        batches: [batch],
        xyzLow: Data(count: points * 4),
        xyzMed: Data(count: points * 4),
        xyzHigh: Data(count: points * 4),
        colors: Data(count: points * 4),
        levels: Data(count: points)
    )
}

// MARK: - Tests

@Test func mock_valueTypes_constructibleFromPublicAPIOnly() {
    let info = makeInfo()
    #expect(info.bytesPerPoint == 17)
    #expect(info.availableDimensions.count == 2)

    let chunk = makeChunk(ChunkID(depth: 2, x: 1, y: 0, z: 3), points: 10)
    #expect(chunk.totalPointCount == 10)
    #expect(chunk.byteCost == 10 * 17)
    #expect(chunk.id.depth == 2)

    let update = StreamingUpdate(added: [chunk], removed: [ChunkID(depth: 1, x: 0, y: 0, z: 0)])
    #expect(!update.isEmpty)
    #expect(update.added.count == 1)
    #expect(update.removed.count == 1)
}

@Test func mock_drivesResidencyProtocolThroughExistential() async {
    let source: any StreamingPointCloudSource = MockStreamingSource(info: makeInfo())

    source.setBudget(64 << 20)
    source.submit(view: StreamingCameraView(
        position: .zero, viewProjection: matrix_identity_float4x4, pixelScale: 100))

    // Nothing queued yet.
    #expect(source.pollLatest() == nil)

    // Queue one update via the concrete mock, drain it through the protocol.
    let mock = source as! MockStreamingSource
    let chunk = makeChunk(ChunkID(depth: 0, x: 0, y: 0, z: 0), points: 50)
    mock.enqueue(StreamingUpdate(added: [chunk], removed: []))

    let delta = source.pollLatest()
    #expect(delta?.added.first?.id == ChunkID(depth: 0, x: 0, y: 0, z: 0))
    #expect(delta?.added.first?.totalPointCount == 50)

    let asyncDelta = await source.nextUpdate()
    #expect(asyncDelta == nil)   // already drained

    source.cancel([ChunkID(depth: 3, x: 1, y: 1, z: 1)])
    #expect(mock.cancelledIDs.count == 1)
    #expect(mock.submittedViews.count == 1)
    #expect(mock.lastBudget == 64 << 20)

    source.close()
    #expect(mock.closed)
}

@Test func mock_defaultedProtocolMembers_dispatchDynamically() {
    let mock = MockStreamingSource(info: makeInfo(), stats: StreamingDecodeStats(
        pendingRequests: 3, inFlightDecodes: 2, decodedChunks: 7, decodedPoints: 700))
    let source: any StreamingPointCloudSource = mock

    // decodeStats() is a defaulted protocol requirement; the override must win
    // through the existential.
    let s = source.decodeStats()
    #expect(s.pendingRequests == 3)
    #expect(s.inFlightDecodes == 2)
    #expect(s.decodedChunks == 7)
    #expect(s.decodedPoints == 700)

    source.setTargetChunkScreenSize(128)
    #expect(mock.lastTargetScreenSize == 128)
}
