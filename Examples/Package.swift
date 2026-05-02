// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftPDALExamples",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "StreamingExample", targets: ["StreamingExample"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "StreamingExample",
            dependencies: [
                .product(name: "SwiftPDAL", package: "SwiftPDAL"),
            ],
            path: ".",
            sources: ["StreamingExample.swift"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .define("SWIFTPDAL_TESTING")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks/gdal.xcframework/macos-arm64",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../Frameworks/gdal.xcframework/macos-arm64",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks/pdalcpp.xcframework/macos-arm64",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../Frameworks/pdalcpp.xcframework/macos-arm64",
                ])
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
