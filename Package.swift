// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftPDAL",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SwiftPDAL",
            targets: ["SwiftPDAL"],
        ),
        .library(
            name: "SwiftPDAL Dynamic",
            type: .dynamic,
            targets: ["SwiftPDAL"],
        ),
        .executable(
            name: "OctreeRenderingExample",
            targets: ["OctreeRenderingExample"]
        ),
        .executable(
            name: "StreamingExample",
            targets: ["StreamingExample"]
        ),
        .executable(
            name: "MetalOctreeViewer",
            targets: ["MetalOctreeViewer"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "gdal",
            url: "https://github.com/mnmly/SwiftPDAL/releases/download/gdal-3.12.4_pdal-2.10.1/gdal.xcframework.zip",
            checksum: "6beb1207e1cad7849191a5423e1f097bb9631747b30b96df3ff971de7ba2d187"
        ),
        .binaryTarget(
            name: "pdalcpp",
            url: "https://github.com/mnmly/SwiftPDAL/releases/download/gdal-3.12.4_pdal-2.10.1/pdalcpp.xcframework.zip",
            checksum: "2b495d8754c0f6009226a11b5829501414d9b9f6739ad2fb75b539af244c34d3"
        ),

        // C++ wrapper target for PDAL
        .target(
            name: "CxxPDAL",
            dependencies: ["pdalcpp", "gdal"],
            cxxSettings: [
                .headerSearchPath("include"),
                .define("PDAL_DLL_EXPORT", to: "1"),
            ]
        ),

        // Swift target that uses the C++ wrapper
        .target(
            name: "SwiftPDAL",
            dependencies: ["CxxPDAL"],
            resources: [
                .copy("Resources/proj.db")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),

        .testTarget(
            name: "SwiftPDALTests",
            dependencies: ["SwiftPDAL"],
            resources: [
                .copy("Resources/test.laz"),
                .copy("Resources/bunnyFloat.e57"),
                .copy("Resources/Stanford_Dragon.ply")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .define("SWIFTPDAL_TESTING")
            ]
        ),

        .executableTarget(
            name: "OctreeRenderingExample",
            dependencies: ["SwiftPDAL"],
            path: "Examples",
            sources: ["OctreeRenderingExample.swift"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),

        .executableTarget(
            name: "StreamingExample",
            dependencies: ["SwiftPDAL"],
            path: "Examples",
            sources: ["StreamingExample.swift"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .define("SWIFTPDAL_TESTING")
            ]
        ),

        .executableTarget(
            name: "MetalOctreeViewer",
            dependencies: ["SwiftPDAL"],
            path: "Examples/MetalOctreeViewer",
            resources: [
                .process("Shaders.metal")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
