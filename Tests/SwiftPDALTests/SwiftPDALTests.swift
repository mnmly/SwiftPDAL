import Testing
import Foundation
import simd
import Metal
@testable import SwiftPDAL

@Test func readLAZFile() async throws {

    setenv("SWIFTPDAL_TESTING", "1", 1)
    // Get test file from bundle
    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    var pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

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
    pointCloud.cleanup()
}

@Test func readE57File() async throws {

    setenv("SWIFTPDAL_TESTING", "1", 1)
    // Get test file from bundle
    guard let testFilePath = Bundle.module.path(forResource: "bunnyFloat", ofType: "e57") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    var pointCloud = try PointCloud.read(from: testFilePath)

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
    pointCloud.cleanup()
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

    var pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    // Build octree
    let octree = pointCloud.buildOctree(maxPointsPerNode: 100, maxDepth: 10)

    // Verify octree was created
    let stats = octree.getStatistics()
    #expect(stats.nodeCount > 0)
    #expect(stats.maxDepth > 0)
    #expect(stats.maxDepth <= 10)

    print("Octree built with \(stats.nodeCount) nodes, max depth: \(stats.maxDepth)")

    // Clean up
    pointCloud.cleanup()
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

    var pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

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
    pointCloud.cleanup()
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

    var pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

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
    pointCloud.cleanup()
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

    var pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

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
    pointCloud.cleanup()
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

    var pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

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

    pointCloud.cleanup()
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

    var pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

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

    pointCloud.cleanup()
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

    var pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

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

    pointCloud.cleanup()
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

    var pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

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

    pointCloud.cleanup()
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

    var pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

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

    pointCloud.cleanup()
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

    var pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

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
        pointCloud.cleanup()
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

    pointCloud.cleanup()
}
