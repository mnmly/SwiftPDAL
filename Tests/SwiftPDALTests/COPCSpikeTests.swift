import Testing
import Foundation
import CxxCOPC
@testable import SwiftPDAL

@Test func copcSpike_listsNodes() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let path = Bundle.module.path(forResource: "test.copc", ofType: "laz") else {
        Issue.record("test.copc.laz not found in bundle")
        return
    }

    let handle = path.withCString { swiftpdal_copc_open($0) }
    #expect(handle != nil, "FileReader failed to open")
    defer { swiftpdal_copc_close(handle) }

    var totalPoints: Int64 = 0
    #expect(swiftpdal_copc_total_points(handle, &totalPoints) == 0)
    #expect(totalPoints > 0)

    var minXYZ = [Double](repeating: 0, count: 3)
    var maxXYZ = [Double](repeating: 0, count: 3)
    #expect(swiftpdal_copc_bounds(handle, &minXYZ, &maxXYZ) == 0)

    var nodeCount: Int32 = 0
    #expect(swiftpdal_copc_node_count(handle, &nodeCount) == 0)
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
        var info = copc_node_info()
        #expect(swiftpdal_copc_node_at(handle, i, &info) == 0)
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
