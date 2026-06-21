// Convert any PDAL-readable point cloud (LAS/LAZ, PLY, PCD, BPF, E57,
// XYZ/TXT, …) into a Cloud-Optimized Point Cloud (`*.copc.laz`), and
// write a STAC sidecar JSON (`<output>.json`) alongside it.
//
//   swift run -c release PDAL2COPC <input> [output.copc.laz] [--no-sidecar]
//
// The reader driver is inferred from the input extension; the writer is
// always `writers.copc` with `extra_dims: "all"` so custom per-point
// dimensions survive the round-trip. When the output path is omitted it
// is derived as `<input-stem>.copc.laz` next to the input.
//
// Per-dimension statistics are computed in the same streaming pass (via
// `filters.stats`, no extra read of the source) and written as a STAC
// pointcloud-extension sidecar unless `--no-sidecar` is given.
#if os(macOS)

import Foundation
import SwiftPDAL

@main
struct PDAL2COPC {
    static func main() {
        var positional: [String] = []
        var writeSidecar = true
        for arg in CommandLine.arguments.dropFirst() {
            switch arg {
            case "--no-sidecar": writeSidecar = false
            default:             positional.append(arg)
            }
        }

        guard let first = positional.first else {
            print("usage: PDAL2COPC <input> [output.copc.laz] [--no-sidecar]")
            exit(2)
        }

        let input = URL(fileURLWithPath: first)
        let output = positional.count > 1
            ? URL(fileURLWithPath: positional[1])
            : defaultOutput(for: input)
        // Convention: sidecar is the output path with `.json` appended.
        let sidecar = URL(fileURLWithPath: output.path + ".json")

        print("input:   \(input.path)")
        print("output:  \(output.path)")
        if writeSidecar { print("sidecar: \(sidecar.path)") }

        let start = Date()
        var lastPct = -1
        let opts = ConvertOptions(
            // Force COPC regardless of the output filename. `extra_dims:
            // "all"` keeps non-standard dimensions; without it the
            // LAS-family writer silently drops them.
            writer: PDALStage("writers.copc", ["extra_dims": .string("all")]),
            onProgress: { p in
                if let f = p.fraction {
                    let pct = Int(f * 100)
                    if pct != lastPct {
                        lastPct = pct
                        FileHandle.standardError.write(
                            Data("\rconverting… \(pct)%".utf8))
                    }
                }
                return true
            }
        )

        do {
            if writeSidecar {
                // Stats fall out of the same write pass for free.
                let (result, stats) = try PDALConvert.convertComputingStatistics(
                    from: input, to: output, options: opts)
                FileHandle.standardError.write(Data("\n".utf8))
                try stats.writeSidecar(to: sidecar)
                report(result: result, stats: stats, start: start)
            } else {
                let result = try PDALConvert.convert(
                    from: input, to: output, options: opts)
                FileHandle.standardError.write(Data("\n".utf8))
                report(result: result, stats: nil, start: start)
            }
        } catch {
            FileHandle.standardError.write(Data("\n".utf8))
            print("failed: \(error)")
            exit(1)
        }
    }

    private static func report(result: ConvertResult,
                               stats: PointCloudStatistics?,
                               start: Date) {
        print(String(format: "done in %.1fs", Date().timeIntervalSince(start)))
        if let count = stats?.count {
            print("points:  \(count)")
        } else if result.pointCount > 0 {
            print("points:  \(result.pointCount)")
        }
        if let stats {
            print("dims:    \(stats.statistics.map(\.name).joined(separator: ", "))")
        }
    }

    /// Derive `<input-stem>.copc.laz`, stripping a trailing `.copc`
    /// (and any single extension) from the input's name.
    private static func defaultOutput(for input: URL) -> URL {
        var stem = input.deletingPathExtension()
        if stem.pathExtension.lowercased() == "copc" {
            stem = stem.deletingPathExtension()
        }
        return stem.appendingPathExtension("copc.laz")
    }
}

#endif
