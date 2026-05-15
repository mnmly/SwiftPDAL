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
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
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

        // copc-lib + laz-perf packaged as a universal static xcframework.
        // Build with: scripts/build-copc-xcframework.sh (also computes the
        // checksum below). For development against the locally-built cmake
        // prefix instead, see Frameworks/copc-build/README.md.
        //
        // Switched from URL- to path-based while iterating on the lazperf
        // pooled-decompressor patches (see Frameworks/lazperf-patches/).
        // To return to URL-based for a release, see the checksum printed
        // at the end of build-copc-xcframework.sh.
        .binaryTarget(
            name: "copclib",
            path: "Frameworks/copclib.xcframework"
        ),

        // C++ bridge to copc-lib for out-of-core streaming.
        .target(
            name: "CxxCOPC",
            dependencies: ["copclib"],
            path: "Sources/CxxCOPC",
            sources: ["copc_bridge.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
            ]
        ),

        // Swift target that uses the C++ wrapper
        .target(
            name: "SwiftPDAL",
            dependencies: ["CxxPDAL", "CxxCOPC"],
            resources: [
                .copy("Resources/proj.db")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),

        // Dev-only benchmark for the COPC streaming path. Run with:
        //   swift run -c release StreamingBench /path/to/file.copc.laz [concurrency] [seconds]
        .executableTarget(
            name: "StreamingBench",
            dependencies: ["SwiftPDAL"],
            path: "Sources/StreamingBench",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),

        .testTarget(
            name: "SwiftPDALTests",
            dependencies: ["SwiftPDAL"],
            resources: [
                .copy("Resources/test.laz"),
                .copy("Resources/test.copc.laz"),
                .copy("Resources/bunnyFloat.e57"),
                .copy("Resources/Stanford_Dragon.ply")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .define("SWIFTPDAL_TESTING")
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
