//
//  PDALRuntime.swift
//  SwiftPDAL
//
//  One-time, thread-safe PDAL process setup.
//

import CxxPDAL
import CxxStdlib
import Foundation
#if os(Windows)
import ucrt  // _putenv_s
#endif

/// Process-wide PDAL runtime initialization, performed exactly once.
///
/// Every PDAL entry point needs two things set before it runs: the
/// `PROJ_DATA` / `PDAL_DRIVER_PATH` environment variables (pointing at the
/// bundled PROJ db and plugin dir), and a seeded stage registry. Doing
/// this from each entry point on every call is unsafe under concurrency:
///
/// - `setenv` is **not thread-safe** — concurrent `setenv`/`getenv` across
///   threads is undefined behaviour and can corrupt the value PDAL reads.
/// - PDAL locks its plugin **search path** on the first `StageFactory`
///   touch. If that first touch races a half-written `PDAL_DRIVER_PATH`,
///   the registry can lock to a path without the framework `PlugIns/`
///   dir, after which `createStage("readers.e57")` returns null
///   ("Failed to create stage").
///
/// ``shared`` is a `static let`, so Swift runs its initializer exactly
/// once under a thread-safe guarantee: the env vars are written a single
/// time and the registry is seeded single-threaded, before any concurrent
/// reader/writer/convert call can touch it.
public enum PDALRuntime {
    private static let shared: Void = {
        let isTesting = ProcessInfo.processInfo.environment["SWIFTPDAL_TESTING"] != nil
        let paths = resolvePaths(isTesting: isTesting)
        setEnv("PROJ_DATA", paths.projDBURL)
        setEnv("PDAL_DRIVER_PATH", paths.driversURL)
        // Seed PDAL's process-wide stage registry now, on this single
        // thread, so its plugin search path is locked from the freshly
        // written PDAL_DRIVER_PATH before any concurrent createStage().
        _ = swiftpdal.convert.driver_is_registered(std.string("readers.las"))
    }()

    /// PROJ/PDAL data paths. On Apple the resolver in ``PointCloud`` handles the
    /// framework/bundle layouts; on Windows (where that Metal-backed type is
    /// compiled out) the proj.db dir comes straight from the SPM resource bundle
    /// and the optional-plugin dir from `SWIFTPDAL_PDAL_DRIVER_PATH` (empty =
    /// core drivers only, which covers the convert path).
    private static func resolvePaths(isTesting: Bool) -> (projDBURL: String, driversURL: String) {
        #if os(Windows)
        let projDBURL: String
        if let dbURL = Bundle.module.url(forResource: "proj", withExtension: "db") {
            projDBURL = dbURL.deletingLastPathComponent().path
        } else {
            projDBURL = Bundle.module.bundlePath
        }
        let driversURL = ProcessInfo.processInfo.environment["SWIFTPDAL_PDAL_DRIVER_PATH"] ?? ""
        return (projDBURL, driversURL)
        #else
        return PointCloud.getPaths(isTesting: isTesting)
        #endif
    }

    /// setenv is POSIX-only; Windows uses the CRT's _putenv_s. Both write the
    /// process env that pdalcpp (same CRT) reads.
    private static func setEnv(_ name: String, _ value: String) {
        #if os(Windows)
        _ = name.withCString { n in value.withCString { v in _putenv_s(n, v) } }
        #else
        setenv(name, value, 1)
        #endif
    }

    /// Ensure the one-time setup has run. Cheap to call on every entry;
    /// the work happens only on the first call.
    public static func ensureBootstrapped() { _ = shared }
}
