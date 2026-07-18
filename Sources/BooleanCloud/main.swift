// BooleanCloud — regenerate mesh-carved point clouds from a boolean spec.
//
//   swift run -c release BooleanCloud <spec.json> [output-dir]
//
// The spec is exported by the bl_copc_renderer Blender addon. For each
// cloud it names the original source file, the decode origin, and the
// cutter meshes (in CRS coordinates) with per-mesh subtract/intersect ops.
// This tool reads each source at full resolution, keeps the points that
// survive the boolean rule, and writes `<source>.boolean.copc.laz`.
#if os(macOS)

import Foundation
import SwiftPDAL
import CxxPDAL
import CxxStdlib

@main
struct BooleanCloud {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let specPath = args.first else {
            FileHandle.standardError.write(Data(
                "usage: BooleanCloud <spec.json> [output-dir]\n".utf8))
            exit(2)
        }
        let outputDir: String? = args.count > 1 ? args[1] : nil

        // Our bridge calls PDAL's StageFactory directly, bypassing SwiftPDAL's
        // public entry points, so seed the runtime (PROJ_DATA / driver path)
        // ourselves before the first read.
        PDALRuntime.ensureBootstrapped()

        let spec: BooleanSpec
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: specPath))
            spec = try JSONDecoder().decode(BooleanSpec.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("failed to read spec: \(error)\n".utf8))
            exit(1)
        }

        print("spec v\(spec.version): \(spec.clouds.count) cloud(s)")
        var failures = 0
        for cloud in spec.clouds {
            if !process(cloud, outputDir: outputDir) { failures += 1 }
        }
        if failures > 0 { exit(1) }
    }

    /// Returns true on success (including a legitimately skipped cloud).
    static func process(_ cloud: CloudSpec, outputDir: String?) -> Bool {
        let cutters = cloud.meshes.compactMap { Cutter($0) }
        guard !cutters.isEmpty else {
            print("• \(cloud.name): no cutter meshes; skipping")
            return true
        }
        guard !cloud.source.isEmpty,
              FileManager.default.fileExists(atPath: cloud.source) else {
            err("• \(cloud.name): source not found: \(cloud.source)")
            return false
        }

        let outPath = outputPath(source: cloud.source, dir: outputDir)
        let subN = cutters.filter { $0.op == .subtract }.count
        let intN = cutters.filter { $0.op == .intersect }.count
        print("• \(cloud.name)  [\(subN) subtract, \(intN) intersect]")
        print("    source: \(cloud.source)")
        print("    output: \(outPath)")

        let start = Date()

        let opened = swiftpdal.boolean_filter.fw_open(std.string(cloud.source), std.string(""))
        guard opened.status == 0, let handle = opened.handle else {
            err("    open failed: \(String(opened.error_message))")
            return false
        }
        defer { swiftpdal.boolean_filter.fw_free(handle) }

        let count = Int(opened.point_count)
        guard count > 0, let xyz = swiftpdal.boolean_filter.fw_xyz(handle) else {
            err("    no points read")
            return false
        }
        print("    read \(count) points")

        let mask = keepMask(xyz: xyz, count: count, cutters: cutters)
        var kept = 0
        for m in mask where m != 0 { kept += 1 }
        let removed = count - kept

        let result = mask.withUnsafeBufferPointer { buf in
            swiftpdal.boolean_filter.fw_write_masked(
                handle, buf.baseAddress!, UInt64(count),
                std.string(outPath), std.string(""), std.string(""))
        }
        guard result.status == 0 else {
            err("    write failed: \(String(result.error_message))")
            return false
        }

        let dt = Date().timeIntervalSince(start)
        print(String(format: "    kept %d, removed %d, wrote %d  (%.1fs)",
                     kept, removed, Int(result.point_count), dt))
        return true
    }

    /// `<source-stem>.boolean.copc.laz`, in `dir` if given else beside the source.
    static func outputPath(source: String, dir: String?) -> String {
        let src = URL(fileURLWithPath: source)
        var stem = src.deletingPathExtension()            // strip .laz
        if stem.pathExtension.lowercased() == "copc" {
            stem = stem.deletingPathExtension()           // strip .copc
        }
        let name = stem.lastPathComponent + ".boolean.copc.laz"
        let folder = dir.map { URL(fileURLWithPath: $0) } ?? src.deletingLastPathComponent()
        return folder.appendingPathComponent(name).path
    }

    static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

#endif
