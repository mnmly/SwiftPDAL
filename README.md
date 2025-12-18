# SwiftPDAL

A Swift wrapper for PDAL (Point Data Abstraction Library) for reading and processing point cloud data.
Currently onlu built for macOS.

## Features

- **Multiple file format support**: LAS, LAZ, E57, PLY, and other PDAL-supported formats
- **Point data access**: Extract coordinates, colors, classifications, and custom attributes
- **Coordinate transformations**: Full EPSG support via embedded PROJ database
- **Streaming API**: Process large point clouds efficiently with streaming
- **Octree generation**: Build spatial indexes for efficient rendering and querying
- **Metal rendering**: Example Metal-based point cloud viewer included
- **Zero external dependencies**: Embedded PDAL and GDAL frameworks included

## Installation

### Swift Package Manager

Add SwiftPDAL to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mnmly/SwiftPDAL.git", from: "1.0.0")
]
```

And add it to your target dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: ["SwiftPDAL"],
    swiftSettings: [
        .interoperabilityMode(.Cxx)  // Required for C++ interop
    ]
)
```

## Usage

### Basic Point Cloud Reading

```swift
import SwiftPDAL

do {
    // Read a point cloud file (LAS, LAZ, E57, PLY, etc.)
    let pointCloud = try PointCloud.read(from: "/path/to/file.laz")

    print("Point count: \(pointCloud.pointCount)")
    print("Bounds: [\(pointCloud.bounds.minX), \(pointCloud.bounds.minY), \(pointCloud.bounds.minZ)]")
    print("        to [\(pointCloud.bounds.maxX), \(pointCloud.bounds.maxY), \(pointCloud.bounds.maxZ)]")

    // Access raw point data
    print("Data size: \(pointCloud.size) bytes")
    print("Stride: \(pointCloud.stride) bytes per point")

    // Clean up when done
    pointCloud.cleanup()

} catch {
    print("Error reading point cloud: \(error)")
}
```

### Streaming Large Files

```swift
let stream = try PointCloudStream(path: "/path/to/large-file.laz")

for try await chunk in stream {
    // Process each chunk of points
    print("Processing \(chunk.pointCount) points")
    // Access chunk.data, chunk.stride, etc.
}
```

### Building Octrees for Rendering

```swift
let pointCloud = try PointCloud.read(from: "/path/to/file.laz")
let octree = pointCloud.buildOctree(maxDepth: 8, minPointsPerNode: 1000)

// Use octree for level-of-detail rendering
let nodes = octree.getNodesAtLevel(4)
for node in nodes {
    // Render node.points
}
```

## Examples

This repository includes three example applications demonstrating different use cases:

### 1. OctreeRenderingExample
Command-line example showing octree generation and traversal.

```bash
swift run OctreeRenderingExample
```

### 2. StreamingExample
Demonstrates efficient streaming processing of large point cloud files.

```bash
swift run StreamingExample
```

### 3. MetalOctreeViewer
Interactive Metal-based 3D point cloud viewer with level-of-detail rendering.

```bash
swift run MetalOctreeViewer
```

The Metal viewer features:
- Real-time 3D navigation (camera controls)
- Level-of-detail rendering using octree
- Efficient GPU-based point rendering
- Interactive performance

## Building from Source

### Prerequisites

- macOS 13.0 or later
- Xcode 15.0 or later
- Swift 6.2 or later
- Homebrew

### Build the Package

```bash
swift build
```

### Run Tests

```bash
swift test
```

## Project Structure

```
SwiftPDAL/
├── Frameworks/
│   ├── gdal.xcframework          # GDAL dependency
│   └── pdalcpp.xcframework       # PDAL framework
├── Sources/
│   ├── CxxPDAL/                  # C++ wrapper layer
│   │   ├── pdal_wrapper.cpp      # C++ implementation
│   │   └── include/
│   │       ├── module.modulemap  # Module definition
│   │       ├── pdal_common.h     # Common types
│   │       ├── pdal_wrapper.h    # Internal C++ header
│   │       └── pdal_wrapper_c.h  # C bridge for Swift
│   └── SwiftPDAL/                # Swift API
│       ├── SwiftPDAL.swift       # Public Swift interface
│       └── Resources/
│           └── proj.db           # PROJ coordinate system database
├── Tests/
│   └── SwiftPDALTests/
│       ├── SwiftPDALTests.swift
│       └── Resources/
│           └── test.laz          # Test data
└── Package.swift
```

## Requirements

- The package includes embedded `pdalcpp.xcframework` and `gdal.xcframework`
- PROJ database (`proj.db`) is bundled for coordinate transformations
- Consumer apps must enable C++ interoperability in their Swift settings

## License

SwiftPDAL is licensed under the MIT License. See [LICENSE](LICENSE) for details.

### Third-Party Licenses

This package includes and depends on:
- **PDAL** - BSD 3-Clause License
- **GDAL** - MIT/X License
- **PROJ** - MIT License

See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for complete license information.

## Credits

Built with:
- [PDAL](https://pdal.io/) - Point Data Abstraction Library (BSD 3-Clause)
- [GDAL](https://gdal.org/) - Geospatial Data Abstraction Library (MIT/X)
- [PROJ](https://proj.org/) - Coordinate transformation library (MIT)
