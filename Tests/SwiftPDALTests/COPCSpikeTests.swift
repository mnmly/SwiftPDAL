import Testing
import Foundation
import CxxCOPC
import CxxStdlib
@testable import SwiftPDAL

@Test func copcSpike_listsNodes() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let path = Bundle.module.path(forResource: "test.copc", ofType: "laz") else {
        Issue.record("test.copc.laz not found in bundle")
        return
    }

    guard let reader = swiftpdal.copc.Reader.open(std.string(path), 1) else {
        Issue.record("FileReader failed to open")
        return
    }
    defer { reader.close() }

    let totalPoints = reader.total_points()
    #expect(totalPoints > 0)

    let minXYZ = reader.bounds_min()
    let maxXYZ = reader.bounds_max()

    let nodeCount = reader.node_count()
    #expect(nodeCount > 0)

    print("--- COPC spike ---")
    print("file: \(path)")
    print("totalPoints: \(totalPoints)")
    print("bounds: [\(minXYZ[0]), \(minXYZ[1]), \(minXYZ[2])] .. [\(maxXYZ[0]), \(maxXYZ[1]), \(maxXYZ[2])]")
    print("nodeCount: \(nodeCount)")

    var nodePointSum: Int64 = 0
    var maxDepth: Int32 = 0
    let preview = min(nodeCount, 10)
    for i in 0 ..< nodeCount {
        var info = swiftpdal.copc.NodeInfo()
        #expect(reader.node_at(i, &info))
        nodePointSum += Int64(info.point_count)
        maxDepth = max(maxDepth, info.depth)
        if i < preview {
            print(String(format: "  node[%d] key=(%d,%d,%d,%d) pts=%d off=%llu sz=%d aabb=[%.2f,%.2f,%.2f]..[%.2f,%.2f,%.2f]",
                         i, info.depth, info.x, info.y, info.z,
                         info.point_count, info.offset, info.byte_size,
                         info.min_x, info.min_y, info.min_z,
                         info.max_x, info.max_y, info.max_z))
        }
    }
    print("maxDepth: \(maxDepth)")
    print("sum(node.point_count): \(nodePointSum)")

    #expect(nodePointSum == totalPoints, "node point counts should sum to total")
}
