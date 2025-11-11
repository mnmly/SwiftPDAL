# Point Cloud Rendering Features

This document describes the rendering pipeline features implemented in SwiftPDAL for efficient, Level-of-Detail (LOD) based point cloud rendering.

## Overview

The rendering system provides:
- **Morton Code spatial indexing** for cache-friendly data layout
- **Cell-based octree traversal** with hierarchical codes
- **Frustum culling** with level-aware queries
- **LOD (Level of Detail) selection** for adaptive rendering
- **Metal GPU buffer management** organized by octree level

## Components

### 1. Morton Code ([MortonCode.swift](Sources/SwiftPDAL/MortonCode.swift))

Morton codes (Z-order curve) provide a 1D ordering that preserves 3D spatial locality.

```swift
// Create Morton code from 3D point
let morton = MortonCode(point: position, bounds: octreeBounds)

// Sort points by Morton code for better cache locality
let sortedIndices = MortonSorter.sortIndices(
    indices,
    positions: positions,
    bounds: bounds
)
```

**Benefits:**
- Points close in 3D space have nearby Morton codes
- Better CPU cache locality during traversal
- Efficient binary search on spatial data
- Simplified serialization

### 2. Octree with Cell Codes ([Octree.swift](Sources/SwiftPDAL/Octree.swift))

Enhanced octree with hierarchical cell codes and level-based operations.

#### Cell Code System

```swift
// Each node has a unique cell code
public struct CellCode {
    let code: UInt64    // Morton-like hierarchical code
    let level: UInt8    // Depth in octree
}

// Octree cell with metadata
public struct OctreeCell {
    let bounds: AABB
    let level: UInt8
    let cellCode: CellCode
    let pointIndices: [Int]
    let pointCount: Int

    func distance(to cameraPosition: simd_float3) -> Float
}
```

#### Level-Based Traversal

```swift
// Get all cells at a specific level
let cellsAtLevel5 = octree.getAllCells(atLevel: 5)
print("Found \(cellsAtLevel5.count) cells at level 5")

// Get all leaf cells (cells with actual points)
let leafCells = octree.getAllLeafCells()
print("Total leaf cells: \(leafCells.count)")

// Get all cells in the octree
let allCells = octree.getAllCells()
print("Total cells: \(allCells.count)")

// Get cells within a level range
let cellsRange = octree.getAllCells(minLevel: 3, maxLevel: 6)
print("Cells between levels 3-6: \(cellsRange.count)")

// Execute function for all cells at specific level (callback style)
octree.executeFunctionForAllCellsAtLevel(5) { cell in
    // Process cell at level 5
    print("Cell \(cell.cellCode) has \(cell.pointCount) points")
}
```

#### Enhanced Frustum Culling

```swift
// Query cells within frustum with level constraints
let cells = octree.queryCells(
    frustum: camera.frustum,
    cameraPosition: camera.position,
    minLevel: 3,  // Only cells at level 3 or deeper
    maxLevel: 7   // Stop at level 7
)
```

#### Custom Query with Closure

```swift
// Query cells with custom filter - only cells with many points
let denseCells = octree.queryCells(minLevel: 3, maxLevel: 6) { cell in
    cell.pointCount > 100
}

// Query cells in a specific spatial region
let targetCenter = simd_float3(x, y, z)
let searchRadius: Float = 50.0

let nearCells = octree.queryCells(maxLevel: 5) { cell in
    let distance = simd_distance(cell.bounds.center, targetCenter)
    return distance < searchRadius
}

// Combine multiple filters
let filteredCells = octree.queryCells(minLevel: 4) { cell in
    // Only cells that are within bounds AND have enough points
    cell.bounds.contains(myPoint) && cell.pointCount >= 10
}
```

### 3. LOD Selector ([LODSelector.swift](Sources/SwiftPDAL/LODSelector.swift))

Distance-based Level of Detail selection for adaptive rendering.

#### LOD Configuration

```swift
// Pre-configured LOD strategies
let config = LODSelector.Config.default     // Balanced
let config = LODSelector.Config.performance // Lower detail, faster
let config = LODSelector.Config.quality     // Higher detail, slower

// Custom configuration
let config = LODSelector.Config(
    distanceThresholds: [
        (10, 10),   // High detail within 10 units
        (50, 7),    // Medium detail within 50 units
        (100, 5),   // Low detail within 100 units
        (500, 3)    // Very low detail beyond
    ],
    maxLevel: 10,
    minLevel: 0
)
```

#### Cell Selection

```swift
let lodSelector = LODSelector(config: .default)

// Select appropriate detail level for each cell
let selectedCells = lodSelector.selectCellsHierarchical(
    visibleCells,
    cameraPosition: camera.position
)
```

The hierarchical selection prevents rendering both parent and child cells simultaneously.

### 4. Example Renderer Implementation

Here's an example of how to implement a Metal-based renderer with GPU buffer management per octree level.

#### Example Setup

```swift
let device = MTLCreateSystemDefaultDevice()!
let renderer = PointCloudRenderer(
    device: device,
    octree: octree,
    pointCloud: pointCloud,
    lodConfig: .default
)

// Prepare GPU buffers for specific levels
try renderer.prepareBuffers(forLevels: [5, 6, 7, 8])
```

#### Rendering Loop

```swift
func render(commandBuffer: MTLCommandBuffer, renderEncoder: MTLRenderCommandEncoder) {
    let camera = Camera(
        position: cameraPosition,
        viewProjection: viewProjectionMatrix
    )

    // Render with automatic LOD selection
    let pointsRendered = renderer.render(
        camera: camera,
        commandBuffer: commandBuffer,
        renderEncoder: renderEncoder
    )

    print("Rendered \(pointsRendered) points")
}
```

#### Statistics

```swift
let stats = renderer.getStats(camera: camera)
print("Visible cells: \(stats.visibleCells)")
print("Total points: \(stats.totalPoints)")
print("Cells by level: \(stats.cellsByLevel)")
print("GPU buffers: \(stats.buffersInMemory)")
```

## Example Renderer Class

```swift
import Metal
import simd

/// Example Metal-based point cloud renderer with LOD support
class PointCloudRenderer {

    struct GPUBuffer {
        let buffer: MTLBuffer
        let pointCount: Int
        let level: UInt8
    }

    private let device: MTLDevice
    private let octree: Octree
    private let pointCloud: PointCloud
    private let lodSelector: LODSelector
    private var gpuBuffers: [UInt8: GPUBuffer] = [:]
    private let vertexStride: Int

    init(device: MTLDevice, octree: Octree, pointCloud: PointCloud, lodConfig: LODSelector.Config = .default) {
        self.device = device
        self.octree = octree
        self.pointCloud = pointCloud
        self.lodSelector = LODSelector(config: lodConfig)
        self.vertexStride = pointCloud.stride
    }

    func prepareBuffers(forLevels levels: [UInt8]) throws {
        for level in levels {
            var pointIndices: [Int] = []

            octree.executeFunctionForAllCellsAtLevel(level) { cell in
                pointIndices.append(contentsOf: cell.pointIndices)
            }

            guard !pointIndices.isEmpty else { continue }

            let bufferSize = pointIndices.count * vertexStride
            guard let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
                throw PointCloudError.readFailed("Failed to create buffer")
            }

            // Copy point data to buffer
            let bufferPointer = buffer.contents()
            let sourceData = pointCloud.data.assumingMemoryBound(to: UInt8.self)

            for (i, pointIndex) in pointIndices.enumerated() {
                bufferPointer.advanced(by: i * vertexStride).copyMemory(
                    from: sourceData.advanced(by: pointIndex * vertexStride),
                    byteCount: vertexStride
                )
            }

            gpuBuffers[level] = GPUBuffer(buffer: buffer, pointCount: pointIndices.count, level: level)
        }
    }

    func getVisibleCells(camera: Camera) -> [OctreeCell] {
        let visibleCells = octree.queryCells(frustum: camera.frustum, cameraPosition: camera.position)
        return lodSelector.selectCellsHierarchical(visibleCells, cameraPosition: camera.position)
    }

    @discardableResult
    func render(camera: Camera, commandBuffer: MTLCommandBuffer, renderEncoder: MTLRenderCommandEncoder) -> Int {
        let visibleCells = getVisibleCells(camera: camera)
        var totalPointsRendered = 0

        var cellsByLevel: [UInt8: [OctreeCell]] = [:]
        for cell in visibleCells {
            cellsByLevel[cell.level, default: []].append(cell)
        }

        for (level, cells) in cellsByLevel.sorted(by: { $0.key < $1.key }) {
            guard let gpuBuffer = gpuBuffers[level] else { continue }

            renderEncoder.setVertexBuffer(gpuBuffer.buffer, offset: 0, index: 0)

            let pointsToRender = cells.reduce(0) { $0 + $1.pointCount }
            if pointsToRender > 0 {
                renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointsToRender)
                totalPointsRendered += pointsToRender
            }
        }

        return totalPointsRendered
    }
}
```

## Complete Usage Example

```swift
// 1. Load point cloud
var pointCloud = try PointCloud.read(from: "data.laz", readerName: "readers.las")

// 2. Build octree with Morton ordering
let octree = Octree(
    pointCloud: pointCloud,
    maxPointsPerNode: 100,
    maxDepth: 10,
    useMortonOrder: true  // Enable Morton code sorting
)

// 3. Create renderer
let device = MTLCreateSystemDefaultDevice()!
let renderer = PointCloudRenderer(
    device: device,
    octree: octree,
    pointCloud: pointCloud,
    lodConfig: .quality  // High quality LOD
)

// 4. Prepare GPU buffers for desired levels
try renderer.prepareBuffers(forLevels: Array(5...10))

// 5. Render each frame
func drawFrame(camera: Camera) {
    let commandBuffer = commandQueue.makeCommandBuffer()!
    let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!

    // Get visible cells with LOD
    let visibleCells = renderer.getVisibleCells(camera: camera)

    // Render
    renderer.render(
        camera: camera,
        commandBuffer: commandBuffer,
        renderEncoder: renderEncoder
    )

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
}

// 6. Cleanup
renderer.releaseAllBuffers()
pointCloud.cleanup()
```

## Performance Characteristics

### Morton Code Benefits
- **Cache Locality**: Points close in space are close in memory
- **Faster Construction**: Sorted data enables optimized octree building
- **Efficient Queries**: Binary search on sorted codes

### LOD System Benefits
- **Reduced Overdraw**: Render only appropriate detail level
- **Distance Culling**: Automatically reduce detail for distant objects
- **Hierarchical Culling**: Prevent parent/child redundancy
- **Adaptive Performance**: Balance quality vs. framerate

### Typical Performance
With a 2M point cloud (8-level octree):
- **All cells**: ~4,400 cells across all levels
- **After LOD**: ~60 cells selected for rendering
- **Point reduction**: 97%+ reduction in points rendered
- **Frustum culling**: Additional 50-90% reduction depending on view

## Testing

All features are tested in [SwiftPDALTests.swift](Tests/SwiftPDALTests/SwiftPDALTests.swift):

```bash
swift test
```

Tests cover:
- Morton code encoding/decoding
- Morton code spatial locality
- Cell code ordering
- Level-based traversal
- LOD distance selection
- Hierarchical cell selection
- Octree with Morton ordering

## Bounding Box Rendering

For debugging and visualization, you can render the bounding boxes of octree cells. This is provided in [OctreeCell+Rendering.swift](Sources/SwiftPDAL/OctreeCell+Rendering.swift).

### Single Cell Bounding Box

```swift
let cell: OctreeCell = // ... get cell from octree

// Get 8 corner vertices
let vertices = cell.boundingBoxVertices // [simd_float3] (8 vertices)

// Create Metal buffer
guard let device = MTLCreateSystemDefaultDevice() else { return }
let vertexBuffer = cell.createBoundingBoxVertexBuffer(device: device)

// Get shared index buffer for line rendering (12 edges = 24 indices)
let indexBuffer = OctreeCell.createBoundingBoxIndexBuffer(device: device)

// Render with Metal
renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
renderEncoder.drawIndexedPrimitives(
    type: .line,
    indexCount: 24,
    indexType: .uint16,
    indexBuffer: indexBuffer!,
    indexBufferOffset: 0
)
```

### Batch Rendering Multiple Cells

```swift
// Get cells to visualize
let cells = octree.getAllCells(atLevel: 5)

// Create batched buffers
let device = MTLCreateSystemDefaultDevice()!
if let (vertexBuffer, indexBuffer, vertexCount) = cells.createBatchedBoundingBoxBuffers(device: device) {
    // Render all cells in one draw call
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    renderEncoder.drawIndexedPrimitives(
        type: .line,
        indexCount: cells.count * 24, // 24 indices per cell
        indexType: .uint16,
        indexBuffer: indexBuffer,
        indexBufferOffset: 0
    )

    print("Rendered \(cells.count) bounding boxes (\(cells.totalBoundingBoxEdges) lines)")
}
```

### Use Cases for Bounding Box Visualization

- **Debug octree structure**: Visualize how the octree subdivides space
- **LOD verification**: See which cells are selected at different distances
- **Frustum culling debug**: Verify which cells are visible
- **Spatial queries**: Highlight cells that match certain criteria

### Example: Visualize LOD Selection

```swift
let camera = Camera(position: cameraPosition, viewProjection: viewProjectionMatrix)
let lodSelector = LODSelector(config: .default)

// Get visible cells with LOD
let visibleCells = octree.queryCells(frustum: camera.frustum, cameraPosition: camera.position)
let selectedCells = lodSelector.selectCellsHierarchical(visibleCells, cameraPosition: camera.position)

// Render bounding boxes to see LOD in action
if let buffers = selectedCells.createBatchedBoundingBoxBuffers(device: device) {
    // Color by level or distance
    // Render wireframe boxes
}
```

## Next Steps

Potential enhancements:
- **Multi-threaded processing**: Parallelize cell processing
- **Compute shaders**: GPU-based frustum culling and LOD
- **Instanced rendering**: Render multiple cells in one draw call
- **Point budget**: Limit total points per frame
- **Temporal coherence**: Reuse selections across frames
- **Progressive loading**: Stream octree levels on demand
