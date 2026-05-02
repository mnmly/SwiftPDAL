import Testing
import Foundation
import simd
import Metal
import CxxPDAL
@testable import SwiftPDAL

@Test func readLAZFile() async throws {

    setenv("SWIFTPDAL_TESTING", "1", 1)
    // Get test file from bundle
    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    // Verify we got points
    #expect(pointCloud.pointCount > 0)

    // Print basic info
    print("Point count: \(pointCloud.pointCount)")
    print("Bounds: [\(pointCloud.bounds.min.x), \(pointCloud.bounds.min.y), \(pointCloud.bounds.min.z)] to [\(pointCloud.bounds.max.x), \(pointCloud.bounds.max.y), \(pointCloud.bounds.max.z)]")
    print("Data size: \(pointCloud.size) bytes")
    print("Stride: \(pointCloud.stride) bytes per point")

    // Print dimensions
    print("Dimensions:")
    for dim in pointCloud.dimensions {
        print("  - \(dim.name): size=\(dim.outputSize), offset=\(dim.offset)")
    }

    // Clean up

}

@Test func readE57File() async throws {

    setenv("SWIFTPDAL_TESTING", "1", 1)
    // Get test file from bundle
    guard let testFilePath = Bundle.module.path(forResource: "bunnyFloat", ofType: "e57") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath)

    // Verify we got points
    #expect(pointCloud.pointCount > 0)

    // Print basic info
    print("Point count: \(pointCloud.pointCount)")
    print("Bounds: [\(pointCloud.bounds.min.x), \(pointCloud.bounds.min.y), \(pointCloud.bounds.min.z)] to [\(pointCloud.bounds.max.x), \(pointCloud.bounds.max.y), \(pointCloud.bounds.max.z)]")
    print("Data size: \(pointCloud.size) bytes")
    print("Stride: \(pointCloud.stride) bytes per point")

    // Print dimensions
    print("Dimensions:")
    for dim in pointCloud.dimensions {
        print("  - \(dim.name): size=\(dim.outputSize), offset=\(dim.offset)")
    }

    // Clean up

}

@Test func buildOctree() async throws {
    // Set PROJ_DATA
    let bundlePath = Bundle.module.bundlePath as NSString
    let projDbPath = bundlePath.deletingLastPathComponent
        .appending("/SwiftPDAL_SwiftPDAL.bundle")
    setenv("PROJ_DATA", projDbPath, 1)

    // Get test file
    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    // Build octree
    let octree = pointCloud.buildOctree(maxPointsPerNode: 100, maxDepth: 10)

    // Verify octree was created
    let stats = octree.getStatistics()
    #expect(stats.nodeCount > 0)
    #expect(stats.maxDepth > 0)
    #expect(stats.maxDepth <= 10)

    print("Octree built with \(stats.nodeCount) nodes, max depth: \(stats.maxDepth)")

    // Clean up

}


@Test func octreeStatistics() async throws {
    // Set PROJ_DATA
    let bundlePath = Bundle.module.bundlePath as NSString
    let projDbPath = bundlePath.deletingLastPathComponent
        .appending("/SwiftPDAL_SwiftPDAL.bundle")
    setenv("PROJ_DATA", projDbPath, 1)

    // Get test file
    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    // Build octree with specific parameters
    let maxDepth = 8
    let maxElementsPerNode = 15

    let octree = pointCloud.buildOctree(maxPointsPerNode: maxElementsPerNode, maxDepth: maxDepth)

    // Get statistics
    let stats = octree.getStatistics()

    // Verify statistics are reasonable
    #expect(stats.nodeCount > 0)
    #expect(stats.maxDepth > 0)
    #expect(stats.maxDepth <= maxDepth)

    print("Octree Statistics:")
    print("  Node count: \(stats.nodeCount)")
    print("  Max depth: \(stats.maxDepth)")

    // Clean up

}

@Test func getPointDataFromOctree() async throws {
    // Set PROJ_DATA
    let bundlePath = Bundle.module.bundlePath as NSString
    let projDbPath = bundlePath.deletingLastPathComponent
        .appending("/SwiftPDAL_SwiftPDAL.bundle")
    setenv("PROJ_DATA", projDbPath, 1)

    // Get test file
    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    // Build octree
    let _ = pointCloud.buildOctree(maxPointsPerNode: 10, maxDepth: 20)

    // Get point data for first few points
    let _ = min(5, pointCloud.pointCount)
    

//    for i in 0..<testIndices {
//        let pointData = octree.getPointData(at: i)
//
//        // Verify point data exists
//        #expect(pointData != nil)
//
//        if let data = pointData {
//            // Verify data size matches stride
//            #expect(data.count == pointCloud.stride)
//
//            print("Point \(i) data size: \(data.count) bytes")
//        }
//    }

    // Clean up

}

@Test func mortonCodeEncodeDecode() async throws {
    // Test encoding and decoding with known values
    let x: Float = 0.5
    let y: Float = 0.25
    let z: Float = 0.75

    let morton = MortonCode(x: x, y: y, z: z)
    let decoded = morton.decodeNormalized()

    // Should be approximately equal (within floating point precision)
    let epsilon: Float = 0.0001
    #expect(abs(decoded.x - x) < epsilon)
    #expect(abs(decoded.y - y) < epsilon)
    #expect(abs(decoded.z - z) < epsilon)

    print("Morton code: \(morton)")
    print("Decoded: \(decoded)")
}

@Test func mortonCodeOrdering() async throws {
    // Test that Morton codes maintain spatial locality
    let bounds = AABB(
        min: simd_float3(0, 0, 0),
        max: simd_float3(10, 10, 10)
    )

    let p1 = simd_float3(1, 1, 1)
    let p2 = simd_float3(1.1, 1.1, 1.1) // Very close to p1
    let p3 = simd_float3(9, 9, 9) // Far from p1

    let m1 = MortonCode(point: p1, bounds: bounds)
    let m2 = MortonCode(point: p2, bounds: bounds)
    let m3 = MortonCode(point: p3, bounds: bounds)

    // Points close in space should have closer Morton codes
    let diff12 = abs(Int64(m1.code) - Int64(m2.code))
    let diff13 = abs(Int64(m1.code) - Int64(m3.code))

    #expect(diff12 < diff13)

    print("p1 morton: \(m1.code)")
    print("p2 morton: \(m2.code)")
    print("p3 morton: \(m3.code)")
    print("diff(p1,p2): \(diff12), diff(p1,p3): \(diff13)")
}

@Test func mortonCodeSorting() async throws {
    let bounds = AABB(
        min: simd_float3(0, 0, 0),
        max: simd_float3(100, 100, 100)
    )

    // Create some test points
    var points = [
        simd_float3(50, 50, 50),
        simd_float3(10, 10, 10),
        simd_float3(90, 90, 90),
        simd_float3(30, 30, 30),
        simd_float3(70, 70, 70),
    ]

    // Sort by Morton code
    MortonSorter.sortPoints(&points, bounds: bounds)

    // Verify points are sorted by their Morton codes
    let mortonCodes = points.map { MortonCode(point: $0, bounds: bounds) }

    for i in 0..<mortonCodes.count - 1 {
        #expect(mortonCodes[i].code <= mortonCodes[i + 1].code)
    }

    print("Sorted points by Morton code:")
    for (i, point) in points.enumerated() {
        print("  \(i): \(point) -> \(mortonCodes[i])")
    }
}

@Test func octreeWithMortonOrder() async throws {
    // Set PROJ_DATA
    let bundlePath = Bundle.module.bundlePath as NSString
    let projDbPath = bundlePath.deletingLastPathComponent
        .appending("/SwiftPDAL_SwiftPDAL.bundle")
    setenv("PROJ_DATA", projDbPath, 1)

    // Get test file
    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    // Build octree with Morton ordering
    let octreeWithMorton = Octree(
        pointCloud: pointCloud,
        maxPointsPerNode: 10,
        maxDepth: 8,
        useMortonOrder: true
    )

    // Build octree without Morton ordering
    let octreeWithoutMorton = Octree(
        pointCloud: pointCloud,
        maxPointsPerNode: 10,
        maxDepth: 8,
        useMortonOrder: false
    )

    let statsWithMorton = octreeWithMorton.getStatistics()
    let statsWithoutMorton = octreeWithoutMorton.getStatistics()

    // Both should work correctly
    #expect(statsWithMorton.nodeCount > 0)
    #expect(statsWithoutMorton.nodeCount > 0)

    print("Octree with Morton ordering:")
    print("  Nodes: \(statsWithMorton.nodeCount), Max depth: \(statsWithMorton.maxDepth)")
    print("Octree without Morton ordering:")
    print("  Nodes: \(statsWithoutMorton.nodeCount), Max depth: \(statsWithoutMorton.maxDepth)")

    // Clean up

}

@Test func queryCellsWithLevels() async throws {
    // Set PROJ_DATA
    let bundlePath = Bundle.module.bundlePath as NSString
    let projDbPath = bundlePath.deletingLastPathComponent
        .appending("/SwiftPDAL_SwiftPDAL.bundle")
    setenv("PROJ_DATA", projDbPath, 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    let octree = Octree(
        pointCloud: pointCloud,
        maxPointsPerNode: 100,
        maxDepth: 8,
        useMortonOrder: true
    )

    // Test executeFunctionForAllCellsAtLevel (level-based traversal)
    var cellsAtLevel3: [OctreeCell] = []
    var cellsAtLevel4: [OctreeCell] = []
    var cellsAtLevel5: [OctreeCell] = []

    octree.executeFunctionForAllCellsAtLevel(3) { cell in
        cellsAtLevel3.append(cell)
    }

    octree.executeFunctionForAllCellsAtLevel(4) { cell in
        cellsAtLevel4.append(cell)
    }

    octree.executeFunctionForAllCellsAtLevel(5) { cell in
        cellsAtLevel5.append(cell)
    }

    #expect(cellsAtLevel3.count > 0)
    #expect(cellsAtLevel4.count > 0)
    #expect(cellsAtLevel5.count > 0)

    // Verify all cells are at correct level
    for cell in cellsAtLevel3 {
        #expect(cell.level == 3)
    }

    for cell in cellsAtLevel4 {
        #expect(cell.level == 4)
    }

    for cell in cellsAtLevel5 {
        #expect(cell.level == 5)
    }

    print("Found cells - Level 3: \(cellsAtLevel3.count), Level 4: \(cellsAtLevel4.count), Level 5: \(cellsAtLevel5.count)")


}

@Test func lodSelection() async throws {
    let config = LODSelector.Config.default
    let lodSelector = LODSelector(config: config)

    // Test distance-based level selection
    let closeLevel = lodSelector.selectLevel(distance: 5)
    let mediumLevel = lodSelector.selectLevel(distance: 75)
    let farLevel = lodSelector.selectLevel(distance: 750)

    // Closer distances should select higher detail levels
    #expect(closeLevel > mediumLevel)
    #expect(mediumLevel > farLevel)

    print("LOD levels - Close: \(closeLevel), Medium: \(mediumLevel), Far: \(farLevel)")
}

@Test func lodCellSelection() async throws {
    // Set PROJ_DATA
    let bundlePath = Bundle.module.bundlePath as NSString
    let projDbPath = bundlePath.deletingLastPathComponent
        .appending("/SwiftPDAL_SwiftPDAL.bundle")
    setenv("PROJ_DATA", projDbPath, 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    let octree = Octree(
        pointCloud: pointCloud,
        maxPointsPerNode: 100,
        maxDepth: 8
    )

    let cameraPosition = simd_float3(430000, 45, -6567000)

    // Collect all leaf cells from all levels
    var allCells: [OctreeCell] = []
    for level in 0...8 {
        octree.executeFunctionForAllCellsAtLevel(UInt8(level)) { cell in
            allCells.append(cell)
        }
    }

    // Apply LOD selection
    let lodSelector = LODSelector(config: .default)
    let selectedCells = lodSelector.selectCells(allCells, cameraPosition: cameraPosition)

    #expect(allCells.count > 0)
    #expect(selectedCells.count > 0)
    #expect(selectedCells.count <= allCells.count)

    print("All cells: \(allCells.count), LOD selected: \(selectedCells.count)")


}

@Test func executeFunctionForLevel() async throws {
    // Set PROJ_DATA
    let bundlePath = Bundle.module.bundlePath as NSString
    let projDbPath = bundlePath.deletingLastPathComponent
        .appending("/SwiftPDAL_SwiftPDAL.bundle")
    setenv("PROJ_DATA", projDbPath, 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    let octree = Octree(
        pointCloud: pointCloud,
        maxPointsPerNode: 100,
        maxDepth: 8
    )

    var cellCount = 0
    var totalPoints = 0

    octree.executeFunctionForAllCellsAtLevel(5) { cell in
        cellCount += 1
        totalPoints += cell.pointCount
        #expect(cell.level == 5)
    }

    #expect(cellCount > 0)
    #expect(totalPoints > 0)

    print("Level 5 cells: \(cellCount), points: \(totalPoints)")


}

@Test func queryCellsWithClosure() async throws {
    // Set PROJ_DATA
    let bundlePath = Bundle.module.bundlePath as NSString
    let projDbPath = bundlePath.deletingLastPathComponent
        .appending("/SwiftPDAL_SwiftPDAL.bundle")
    setenv("PROJ_DATA", projDbPath, 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    let octree = Octree(
        pointCloud: pointCloud,
        maxPointsPerNode: 100,
        maxDepth: 8
    )

    // Query cells with custom filter - only cells with more than 5 points
    let cells = octree.queryCells(minLevel: 3, maxLevel: 6) { cell in
        cell.pointCount > 5
    }

    #expect(cells.count > 0)

    // Verify all cells match filter criteria
    for cell in cells {
        #expect(cell.pointCount > 5)
        #expect(cell.level >= 3)
        #expect(cell.level <= 6)
    }

    print("Found \(cells.count) cells with >5 points between levels 3-6")

    // Query cells in a specific bounding region
    let targetCenter = simd_float3(430000, 45, -6567000)
    let searchRadius: Float = 100.0

    let nearCells = octree.queryCells(maxLevel: 5) { cell in
        let distance = simd_distance(cell.bounds.center, targetCenter)
        return distance < searchRadius
    }

    #expect(nearCells.count > 0)

    print("Found \(nearCells.count) cells within \(searchRadius) units of target")


}

@Test func getAllCellsMethods() async throws {
    // Set PROJ_DATA
    let bundlePath = Bundle.module.bundlePath as NSString
    let projDbPath = bundlePath.deletingLastPathComponent
        .appending("/SwiftPDAL_SwiftPDAL.bundle")
    setenv("PROJ_DATA", projDbPath, 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    let octree = Octree(
        pointCloud: pointCloud,
        maxPointsPerNode: 100,
        maxDepth: 8
    )

    // Test getAllCells(atLevel:)
    let cellsAtLevel5 = octree.getAllCells(atLevel: 5)
    #expect(cellsAtLevel5.count > 0)
    for cell in cellsAtLevel5 {
        #expect(cell.level == 5)
    }
    print("Cells at level 5: \(cellsAtLevel5.count)")

    // Test getAllLeafCells()
    let leafCells = octree.getAllLeafCells()
    #expect(leafCells.count > 0)
    for cell in leafCells {
        #expect(cell.pointCount > 0) // Leaf cells should have points
    }
    print("Total leaf cells: \(leafCells.count)")

    // Test getAllCells() - all cells
    let allCells = octree.getAllCells()
    #expect(allCells.count > 0)
    #expect(allCells.count >= leafCells.count) // Should have at least as many as leaf cells
    print("Total cells (all levels): \(allCells.count)")

    // Test getAllCells(minLevel:maxLevel:)
    let cellsRange = octree.getAllCells(minLevel: 3, maxLevel: 6)
    #expect(cellsRange.count > 0)
    for cell in cellsRange {
        #expect(cell.level >= 3)
        #expect(cell.level <= 6)
    }
    print("Cells between levels 3-6: \(cellsRange.count)")


}

@Test func octreeCellBoundingBoxRendering() async throws {
    // Set PROJ_DATA
    let bundlePath = Bundle.module.bundlePath as NSString
    let projDbPath = bundlePath.deletingLastPathComponent
        .appending("/SwiftPDAL_SwiftPDAL.bundle")
    setenv("PROJ_DATA", projDbPath, 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    let octree = Octree(
        pointCloud: pointCloud,
        maxPointsPerNode: 100,
        maxDepth: 8
    )

    // Get some cells to render
    let cells = octree.getAllCells(atLevel: 5)
    #expect(cells.count > 0)

    guard let device = MTLCreateSystemDefaultDevice() else {
        print("Metal device not available, skipping Metal buffer tests")
    
        return
    }

    // Test single cell bounding box
    if let cell = cells.first {
        // Get vertices
        let vertices = cell.boundingBoxVertices
        #expect(vertices.count == 8) // 8 corners
        print("Cell bounding box: 8 vertices")

        // Create vertex buffer
        let vertexBuffer = cell.createBoundingBoxVertexBuffer(device: device)
        #expect(vertexBuffer != nil)
        #expect(vertexBuffer!.length == 8 * MemoryLayout<simd_float3>.stride)
        print("Created vertex buffer: \(vertexBuffer!.length) bytes")

        // Create shared index buffer
        let indexBuffer = OctreeCell.createBoundingBoxIndexBuffer(device: device)
        #expect(indexBuffer != nil)
        #expect(indexBuffer!.length == 24 * MemoryLayout<UInt16>.stride)
        print("Created index buffer: \(indexBuffer!.length) bytes (12 lines)")
    }

    // Test batched bounding box rendering
    let batchedBuffers = cells.createBatchedBoundingBoxBuffers(device: device)
    #expect(batchedBuffers != nil)

    if let (vertexBuffer, indexBuffer, vertexCount) = batchedBuffers {
        #expect(vertexCount == cells.count * 8) // 8 vertices per cell
        print("Batched \(cells.count) cells:")
        print("  Vertex buffer: \(vertexBuffer.length) bytes (\(vertexCount) vertices)")
        print("  Index buffer: \(indexBuffer.length) bytes (\(cells.totalBoundingBoxEdges) lines)")
    }

    // Test array utilities
    let totalEdges = cells.totalBoundingBoxEdges
    #expect(totalEdges == cells.count * 12)
    print("Total edges to render: \(totalEdges)")


}

// MARK: - Streaming Tests

@Test func streamingReadBasic() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    var chunkCount = 0
    var totalPointsReceived = 0
    var lastChunk: PointCloudChunk?
    var dimensions: [DimensionInfo]?

    // Use the new AsyncStream API
    let stream = StreamingPointCloud(
        filePath: testFilePath,
        readerName: "readers.las",
        chunkSize: 1000
    )

    for try await progress in stream.load() {
        chunkCount += 1
        totalPointsReceived += progress.chunk.pointCount
        lastChunk = progress.chunk

        // Save dimensions from first chunk
        if dimensions == nil {
            dimensions = progress.dimensions
        }

        print("Chunk \(chunkCount): \(progress.chunk.pointCount) points (total: \(progress.chunk.totalPointsSoFar))")
    }

    // Verify we received chunks
    #expect(chunkCount > 0)
    #expect(totalPointsReceived > 0)

    // Verify last chunk was marked complete
    #expect(lastChunk?.isComplete == true)

    // Verify dimensions were received
    #expect(dimensions != nil)
    #expect(dimensions!.count > 0)

    // Verify bounds are valid after completion
    let bounds = stream.bounds
    #expect(bounds.min.x < bounds.max.x)
    #expect(bounds.min.y < bounds.max.y)
    #expect(bounds.min.z < bounds.max.z)

    print("\nStreaming Summary:")
    print("  Total chunks: \(chunkCount)")
    print("  Total points: \(totalPointsReceived)")
    print("  Dimensions: \(dimensions?.count ?? 0)")
    print("  Bounds: [\(bounds.min.x), \(bounds.min.y), \(bounds.min.z)] to [\(bounds.max.x), \(bounds.max.y), \(bounds.max.z)]")
}

@Test func streamingReadWithCancellation() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let maxChunks = 3
    var chunkCount = 0

    let stream = StreamingPointCloud(
        filePath: testFilePath,
        readerName: "readers.las",
        chunkSize: 1000
    )

    // Simply break after maxChunks
    for try await progress in stream.load() {
        chunkCount += 1
        print("Chunk \(chunkCount): \(progress.chunk.pointCount) points")

        // Cancel after 3 chunks
        if chunkCount >= maxChunks {
            break
        }
    }

    // Verify we stopped at the right number of chunks
    #expect(chunkCount == maxChunks)

    print("Successfully stopped after \(chunkCount) chunks")
}

@Test func streamingReadChunkDataAccess() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    var firstChunkData: Data?
    var firstChunkDimensions: [DimensionInfo]?

    let stream = StreamingPointCloud(
        filePath: testFilePath,
        readerName: "readers.las",
        chunkSize: 100
    )

    for try await progress in stream.load() {
        // On first chunk, copy the data for inspection
        if firstChunkData == nil {
            let dataSize = progress.chunk.pointCount * progress.chunk.stride
            firstChunkData = Data(bytes: progress.chunk.data, count: dataSize)
            firstChunkDimensions = progress.dimensions

            print("First chunk captured:")
            print("  Points: \(progress.chunk.pointCount)")
            print("  Stride: \(progress.chunk.stride)")
            print("  Data size: \(dataSize) bytes")
            print("  Dimensions:")
            for dim in progress.dimensions {
                print("    - \(dim.name): offset=\(dim.offset), size=\(dim.outputSize)")
            }

            // Verify we can access the raw data
            #expect(firstChunkData!.count > 0)
            #expect(firstChunkData!.count == dataSize)

            // Stop after first chunk
            break
        }
    }

    // Verify we captured the data
    #expect(firstChunkData != nil)
    #expect(firstChunkDimensions != nil)
    #expect(firstChunkDimensions!.count > 0)
}

@Test func streamingReadProgressTracking() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    var progressUpdates: [(chunk: Int, points: Int, complete: Bool)] = []

    let stream = StreamingPointCloud(
        filePath: testFilePath,
        readerName: "readers.las",
        chunkSize: 500
    )

    for try await progress in stream.load() {
        progressUpdates.append((
            chunk: progressUpdates.count + 1,
            points: progress.chunk.totalPointsSoFar,
            complete: progress.chunk.isComplete
        ))
    }

    // Verify progress tracking
    #expect(progressUpdates.count > 0)

    // Verify totalPointsSoFar increases monotonically
    for i in 1..<progressUpdates.count {
        #expect(progressUpdates[i].points > progressUpdates[i-1].points)
    }

    // Only last chunk should be marked complete
    for i in 0..<progressUpdates.count-1 {
        #expect(progressUpdates[i].complete == false)
    }
    #expect(progressUpdates.last?.complete == true)

    print("Progress tracking:")
    for update in progressUpdates {
        let status = update.complete ? "COMPLETE" : "ongoing"
        print("  Chunk \(update.chunk): \(update.points) points total [\(status)]")
    }
}

@Test func streamingVsNormalReadComparison() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    // Normal read
    let normalCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    // Streaming read
    var streamingTotalPoints = 0
    var streamingStride = 0
    var streamingDimensions: [DimensionInfo]?

    let stream = StreamingPointCloud(
        filePath: testFilePath,
        readerName: "readers.las",
        chunkSize: 1000
    )

    for try await progress in stream.load() {
        streamingTotalPoints = progress.chunk.totalPointsSoFar
        streamingStride = progress.chunk.stride
        if streamingDimensions == nil {
            streamingDimensions = progress.dimensions
        }
    }

    let streamingBounds = stream.bounds

    // Compare results
    #expect(streamingTotalPoints == normalCloud.pointCount)
    #expect(streamingStride == normalCloud.stride)
    #expect(streamingDimensions?.count == normalCloud.dimensions.count)

    // Bounds should be approximately the same
    let epsilon: Float = 0.001
    #expect(abs(streamingBounds.min.x - normalCloud.bounds.min.x) < epsilon)
    #expect(abs(streamingBounds.min.y - normalCloud.bounds.min.y) < epsilon)
    #expect(abs(streamingBounds.min.z - normalCloud.bounds.min.z) < epsilon)
    #expect(abs(streamingBounds.max.x - normalCloud.bounds.max.x) < epsilon)
    #expect(abs(streamingBounds.max.y - normalCloud.bounds.max.y) < epsilon)
    #expect(abs(streamingBounds.max.z - normalCloud.bounds.max.z) < epsilon)

    print("\nComparison:")
    print("  Point count - Normal: \(normalCloud.pointCount), Streaming: \(streamingTotalPoints)")
    print("  Stride - Normal: \(normalCloud.stride), Streaming: \(streamingStride)")
    print("  Dimensions - Normal: \(normalCloud.dimensions.count), Streaming: \(streamingDimensions?.count ?? 0)")


}

@Test func streamingReadE57File() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)

    guard let testFilePath = Bundle.module.path(forResource: "bunnyFloat", ofType: "e57") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    var chunkCount = 0
    var totalPoints = 0

    let stream = StreamingPointCloud(filePath: testFilePath, chunkSize: 2000)

    for try await progress in stream.load() {
        chunkCount += 1
        totalPoints = progress.chunk.totalPointsSoFar
    }

    let bounds = stream.bounds

    #expect(chunkCount > 0)
    #expect(totalPoints > 0)
    #expect(bounds.min.x < bounds.max.x)

    print("E57 Streaming: \(chunkCount) chunks, \(totalPoints) points")
}
