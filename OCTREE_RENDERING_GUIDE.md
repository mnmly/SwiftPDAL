# Octree Rendering Guide

This guide demonstrates how to use SwiftPDAL's octree functionality for efficient point cloud rendering and visualization.

## Overview

SwiftPDAL provides two example applications that showcase octree-based rendering:

1. **OctreeRenderingExample** - Command-line tool demonstrating octree API
2. **MetalOctreeViewer** - Interactive 3D viewer with Metal rendering

## Quick Start

### Run the Command-Line Example

```bash
swift run OctreeRenderingExample
```

This demonstrates:
- Point cloud loading from PLY files
- Octree construction with statistics
- Cell queries at different levels
- Metal buffer creation for bounding boxes
- Frustum culling queries
- LOD selection

### Run the Interactive Viewer

```bash
swift run MetalOctreeViewer
```

This launches a full 3D viewer where you can:
- Rotate, pan, and zoom the point cloud
- Toggle point and bounding box rendering
- Adjust LOD levels in real-time
- See octree statistics

## Core Concepts

### 1. Octree Construction

The octree spatially subdivides your point cloud for efficient querying:

```swift
import SwiftPDAL

// Load point cloud
var pointCloud = try PointCloud.read(from: "dragon.ply", readerName: "readers.ply")
defer { pointCloud.cleanup() }

// Build octree
let octree = pointCloud.buildOctree(
    maxPointsPerNode: 1000,  // Max points before subdivision
    maxDepth: 8,             // Maximum tree depth
    useMortonOrder: true     // Enable Morton Z-order curve for cache efficiency
)

// Get statistics
let stats = octree.getStatistics()
print("Nodes: \(stats.nodeCount), Depth: \(stats.maxDepth)")
```

### 2. Cell Queries

Query octree cells for rendering:

```swift
// Get all cells at a specific level
let level3Cells = octree.getAllCells(atLevel: 3)

// Get all leaf cells (finest detail)
let leafCells = octree.getAllLeafCells()

// Get all cells in a range
let cells = octree.getAllCells(minLevel: 2, maxLevel: 5)
```

### 3. Frustum Culling

Efficiently render only visible cells:

```swift
import Metal
import simd

// Create frustum from camera parameters
let frustum = Frustum.fromCameraParameters(
    fov: .pi / 3,           // 60 degrees
    aspect: 16.0 / 9.0,     // Aspect ratio
    near: 0.1,              // Near plane
    far: 1000.0,            // Far plane
    reversedZ: true         // For Metal's reversed depth
)

// Query visible cells
let visibleCells = octree.queryCells(
    frustum: frustum,
    cameraPosition: cameraPos,
    minLevel: nil,          // Optional minimum level
    maxLevel: 5             // Optional maximum level (LOD)
)

print("Visible: \(visibleCells.count) cells")
```

### 4. LOD Selection

Control level-of-detail for performance:

```swift
// Low detail (fewer cells, better performance)
let lowDetail = octree.queryCells(
    frustum: frustum,
    cameraPosition: cameraPos,
    maxLevel: 3
)

// High detail (more cells, more detail)
let highDetail = octree.queryCells(
    frustum: frustum,
    cameraPosition: cameraPos,
    maxLevel: 7
)
```

### 5. Custom Filtering

Filter cells based on custom criteria:

```swift
// Find large cells
let largeCells = octree.queryCells { cell in
    cell.pointCount > 500
}

// Find cells at a specific distance
let nearCells = octree.queryCells { cell in
    cell.distance(to: cameraPos) < 100.0
}
```

## Rendering Bounding Boxes

### Individual Cell Buffer

```swift
guard let device = MTLCreateSystemDefaultDevice() else { return }

let cell = leafCells.first!

// Create vertex buffer (8 corner vertices)
let vertexBuffer = cell.createBoundingBoxVertexBuffer(device: device)

// Create index buffer (12 edges, 24 indices)
let indexBuffer = OctreeCell.createBoundingBoxIndexBuffer(device: device)

// Render
encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
encoder.drawIndexedPrimitives(
    type: .line,
    indexCount: 24,
    indexType: .uint16,
    indexBuffer: indexBuffer,
    indexBufferOffset: 0
)
```

### Batched Rendering (Efficient)

```swift
// Create batched buffers for multiple cells
if let buffers = leafCells.createBatchedBoundingBoxBuffers(device: device) {
    let (vertexBuffer, indexBuffer, vertexCount) = buffers

    // Single draw call for all cells
    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    encoder.drawIndexedPrimitives(
        type: .line,
        indexCount: leafCells.totalBoundingBoxEdges * 2,
        indexType: .uint16,
        indexBuffer: indexBuffer,
        indexBufferOffset: 0
    )
}
```

## Metal Shader Integration

### Bounding Box Vertex Layout

```metal
struct BBoxVertexIn {
    float3 position [[attribute(0)]];
};
```

Each cell has:
- **8 vertices**: Box corners (min to max)
- **24 indices**: 12 edges × 2 vertices per edge
- **12 lines**: Bottom face (4), top face (4), vertical edges (4)

### Point Cloud Vertex Layout

```metal
struct VertexIn {
    float3 position [[attribute(0)]];
    float3 color [[attribute(1)]];
};
```

## Performance Tips

### 1. Morton Ordering
Always enable Morton ordering for better cache locality:

```swift
let octree = pointCloud.buildOctree(useMortonOrder: true)
```

### 2. Appropriate Tree Depth
- **Small datasets (< 100K points)**: maxDepth = 6-7
- **Medium datasets (100K-1M points)**: maxDepth = 8-9
- **Large datasets (> 1M points)**: maxDepth = 10-12

### 3. Points Per Node
- **Rendering**: 500-1000 points per node
- **Spatial queries**: 100-500 points per node
- **Collision detection**: 10-50 points per node

### 4. LOD Strategy

```swift
func selectLOD(distance: Float) -> UInt8 {
    switch distance {
    case 0..<50: return 8      // Close: high detail
    case 50..<200: return 6    // Medium: medium detail
    case 200..<500: return 4   // Far: low detail
    default: return 2          // Very far: minimal detail
    }
}
```

### 5. Frustum Culling
Always use frustum culling for real-time rendering:

```swift
// ✅ Good: Only render visible cells
let cells = octree.queryCells(frustum: frustum, cameraPosition: cameraPos)

// ❌ Bad: Render all cells
let cells = octree.getAllLeafCells()
```

## Example: Complete Rendering Loop

```swift
class PointCloudRenderer {
    let octree: Octree
    var camera: Camera

    func render(encoder: MTLRenderCommandEncoder, view: MTKView) {
        // Create frustum from camera
        let aspect = Float(view.bounds.width / view.bounds.height)
        let frustum = Frustum.fromCameraParameters(
            fov: camera.fov,
            aspect: aspect,
            near: camera.nearPlane,
            far: camera.farPlane
        )

        // Select LOD based on performance budget
        let maxLevel = selectLOD(camera: camera)

        // Query visible cells
        let visibleCells = octree.queryCells(
            frustum: frustum,
            cameraPosition: camera.position,
            maxLevel: maxLevel
        )

        // Render bounding boxes
        if let buffers = visibleCells.createBatchedBoundingBoxBuffers(device: view.device!) {
            encoder.setVertexBuffer(buffers.vertexBuffer, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(
                type: .line,
                indexCount: visibleCells.totalBoundingBoxEdges * 2,
                indexType: .uint16,
                indexBuffer: buffers.indexBuffer,
                indexBufferOffset: 0
            )
        }

        // Render points within visible cells
        for cell in visibleCells {
            renderCellPoints(cell, encoder: encoder)
        }
    }
}
```

## Data Structures

### OctreeCell

```swift
public struct OctreeCell {
    public let bounds: AABB              // Cell bounding box
    public let level: UInt8              // Depth in tree (0 = root)
    public let cellCode: CellCode        // Morton code identifier
    public let pointIndices: [Int]       // Indices into point cloud
    public let pointCount: Int           // Number of points

    // Helper methods
    public func distance(to: simd_float3) -> Float
    public var boundingBoxVertices: [simd_float3]
    public func createBoundingBoxVertexBuffer(device: MTLDevice) -> MTLBuffer?
}
```

### AABB (Axis-Aligned Bounding Box)

```swift
public struct AABB {
    public var min: simd_float3
    public var max: simd_float3

    public var center: simd_float3
    public var size: simd_float3

    public func contains(_ point: simd_float3) -> Bool
    public func intersects(_ other: AABB) -> Bool
}
```

### Frustum

```swift
public struct Frustum {
    public let planes: [simd_float4]    // 6 frustum planes

    public init(viewProjection: simd_float4x4)
    public static func fromCameraParameters(...) -> Frustum
    public func intersects(_ bounds: AABB) -> Bool
}
```

## Common Use Cases

### 1. Point Cloud Visualization
```swift
// Load and visualize with LOD
let octree = pointCloud.buildOctree(maxPointsPerNode: 1000, maxDepth: 8)
let visibleCells = octree.queryCells(frustum: frustum, cameraPosition: cameraPos)
// Render cells...
```

### 2. Spatial Queries
```swift
// Find points in region
let cellsInRegion = octree.queryCells { cell in
    regionBounds.intersects(cell.bounds)
}
```

### 3. Collision Detection
```swift
// Find cells intersecting object
let octree = pointCloud.buildOctree(maxPointsPerNode: 50, maxDepth: 10)
let intersectingCells = octree.queryCells { cell in
    objectBounds.intersects(cell.bounds)
}
```

### 4. Progressive Loading
```swift
// Load low detail first
var currentLevel = 2
let cells = octree.getAllCells(atLevel: UInt8(currentLevel))
// Render...

// Then increase detail
currentLevel += 1
let moreCells = octree.getAllCells(atLevel: UInt8(currentLevel))
// Render...
```

## Files Reference

### Examples
- [Examples/OctreeRenderingExample.swift](Examples/OctreeRenderingExample.swift) - CLI example
- [Examples/MetalOctreeViewer/](Examples/MetalOctreeViewer/) - Interactive viewer

### Core Implementation
- [Sources/SwiftPDAL/Octree.swift](Sources/SwiftPDAL/Octree.swift) - Octree data structure
- [Sources/SwiftPDAL/OctreeCell+Rendering.swift](Sources/SwiftPDAL/OctreeCell+Rendering.swift) - Rendering helpers
- [Sources/SwiftPDAL/MortonCode.swift](Sources/SwiftPDAL/MortonCode.swift) - Morton Z-order curve
- [Sources/SwiftPDAL/LODSelector.swift](Sources/SwiftPDAL/LODSelector.swift) - LOD utilities

## Next Steps

1. **Run the examples** to see octree rendering in action
2. **Experiment with parameters** (maxDepth, maxPointsPerNode)
3. **Try your own point cloud data** (PLY, LAS, LAZ files)
4. **Integrate into your app** using the code patterns above

For more details, see:
- [Examples/README.md](Examples/README.md)
- [Examples/MetalOctreeViewer/README.md](Examples/MetalOctreeViewer/README.md)
