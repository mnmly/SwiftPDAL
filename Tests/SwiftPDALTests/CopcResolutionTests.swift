import Testing
import Foundation
import simd
@testable import SwiftPDAL

// Validates the COPC LOD-limited read: `PointCloud.read(…, resolution:)` on a
// *.copc.laz reads only octree nodes coarser than `resolution`, so a positive
// resolution returns a strict, non-empty subset of the full read — the whole
// point of reading COPC coarsely instead of decoding every point.
@Test func copcResolution_readsCoarseSubset() throws {
    guard let path = Bundle.module.path(forResource: "test.copc", ofType: "laz") else {
        Issue.record("test.copc.laz not found in test bundle")
        return
    }

    let full = try PointCloud.read(from: path, readerName: "readers.copc", resolution: 0)
    #expect(full.pointCount > 0)

    let ext = full.bounds.max - full.bounds.min
    let span = Double(max(ext.x, max(ext.y, ext.z)))
    // Coarse enough to drop the finest octree levels but keep the top ones.
    let coarse = try PointCloud.read(from: path, readerName: "readers.copc", resolution: span / 8.0)

    print("[CopcResolution] span=\(span) full=\(full.pointCount) coarse=\(coarse.pointCount)")
    #expect(coarse.pointCount > 0)
    #expect(coarse.pointCount < full.pointCount)
}
