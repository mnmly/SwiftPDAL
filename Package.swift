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
        // Binary targets for frameworks
        // TODO: Replace URL with actual GitHub Release URL after uploading
        // Example: https://github.com/mnmly/SwiftPDAL/releases/download/v1.0.0/gdal.xcframework.zip
        .binaryTarget(
            name: "gdal",
            url: "https://github.com/mnmly/SwiftPDAL/releases/download/gdal-v3.12/gdal.xcframework.zip",
            checksum: "e374d54681f1aad30084eb870070c466ce3c08f1c01f0a72ac71842a712260b7"
        ),
        .binaryTarget(
            name: "pdalcpp",
            url: "https://github.com/mnmly/SwiftPDAL/releases/download/pdalcpp-v2.9/pdalcpp.xcframework.zip",
            checksum: "58921a58da064cfdcb3857559a75a0cc9218c1c9816491e863724158788a22a8"
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
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../Frameworks/gdal.xcframework/macos-arm64/gdal.framework",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../Frameworks/gdal.xcframework/macos-arm64/gdal.framework"
                ])
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
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../Frameworks/gdal.xcframework/macos-arm64/gdal.framework",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../Frameworks/gdal.xcframework/macos-arm64/gdal.framework"
                ])
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
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../Frameworks/gdal.xcframework/macos-arm64/gdal.framework",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../Frameworks/gdal.xcframework/macos-arm64/gdal.framework"
                ])
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
