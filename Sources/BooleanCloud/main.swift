// BooleanCloud — regenerate mesh-carved point clouds from a boolean spec.
//
//   swift run -c release BooleanCloud <spec.json> [output-dir] [--suffix NAME]
//
// The spec is exported by the bl_copc_renderer Blender addon. For each
// cloud it names the original source file, the decode origin, and the
// cutter meshes (in CRS coordinates) with per-mesh subtract/intersect ops.
// This tool reads each source at full resolution, keeps the points that
// survive the boolean rule, and writes `<source-stem>.<suffix>.copc.laz`.
// `--suffix` defaults to the spec file's own name (e.g. carve.json -> carve),
// so each spec's outputs are self-labeling.
#if os(macOS)

import Foundation
import SwiftPDAL
import CxxPDAL
import CxxStdlib

@main
struct BooleanCloud {
    static let usage =
        "usage: BooleanCloud <spec.json> [output-dir] [--suffix NAME]\n" +
        "  output name: <source-stem>.<suffix>.copc.laz\n" +
        "  --suffix     label inserted before .copc.laz (default: the spec's\n" +
        "               filename, e.g. carve.json -> carve). Empty for none.\n"

    static func main() {
        // Parse: positionals [spec, output-dir] plus an optional --suffix flag
        // (both --suffix NAME and --suffix=NAME forms).
        var positionals: [String] = []
        var suffix: String? = nil
        let args = Array(CommandLine.arguments.dropFirst())
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--suffix" {
                i += 1
                guard i < args.count else {
                    err("--suffix needs a value\n" + usage); exit(2)
                }
                suffix = args[i]
            } else if arg.hasPrefix("--suffix=") {
                suffix = String(arg.dropFirst("--suffix=".count))
            } else if arg == "-h" || arg == "--help" {
                print(usage); exit(0)
            } else {
                positionals.append(arg)
            }
            i += 1
        }
        // Unbuffered stdout so per-cloud progress streams to a parent process
        // (e.g. the Blender add-on) instead of arriving only at exit.
        setvbuf(stdout, nil, _IONBF, 0)

        guard let specPath = positionals.first else {
            err(usage); exit(2)
        }
        let outputDir: String? = positionals.count > 1 ? positionals[1] : nil
        // Default suffix = the spec file's own stem, so a run's outputs carry
        // the spec's name; an explicit --suffix (including "") overrides it.
        let suffixValue = suffix ?? URL(fileURLWithPath: specPath)
            .deletingPathExtension().lastPathComponent

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
            if !process(cloud, outputDir: outputDir, suffix: suffixValue) { failures += 1 }
        }
        if failures > 0 { exit(1) }
    }

    /// Returns true on success (including a legitimately skipped cloud).
    static func process(_ cloud: CloudSpec, outputDir: String?, suffix: String) -> Bool {
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

        let outPath = outputPath(source: cloud.source, dir: outputDir, suffix: suffix)
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

    /// `<source-stem>.<suffix>.copc.laz` (or `<source-stem>.copc.laz` when
    /// suffix is empty), in `dir` if given else beside the source.
    static func outputPath(source: String, dir: String?, suffix: String) -> String {
        let src = URL(fileURLWithPath: source)
        var stem = src.deletingPathExtension()            // strip .laz
        if stem.pathExtension.lowercased() == "copc" {
            stem = stem.deletingPathExtension()           // strip .copc
        }
        let label = suffix.isEmpty ? "" : ".\(suffix)"
        let name = stem.lastPathComponent + label + ".copc.laz"
        let folder = dir.map { URL(fileURLWithPath: $0) } ?? src.deletingLastPathComponent()
        return folder.appendingPathComponent(name).path
    }

    static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

#endif
