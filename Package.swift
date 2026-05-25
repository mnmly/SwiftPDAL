// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftPDAL",
    platforms: [
        // 13.3 is the minimum deployment for C++ reference types imported
        // via SWIFT_SHARED_REFERENCE (used by CxxCOPC's Reader).
        .macOS("13.3"),
        // iOS slices of gdal/proj/pdalcpp/E57Format are static MH_OBJECT
        // built by gdal-xcframework-builder + pdal-xcframework-builder.
        // 17.0 matches the deployment target used to build those slices.
        .iOS("17.0"),
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
        // xcodebuild rejects mixing framework + library slices in one
        // xcframework, and static iOS libraries must ship as library
        // xcframeworks (`<slice>/lib<name>.a + Headers/`) because
        // Xcode's framework-embed pipeline corrupts MH_OBJECT framework
        // binaries on iOS apps. So the macOS dynamic framework and the
        // iOS static library ship in separate xcframeworks, gated by
        // platform conditions on the dependent targets below.
        //
        // For local iteration, swap each `.binaryTarget` below to
        // `path: "Frameworks/<name>.xcframework"` and rebuild via
        // gdal-xcframework-builder / pdal-xcframework-builder.
        .binaryTarget(
            name: "gdal",
            url: "https://github.com/mnmly/SwiftPDAL/releases/download/gdal-3.12.4_pdal-2.10.1-r5/gdal.xcframework.zip",
            checksum: "1187949a2fe8bb46a0de0110efae858cf86343541a38b9d36b8c43fe2fe4778c"
        ),
        // r5 rebuilds pdalcpp + pdalcpp-ios against PDAL's vendored
        // lazperf patched to match copclib's lazperf vtable layout
        // (las_decompressor::reset(InputCb) added). Without that, iOS
        // consumers crashed with __cxa_pure_virtual during COPC
        // decompression. See pdal-xcframework-builder phase 1.5.
        .binaryTarget(
            name: "pdalcpp",
            url: "https://github.com/mnmly/SwiftPDAL/releases/download/gdal-3.12.4_pdal-2.10.1-r5/pdalcpp.xcframework.zip",
            checksum: "730291c9a93ec92df1d26e127259cf24926306edc74713be30d6d83586c5b653"
        ),
        .binaryTarget(
            name: "pdalcpp-ios",
            url: "https://github.com/mnmly/SwiftPDAL/releases/download/gdal-3.12.4_pdal-2.10.1-r5/pdalcpp-ios.xcframework.zip",
            checksum: "1fe36b4705aa299c28e20e63ee17d28746f7a6ee1510e0ebcae9014fac8ac297"
        ),

        // PROJ ships as a separate xcframework (iOS-only) from
        // gdal-xcframework-builder. macOS PDAL build links Homebrew
        // proj at builder-time and bundles its dylib inside
        // gdal.framework's Libraries/, so this binaryTarget is only
        // meaningful on iOS.
        .binaryTarget(
            name: "proj",
            url: "https://github.com/mnmly/SwiftPDAL/releases/download/gdal-3.12.4_pdal-2.10.1-r5/proj.xcframework.zip",
            checksum: "6737228edcb2bc33e1a4d36377fd523626f519878d821343a548042a3b0da6a6"
        ),

        // libE57Format packaged as a self-contained xcframework
        // (Xerces-C 3.3 statically bundled inside). Used by the
        // libE57Format → writers.copc bridge in CxxPDAL, which works
        // around PDAL's E57 reader bug on certain multi-scan files.
        // Built by pdal-xcframework-builder/build_e57.sh.
        .binaryTarget(
            name: "E57Format",
            url: "https://github.com/mnmly/SwiftPDAL/releases/download/gdal-3.12.4_pdal-2.10.1-r5/E57Format.xcframework.zip",
            checksum: "80235bbb898a462591193c8cd799cdb54ee7b5172f5bbb9bfae3f543589aec37"
        ),
        .binaryTarget(
            name: "E57Format-ios",
            url: "https://github.com/mnmly/SwiftPDAL/releases/download/gdal-3.12.4_pdal-2.10.1-r5/E57Format-ios.xcframework.zip",
            checksum: "f2b9746f7851cec2123e0cdd935b7c25d45c9515a2b1fb4639a085efb1bbcca2"
        ),

        // C++ wrapper target for PDAL. Two source files:
        //   pdal_convert.cpp      — generic pdal-convert pipeline.
        //   pdal_e57_convert.cpp  — libE57Format → writers.copc bypass.
        // Both compile into the same CxxPDAL module and share the same
        // C ABI shape (swiftpdal::convert namespace).
        .target(
            name: "CxxPDAL",
            dependencies: [
                "gdal",
                .target(name: "pdalcpp", condition: .when(platforms: [.macOS])),
                .target(name: "E57Format", condition: .when(platforms: [.macOS])),
                .target(name: "pdalcpp-ios", condition: .when(platforms: [.iOS])),
                .target(name: "E57Format-ios", condition: .when(platforms: [.iOS])),
                .target(name: "proj", condition: .when(platforms: [.iOS])),
            ],
            cxxSettings: [
                .headerSearchPath("include"),
                .define("PDAL_DLL_EXPORT", to: "1"),
                // pdalcpp.framework's headers live at Headers/pdal/*.
                // xcodebuild only exposes <pdalcpp/...>-style includes
                // via -F; <pdal/...>-style needs an explicit -I to the
                // framework's Headers/ dir. On iOS the framework is at
                // a per-slice path; we point at the device slice
                // (headers are identical across slices).
                // Note: no -I to pdalcpp-ios.xcframework's Headers on
                // iOS. CxxPDAL ships its own copy of PDAL public
                // headers under Sources/CxxPDAL/include/pdal/ (via
                // headerSearchPath("include") above) and the
                // framework-supplied copy would redefine types like
                // NullOStream and dynamicLibExtension. The local copy
                // serves both macOS and iOS compile paths uniformly;
                // the xcframework contributes only at link time.
            ],
            linkerSettings: [
                // System libs PDAL + bundled gdal/proj transitively need.
                // libcurl is cross-built and statically merged into
                // pdalcpp.framework's binary on iOS (PDAL's arbiter
                // eagerly constructs an HTTP Pool on startup — runtime
                // resolution via -undefined dynamic_lookup crashes).
                // SecureTransport.framework + CoreFoundation satisfy
                // libcurl's TLS path on iOS.
                .linkedLibrary("z", .when(platforms: [.iOS])),
                .linkedLibrary("iconv", .when(platforms: [.iOS])),
                .linkedLibrary("xml2", .when(platforms: [.iOS])),
                .linkedLibrary("sqlite3", .when(platforms: [.iOS])),
                .linkedLibrary("c++", .when(platforms: [.iOS])),
                .linkedFramework("Security", .when(platforms: [.iOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.iOS])),
                .linkedFramework("SystemConfiguration", .when(platforms: [.iOS])),
                // PDAL's plugin registrars are file-scope statics, so
                // ld would drop them from the static iOS slices of
                // libpdalcpp.a as unreferenced. CxxPDAL handles this
                // in-package via `pdal_static_plugins.cpp`, which
                // constructs one instance of each anchored stage to
                // keep its `.o` linked. No consumer-side OTHER_LDFLAGS
                // needed. See SwiftPDAL.docc/SwiftPDAL.md for the list
                // of anchored stages.
            ]
        ),

        // copc-lib + laz-perf packaged as a universal static xcframework.
        // Build with: scripts/build-copc-xcframework.sh (also computes the
        // checksum below). For development against the locally-built cmake
        // prefix instead, see Frameworks/copc-build/README.md.
        //
        // copclib-1.2.0 adds the lazperf pooled-decompressor reset() API
        // applied as Frameworks/lazperf-patches/0001-add-reset-api.patch on
        // top of upstream laz-perf master. For local iteration, switch the
        // binaryTarget below to `path: "Frameworks/copclib.xcframework"` and
        // run the build script.
        .binaryTarget(
            name: "copclib",
            url: "https://github.com/mnmly/SwiftPDAL/releases/download/copclib-1.2.0/copclib.xcframework.zip",
            checksum: "cb45a86fb22da2f7f2e97a0ac2298bb18608a5abd42a4a2b7d2b3d938621ceb7"
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
