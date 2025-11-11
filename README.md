# SwiftPDAL

A Swift wrapper for PDAL (Point Data Abstraction Library) for reading and processing point cloud data (LAS/LAZ files).

## Features

- Read LAS/LAZ point cloud files
- Extract point coordinates, colors, and attributes
- Coordinate system transformations (EPSG support)
- Embedded PDAL and GDAL frameworks (no external dependencies)

## Installation

### Swift Package Manager

Add SwiftPDAL to your `Package.swift`:

```swift
dependencies: [
    .package(url: "your-repo-url", from: "1.0.0")
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

```swift
import SwiftPDAL

do {
    // Read a LAZ file
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

## Building from Source

### Prerequisites

- macOS 13.0 or later
- Xcode 15.0 or later
- Swift 6.2 or later
- Homebrew

### Install Dependencies

```bash
brew install pdal gdal
```

### Rebuild XCFrameworks

If you need to rebuild the embedded frameworks:

```bash
# Create pdalcpp XCFramework
xcodebuild -create-xcframework \
  -framework ~/Library/Frameworks/pdalcpp.framework \
  -output Frameworks/pdalcpp.xcframework

# Create GDAL XCFramework
xcodebuild -create-xcframework \
  -framework ~/Library/Frameworks/gdal.framework \
  -output Frameworks/gdal.xcframework
```

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

[Your License Here]

## Credits

Built with:
- [PDAL](https://pdal.io/) - Point Data Abstraction Library
- [GDAL](https://gdal.org/) - Geospatial Data Abstraction Library
- [PROJ](https://proj.org/) - Coordinate transformation library
