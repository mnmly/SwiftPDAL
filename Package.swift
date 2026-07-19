// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

// On Windows there are no xcframeworks; CxxPDAL/CxxCOPC link against
// externally-built prefixes instead (see CLAUDE.md "Build dependencies" and
// scripts/windows/README.md):
//   - vcpkg prefix: PDAL 2.10.1, GDAL 3.12.4, libE57Format 3.3.0 (DLL + .lib)
//   - copc prefix:  copc-lib + lazperf, static (.lib), built by
//                   scripts/windows/build-copc.ps1
// Paths default to the mnml-win testbed layout and are overridable via env
// vars. Forward slashes work with clang's -I/-L on Windows and avoid escaping.
#if os(Windows)
private let vcpkgPrefix = ProcessInfo.processInfo.environment["SWIFTPDAL_VCPKG_PREFIX"]
    ?? "C:/src/vcpkg/installed/x64-windows"
private let copcPrefix = ProcessInfo.processInfo.environment["SWIFTPDAL_COPC_PREFIX"]
    ?? "C:/src/copc-install"
#endif

// Build the CxxPDAL/CxxCOPC clang modules in C++20 mode (matching the C++
// targets) when the Swift importer compiles them. The MSVC-STL coroutine_handle
// module error is avoided structurally by keeping heavy C++ headers out of the
// Windows module surface (pdal_wrapper.h is gated off; see its comment and
// scripts/windows/README.md), not by a flag. No-op on Apple.
#if os(Windows)
let windowsCxxImporterFlags: [SwiftSetting] = [
    .unsafeFlags(["-Xcc", "-std=c++20"])
]
#else
let windowsCxxImporterFlags: [SwiftSetting] = []
#endif

// SwiftPDAL sources compiled out on Windows: they use Metal (MTLBuffer) and/or
// the heavy pdal_wrapper.h read/streaming API that can't cross the Swift/MSVC-STL
// module boundary. The convert path (Convert.swift, PDALRuntime.swift,
// PointCloudStatistics.swift, DecodeGate.swift) — all PDAL2COPC needs — remains.
#if os(Windows)
let swiftPDALExclude = [
    "SwiftPDAL.swift",
    "Deinterleave/DeinterleavedGeometry.swift",
    "Streaming/ChunkPacking.swift",
    "Streaming/StreamingPointCloudSource.swift",
]
#else
let swiftPDALExclude: [String] = []
#endif

// Platform-specific C++ targets (the binary xcframeworks + their CxxPDAL/CxxCOPC
// wiring on Apple; prefix-linked equivalents on Windows). The Swift target,
// executables, and tests below are identical across platforms.
var platformTargets: [Target] = []

#if os(Windows)

platformTargets += [
    // C++ wrapper for PDAL. Same sources as the Apple build; links the vcpkg
    // import libs (pdalcpp/gdal) plus libE57Format for the E57 bridge. The
    // target's own include/ precedes the vcpkg include dir so the vendored
    // pdal/* headers win over vcpkg's copy (matching the Apple rationale).
    .target(
        name: "CxxPDAL",
        // pdal_static_plugins.cpp: iOS-only stage anchoring (Apple headers).
        // pdal_wrapper.cpp: implements the binary-read/streaming/SoA API whose
        // header (pdal_wrapper.h) is compiled out on Windows — see the guard
        // there and the excluded Swift files below.
        exclude: ["pdal_static_plugins.cpp", "pdal_wrapper.cpp"],
        cxxSettings: [
            .headerSearchPath("include"),
            .define("PDAL_DLL_EXPORT", to: "1"),
            // Stop <windows.h> pulling the legacy <winsock.h>: PDAL's
            // portable_endian.hpp includes <winsock2.h> for htonl/ntohl, which
            // collides with an earlier winsock.h. NOMINMAX keeps windows.h's
            // min/max macros from clobbering std::min/max.
            .define("WIN32_LEAN_AND_MEAN"),
            .define("NOMINMAX"),
            .unsafeFlags(["-I\(vcpkgPrefix)/include"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-L\(vcpkgPrefix)/lib",
                "-lpdalcpp", "-lgdal", "-lE57Format",
            ]),
        ]
    ),
    // C++ bridge to copc-lib. http_stream.mm (ObjC++/URLSession) is replaced by
    // http_stream_win.cpp (stub → remote COPC-over-HTTP unavailable on Windows;
    // local-file COPC works). LAZPERF_VENDORED makes lazperf's export macro
    // empty, required for the static build (dllexport-on-dllexport-member is a
    // hard error under clang-cl).
    .target(
        name: "CxxCOPC",
        path: "Sources/CxxCOPC",
        sources: ["copc_bridge.cpp", "http_stream_win.cpp"],
        publicHeadersPath: "include",
        cxxSettings: [
            .headerSearchPath("include"),
            .define("LAZPERF_VENDORED"),
            .define("WIN32_LEAN_AND_MEAN"),
            .define("NOMINMAX"),
            .unsafeFlags(["-I\(copcPrefix)/include"]),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-L\(copcPrefix)/lib",
                "-lcopc-lib", "-llazperf",
            ]),
        ]
    ),
]

#else

platformTargets += [
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
        url: "https://github.com/mnmly/gdal-xcframework-builder/releases/download/gdal-3.12.4-r2/gdal.xcframework.zip",
        checksum: "2d935c5a83f39e7cdde40116bf3fb1531b672911b3d60c785465a84723b9381c"
    ),
    // r5 rebuilds pdalcpp + pdalcpp-ios against PDAL's vendored
    // lazperf patched to match copclib's lazperf vtable layout
    // (las_decompressor::reset(InputCb) added). Without that, iOS
    // consumers crashed with __cxa_pure_virtual during COPC
    // decompression. See pdal-xcframework-builder phase 1.5.
    .binaryTarget(
        name: "pdalcpp",
        url: "https://github.com/mnmly/pdal-xcframework-builder/releases/download/pdal-2.10.1-r1/pdalcpp.xcframework.zip",
        checksum: "30fcd5e99f9ff365621763f78698878a545eafdf624629041cdf880fac950647"
    ),
    .binaryTarget(
        name: "pdalcpp-ios",
        url: "https://github.com/mnmly/pdal-xcframework-builder/releases/download/pdal-2.10.1-r1/pdalcpp-ios.xcframework.zip",
        checksum: "343028724424a9cb5818b98b8a0fbb78db950fe9658207054eecacbaa142b2e3"
    ),

    // PROJ ships as a separate xcframework (iOS-only) from
    // gdal-xcframework-builder. macOS PDAL build links Homebrew
    // proj at builder-time and bundles its dylib inside
    // gdal.framework's Libraries/, so this binaryTarget is only
    // meaningful on iOS.
    .binaryTarget(
        name: "proj",
        url: "https://github.com/mnmly/gdal-xcframework-builder/releases/download/gdal-3.12.4-r2/proj.xcframework.zip",
        checksum: "13cf2c5ecfad1aee5e7dd333752c44ba13b160ae8e29a08869c3ffbc3bbdda73"
    ),

    // libE57Format packaged as a self-contained xcframework
    // (Xerces-C 3.3 statically bundled inside). Used by the
    // libE57Format → writers.copc bridge in CxxPDAL, which works
    // around PDAL's E57 reader bug on certain multi-scan files.
    // Built by pdal-xcframework-builder/build_e57.sh.
    .binaryTarget(
        name: "E57Format",
        url: "https://github.com/mnmly/pdal-xcframework-builder/releases/download/libE57Format-3.3.0-r1/E57Format.xcframework.zip",
        checksum: "a541174b97a821308046f8515ac3f914afea683a83e48a13923b2656a0877782"
    ),
    .binaryTarget(
        name: "E57Format-ios",
        url: "https://github.com/mnmly/pdal-xcframework-builder/releases/download/libE57Format-3.3.0-r1/E57Format-ios.xcframework.zip",
        checksum: "5c466f2b1c4ac831d24f0d4ad6be28ecb6c24c19226a72f51e13c24c7a6541e1"
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
        // http_stream.mm is Objective-C++ (URLSession-backed istream for
        // the COPC-over-HTTP streaming path). It compiles in this C++ SPM
        // target and exposes only a plain C++ interface (http_stream.h).
        sources: ["copc_bridge.cpp", "http_stream.mm"],
        publicHeadersPath: "include",
        cxxSettings: [
            .headerSearchPath("include"),
        ],
        linkerSettings: [
            .linkedFramework("Foundation"), // URLSession for http_stream.mm
        ]
    ),
]

#endif

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
        // Exposes the copc-lib/lazperf-backed COPC reader (swiftpdal::copc::Reader)
        // for consumers that only need direct out-of-core node decoding without
        // the full PDAL/GDAL resident path. Used by the bl_copc_renderer dylib.
        .library(
            name: "CxxCOPC",
            targets: ["CxxCOPC"],
        ),
        // CLI that converts any PDAL-readable point cloud into COPC.
        //   swift run -c release PDAL2COPC <input> [output.copc.laz]
        .executable(
            name: "PDAL2COPC",
            targets: ["PDAL2COPC"],
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
    ],
    targets: platformTargets + [
        // Swift target that uses the C++ wrapper
        .target(
            name: "SwiftPDAL",
            dependencies: ["CxxPDAL", "CxxCOPC"],
            exclude: swiftPDALExclude,
            resources: [
                .copy("Resources/proj.db")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ] + windowsCxxImporterFlags
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

        // Dev-only one-off: write a STAC sidecar JSON for a point-cloud file.
        //   swift run -c release SidecarTool /path/to/file.copc.laz
        .executableTarget(
            name: "SidecarTool",
            dependencies: ["SwiftPDAL"],
            path: "Sources/SidecarTool",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),

        // CLI: convert any PDAL-readable point cloud to COPC. Run with:
        //   swift run -c release PDAL2COPC /path/to/input [output.copc.laz]
        .executableTarget(
            name: "PDAL2COPC",
            dependencies: ["SwiftPDAL"],
            path: "Sources/PDAL2COPC",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),

        // CLI: carve point clouds with mesh volumes from a boolean spec
        // (as exported by the bl_copc_renderer Blender addon) and write the
        // filtered full-resolution clouds. Run with:
        //   swift run -c release BooleanCloud <spec.json> [output-dir]
        .executableTarget(
            name: "BooleanCloud",
            dependencies: ["SwiftPDAL"],
            path: "Sources/BooleanCloud",
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
                .copy("Resources/wide_record.copc.laz"),
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
