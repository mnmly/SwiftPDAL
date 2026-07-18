//
//  PDALRuntime.swift
//  SwiftPDAL
//
//  One-time, thread-safe PDAL process setup.
//

import CxxPDAL
import CxxStdlib
import Foundation

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
        let paths = PointCloud.getPaths(isTesting: isTesting)
        setenv("PROJ_DATA", paths.projDBURL, 1)
        setenv("PDAL_DRIVER_PATH", paths.driversURL, 1)
        // Seed PDAL's process-wide stage registry now, on this single
        // thread, so its plugin search path is locked from the freshly
        // written PDAL_DRIVER_PATH before any concurrent createStage().
        _ = swiftpdal.convert.driver_is_registered(std.string("readers.las"))
    }()

    /// Ensure the one-time setup has run. Cheap to call on every entry;
    /// the work happens only on the first call.
    public static func ensureBootstrapped() { _ = shared }
}
