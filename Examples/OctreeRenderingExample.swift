import Foundation
import SwiftPDAL
import Metal
import simd

@main
struct OctreeRenderingExample {
    static func main() {
        print("=== Octree Rendering Example ===\n")

        // Get the path to the Stanford Dragon PLY file
        let currentDirectory = FileManager.default.currentDirectoryPath
        let plyPath = "\(currentDirectory)/Tests/SwiftPDALTests/Resources/Stanford_Dragon.ply"

        guard FileManager.default.fileExists(atPath: plyPath) else {
            print("❌ Error: Stanford_Dragon.ply not found at \(plyPath)")
            return
        }

        print("📂 Loading point cloud from: \(plyPath)")

        do {
            // Read the point cloud
            var pointCloud = try PointCloud.read(from: plyPath, readerName: "readers.ply")
            defer { pointCloud.cleanup() }

            print("✅ Point cloud loaded successfully!")
            print("   Points: \(pointCloud.pointCount)")
            print("   Bounds: min(\(pointCloud.bounds.min.x), \(pointCloud.bounds.min.y), \(pointCloud.bounds.min.z))")
            print("           max(\(pointCloud.bounds.max.x), \(pointCloud.bounds.max.y), \(pointCloud.bounds.max.z))")
            print("   Dimensions: \(pointCloud.dimensions.map { String($0.name) }.joined(separator: ", "))")
            print()

            // Build octree
            print("🌳 Building octree...")
            let startTime = Date()
            let octree = pointCloud.buildOctree(maxPointsPerNode: 1000, maxDepth: 8, useMortonOrder: true)
            let buildTime = Date().timeIntervalSince(startTime)

            let stats = octree.getStatistics()
            print("✅ Octree built in \(String(format: "%.3f", buildTime)) seconds")
            print("   Total nodes: \(stats.nodeCount)")
            print("   Leaf nodes: \(stats.leafCount)")
            print("   Max depth: \(stats.maxDepth)")
            print("   Avg points per leaf: \(String(format: "%.1f", stats.averagePointsPerLeaf))")
            print()

            // Test cell queries at different levels
            print("📊 Querying cells at different octree levels:")
            for level in 0...min(stats.maxDepth, 4) {
                let cells = octree.getAllCells(atLevel: UInt8(level))
                print("   Level \(level): \(cells.count) cells")
            }
            print()

            // Get all leaf cells for rendering
            print("🎨 Getting leaf cells for rendering...")
            let leafCells = octree.getAllLeafCells()
            print("   Total leaf cells: \(leafCells.count)")

            // Show some sample cell information
            if !leafCells.isEmpty {
                print("\n📦 Sample cell information:")
                for i in 0..<min(5, leafCells.count) {
                    let cell = leafCells[i]
                    let size = cell.bounds.size
                    print("   Cell \(i):")
                    print("     Level: \(cell.level)")
                    print("     Points: \(cell.pointCount)")
                    print("     Center: (\(String(format: "%.2f", cell.bounds.center.x)), \(String(format: "%.2f", cell.bounds.center.y)), \(String(format: "%.2f", cell.bounds.center.z)))")
                    print("     Size: (\(String(format: "%.2f", size.x)), \(String(format: "%.2f", size.y)), \(String(format: "%.2f", size.z)))")
                }
            }
            print()

            // Test Metal buffer creation for bounding boxes
            print("🔧 Testing Metal buffer creation for bounding boxes...")
            guard let device = MTLCreateSystemDefaultDevice() else {
                print("⚠️  Warning: No Metal device available, skipping buffer tests")
                testBoundingBoxGeometry(cells: leafCells)
                return
            }

            print("   Metal device: \(device.name)")

            // Create bounding box buffers for a subset of cells
            let testCells = Array(leafCells.prefix(10))

            if let batchBuffers = testCells.createBatchedBoundingBoxBuffers(device: device) {
                print("   ✅ Created batched bounding box buffers:")
                print("      Vertex buffer size: \(batchBuffers.vertexBuffer.length) bytes")
                print("      Index buffer size: \(batchBuffers.indexBuffer.length) bytes")
                print("      Total vertices: \(batchBuffers.vertexCount)")
                print("      Total edges: \(testCells.totalBoundingBoxEdges)")
            } else {
                print("   ❌ Failed to create batched buffers")
            }

            // Create individual cell buffer
            if let cell = leafCells.first,
               let vertexBuffer = cell.createBoundingBoxVertexBuffer(device: device),
               let indexBuffer = OctreeCell.createBoundingBoxIndexBuffer(device: device) {
                print("   ✅ Created individual cell buffers:")
                print("      Vertex buffer size: \(vertexBuffer.length) bytes")
                print("      Index buffer size: \(indexBuffer.length) bytes")
            }
            print()

            // Test bounding box geometry
            testBoundingBoxGeometry(cells: leafCells)

            // Test frustum culling
            testFrustumCulling(octree: octree, bounds: pointCloud.bounds)

            print("✨ Example completed successfully!")

        } catch {
            print("❌ Error: \(error)")
        }
    }

    static func testBoundingBoxGeometry(cells: [OctreeCell]) {
        print("📐 Testing bounding box geometry...")

        guard let cell = cells.first else {
            print("   ⚠️  No cells available")
            return
        }

        let vertices = cell.boundingBoxVertices
        let indices = OctreeCell.boundingBoxLineIndices

        print("   ✅ Bounding box geometry:")
        print("      Vertices: \(vertices.count)")
        print("      Indices: \(indices.count) (forming \(indices.count / 2) lines)")

        // Verify vertex positions
        let expectedMin = cell.bounds.min
        let expectedMax = cell.bounds.max

        print("      Vertex 0 (min corner): (\(vertices[0].x), \(vertices[0].y), \(vertices[0].z))")
        print("      Vertex 6 (max corner): (\(vertices[6].x), \(vertices[6].y), \(vertices[6].z))")

        assert(vertices[0] == expectedMin, "Min corner should match bounds.min")
        assert(vertices[6] == expectedMax, "Max corner should match bounds.max")

        print("      ✓ Geometry verification passed")
        print()
    }

    static func testFrustumCulling(octree: Octree, bounds: PointCloud.Bounds) {
        print("👁️  Testing frustum culling...")

        // Create a simple frustum from camera parameters
        let fov: Float = .pi / 3  // 60 degrees
        let aspect: Float = 16.0 / 9.0
        let near: Float = 0.1
        let far: Float = 1000.0

        let frustum = Frustum.fromCameraParameters(
            fov: fov,
            aspect: aspect,
            near: near,
            far: far,
            reversedZ: true
        )

        // Position camera to look at the point cloud
        let center = (bounds.min + bounds.max) * 0.5
        let size = bounds.max - bounds.min
        let distance = simd_length(size) * 2
        let cameraPosition = center + simd_float3(0, 0, distance)

        print("   Camera position: (\(String(format: "%.2f", cameraPosition.x)), \(String(format: "%.2f", cameraPosition.y)), \(String(format: "%.2f", cameraPosition.z)))")
        print("   Looking at: (\(String(format: "%.2f", center.x)), \(String(format: "%.2f", center.y)), \(String(format: "%.2f", center.z)))")

        // Query cells in frustum
        let visibleCells = octree.queryCells(
            frustum: frustum,
            cameraPosition: cameraPosition,
            minLevel: nil,
            maxLevel: nil
        )

        print("   ✅ Visible cells: \(visibleCells.count)")

        // Show level distribution
        var levelCounts: [UInt8: Int] = [:]
        for cell in visibleCells {
            levelCounts[cell.level, default: 0] += 1
        }

        print("   Level distribution:")
        for level in levelCounts.keys.sorted() {
            print("      Level \(level): \(levelCounts[level]!) cells")
        }

        // Test LOD-based queries
        print("\n   Testing LOD queries...")
        for maxLevel in 1...3 {
            let lodCells = octree.queryCells(
                frustum: frustum,
                cameraPosition: cameraPosition,
                minLevel: nil,
                maxLevel: UInt8(maxLevel)
            )
            print("      Max level \(maxLevel): \(lodCells.count) cells")
        }

        // Test custom filtering
        let largeCells = octree.queryCells(
            minLevel: nil,
            maxLevel: nil
        ) { cell in
            cell.pointCount > 500
        }
        print("      Large cells (>500 points): \(largeCells.count)")

        print()
    }
}
