# SwiftPDAL Examples

This directory contains example programs demonstrating SwiftPDAL functionality.

## OctreeRenderingExample

A comprehensive example demonstrating octree construction and rendering capabilities with point cloud data.

### What it demonstrates

- **Point Cloud Loading**: Loading PLY files using PDAL
- **Octree Construction**: Building an efficient spatial index with Morton ordering
- **Cell Queries**: Retrieving octree cells at different levels of detail
- **Bounding Box Rendering**: Creating Metal buffers for rendering cell bounds
- **Frustum Culling**: Querying visible cells for efficient rendering
- **LOD Selection**: Using level-of-detail queries for performance optimization

### Running the example

```bash
swift run OctreeRenderingExample
```

### Sample Output

The example uses the Stanford Dragon PLY file (~157K points) and demonstrates:

- Octree statistics (nodes, depth, point distribution)
- Cell information at different octree levels
- Metal buffer creation for bounding box visualization
- Frustum culling with level distribution
- LOD-based queries for dynamic detail selection

### Key Features Tested

#### 1. Octree Cell Queries

```swift
// Get all cells at a specific level
let cells = octree.getAllCells(atLevel: 3)

// Get all leaf cells
let leafCells = octree.getAllLeafCells()

// Get cells in view frustum
let visibleCells = octree.queryCells(
    frustum: frustum,
    cameraPosition: cameraPosition
)
```

#### 2. Bounding Box Rendering

```swift
// Create batched buffers for multiple cells
let (vertexBuffer, indexBuffer, vertexCount) =
    cells.createBatchedBoundingBoxBuffers(device: device)

// Create individual cell buffers
let vertexBuffer = cell.createBoundingBoxVertexBuffer(device: device)
let indexBuffer = OctreeCell.createBoundingBoxIndexBuffer(device: device)
```

#### 3. LOD Selection

```swift
// Query cells up to a maximum level
let lodCells = octree.queryCells(
    frustum: frustum,
    cameraPosition: cameraPosition,
    minLevel: nil,
    maxLevel: 3
)

// Custom filtering
let largeCells = octree.queryCells { cell in
    cell.pointCount > 500
}
```

### Use Cases

This example serves as a foundation for:

- **Real-time Point Cloud Rendering**: Efficient culling and LOD selection
- **3D Visualization**: Bounding box visualization for debugging
- **Spatial Queries**: Finding points or cells in specific regions
- **Performance Optimization**: Morton ordering for cache-friendly traversal

### Data

The example uses the Stanford Dragon model included in the test resources:
- File: `Tests/SwiftPDALTests/Resources/Stanford_Dragon.ply`
- Points: 156,623
- Dimensions: Position (X, Y, Z), Normals, Colors
