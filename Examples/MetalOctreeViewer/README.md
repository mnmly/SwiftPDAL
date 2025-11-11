# MetalOctreeViewer

An interactive 3D point cloud viewer with octree visualization using Metal and SwiftUI.

![MetalOctreeViewer Screenshot](screenshot.png)

## Features

- **Real-time 3D Rendering**: Hardware-accelerated Metal rendering of point clouds
- **Interactive Camera**: Rotate, pan, and zoom with mouse/trackpad
- **Octree Visualization**: View octree cell bounding boxes
- **LOD Control**: Adjust maximum level-of-detail for performance
- **Frustum Culling**: Efficient rendering with view frustum culling
- **Point Cloud Statistics**: Real-time display of octree metrics

## Running the App

```bash
swift run MetalOctreeViewer
```

## Controls

### Mouse/Trackpad
- **Left Click + Drag**: Rotate camera around the point cloud
- **Right Click + Drag** or **⌘ + Left Click + Drag**: Pan camera
- **Scroll**: Zoom in/out

### UI Controls
- **Show Points**: Toggle point cloud rendering
- **Show Bounds**: Toggle octree bounding box visualization
- **Frustum Culling**: Enable/disable view frustum culling
- **Max LOD Level**: Adjust maximum octree depth to render (0-8)
- **Point Size**: Adjust rendered point size (1-10)
- **Reset Camera**: Reset camera to default view

## Architecture

### Components

#### MetalOctreeViewerApp.swift
Main SwiftUI app entry point with view model managing application state.

#### OctreeRenderer.swift
Metal rendering engine that:
- Manages Metal pipeline states for points and bounding boxes
- Loads and renders point cloud data
- Handles octree cell queries and culling
- Maintains separate vertex/index buffers for points and bounds

#### Camera.swift
Spherical camera controller with:
- Orbit controls (azimuth/elevation)
- Pan and zoom
- Perspective projection
- Auto-framing to point cloud bounds

#### InteractiveMetalView.swift
Custom MTKView subclass handling mouse/trackpad input for camera manipulation.

#### MetalViewRepresentable.swift
SwiftUI bridge connecting MTKView to SwiftUI lifecycle.

#### Shaders.metal
Metal shaders for:
- Point cloud rendering with per-vertex colors
- Semi-transparent bounding box line rendering

## Technical Details

### Rendering Pipeline

1. **Point Cloud Loading**
   - Loads PLY file using PDAL
   - Extracts position (X, Y, Z) and color (RGB) data
   - Creates Metal vertex buffer with interleaved data

2. **Octree Construction**
   - Builds spatial index with Morton ordering
   - Configurable max depth and points per node
   - Generates hierarchical cell structure

3. **Bounding Box Generation**
   - Creates batched vertex/index buffers for all octree leaf cells
   - 8 vertices per cell (box corners)
   - 24 indices per cell (12 edges, 2 vertices each)

4. **Frame Rendering**
   - Updates camera matrices
   - Renders point cloud with point primitives
   - Renders bounding boxes with line primitives and alpha blending

### Memory Layout

**Point Vertex Structure** (24 bytes):
```
struct Vertex {
    position: SIMD3<Float>  // 12 bytes (X, Y, Z)
    color: SIMD3<Float>     // 12 bytes (R, G, B)
}
```

**Bounding Box Vertex** (12 bytes):
```
position: SIMD3<Float>  // 12 bytes (X, Y, Z)
```

### Performance Optimizations

- **Morton Ordering**: Cache-friendly spatial ordering during octree construction
- **Batched Buffers**: Single draw call for all bounding boxes
- **Frustum Culling**: Only render visible octree cells (when enabled)
- **LOD Selection**: Limit traversal depth for large datasets

## Data

The app loads the Stanford Dragon model:
- **File**: `Tests/SwiftPDALTests/Resources/Stanford_Dragon.ply`
- **Points**: ~157K vertices
- **Octree Depth**: Up to 8 levels
- **Leaf Cells**: ~311 cells

## Extending the Viewer

### Custom Point Cloud Data

Modify [MetalViewRepresentable.swift:87](MetalViewRepresentable.swift#L87) to load different PLY/LAS files:

```swift
let plyPath = "/path/to/your/pointcloud.ply"
var pointCloud = try PointCloud.read(from: plyPath, readerName: "readers.ply")
```

### Octree Parameters

Adjust octree construction in [MetalViewRepresentable.swift:91](MetalViewRepresentable.swift#L91):

```swift
let octree = pointCloud.buildOctree(
    maxPointsPerNode: 1000,  // Increase for fewer, larger cells
    maxDepth: 8,             // Increase for finer subdivision
    useMortonOrder: true     // Enable for better cache locality
)
```

### Custom Rendering

Add new shader functions in [Shaders.metal](Shaders.metal) and pipeline states in [OctreeRenderer.swift](OctreeRenderer.swift) for:
- Normal visualization
- Intensity-based coloring
- Cell-level coloring
- Selection highlighting

## Requirements

- macOS 13.0+
- Swift 6.2+
- Metal-capable GPU
