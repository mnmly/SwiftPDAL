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
        // xcodebuild rejects mixing framework + library slices in a
        // single xcframework, and static iOS libraries must ship as
        // library xcframeworks (`<slice>/lib<name>.a + Headers/`)
        // because Xcode's framework-embed pipeline corrupts MH_OBJECT
        // framework binaries on iOS apps. So the macOS dynamic
        // framework and the iOS static library ship in separate
        // xcframeworks, gated by platform conditions on dependent
        // targets below.
        .binaryTarget(name: "gdal", path: "Frameworks/gdal.xcframework"),
        .binaryTarget(name: "pdalcpp", path: "Frameworks/pdalcpp.xcframework"),
        .binaryTarget(name: "pdalcpp-ios", path: "Frameworks/pdalcpp-ios.xcframework"),

        // PROJ ships as a separate xcframework (iOS-only) from
        // gdal-xcframework-builder. macOS PDAL build links Homebrew
        // proj at builder-time and bundles its dylib inside
        // gdal.framework's Libraries/, so this binaryTarget is only
        // meaningful on iOS.
        .binaryTarget(name: "proj", path: "Frameworks/proj.xcframework"),

        // libE57Format packaged as a self-contained xcframework (Xerces-C
        // 3.3 statically bundled inside). Used by the libE57Format →
        // writers.copc bridge in CxxPDAL, which works around PDAL's
        // E57 reader bug on certain multi-scan files. Build with:
        // pdal-xcframework-builder/build_e57.sh.
        //
        // For local iteration, swap the binaryTarget below to
        // `path: "Frameworks/E57Format.xcframework"`.
        .binaryTarget(name: "E57Format", path: "Frameworks/E57Format.xcframework"),
        .binaryTarget(name: "E57Format-ios", path: "Frameworks/E57Format-ios.xcframework"),

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
                // IMPORTANT for iOS consumers: PDAL's plugin registrars
                // are file-scope statics; without `-force_load` on
                // libpdalcpp.a, ld drops them and
                // `StageFactory::createStage("readers.las")` returns
                // null at runtime. SwiftPM's .unsafeFlags rejects
                // Xcode build variables like $(BUILT_PRODUCTS_DIR),
                // so we can't express the slice-aware path here.
                // App targets must add to their OTHER_LDFLAGS build
                // setting:
                //     -Wl,-force_load,$(BUILT_PRODUCTS_DIR)/libpdalcpp.a
                // (only for iOS configurations). Examples/PDALApp's
                // project.pbxproj demonstrates this.
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
