// Convert any PDAL-readable point cloud (LAS/LAZ, PLY, PCD, BPF, E57,
// XYZ/TXT, …) into a Cloud-Optimized Point Cloud (`*.copc.laz`), and
// write a STAC sidecar JSON (`<output>.json`) alongside it.
//
//   swift run -c release PDAL2COPC <input> [output.copc.laz]
//                                  [--scale <metres>] [--no-sidecar]
//
// The reader driver is inferred from the input extension; the writer is
// always `writers.copc` with `extra_dims: "all"` so custom per-point
// dimensions survive the round-trip. When the output path is omitted it
// is derived as `<input-stem>.copc.laz` next to the input.
//
// `--scale` sets the LAS coordinate quantum (default 1 mm). PDAL's own
// default is 1 cm, which is coarse enough to collapse a dense scan onto a
// visible cubic lattice — see ConvertOptions.coordinateScale.
//
// Per-dimension statistics are computed in the same streaming pass (via
// `filters.stats`, no extra read of the source) and written as a STAC
// pointcloud-extension sidecar unless `--no-sidecar` is given.
#if os(macOS) || os(Windows)

import Foundation
import SwiftPDAL

@main
struct PDAL2COPC {
    static func main() {
        var positional: [String] = []
        var writeSidecar = true
        // Coordinate quantum in source units. LAS stores X/Y/Z as Int32
        // multiples of this, so it is the file's precision floor; PDAL's
        // own default of 1 cm visibly lattices architectural scans.
        var scale = ConvertOptions.defaultCoordinateScale
        var expectingScale = false
        for arg in CommandLine.arguments.dropFirst() {
            if expectingScale {
                expectingScale = false
                guard let v = Double(arg), v > 0 else {
                    print("--scale expects a positive number in source units, got '\(arg)'")
                    exit(2)
                }
                scale = v
                continue
            }
            switch arg {
            case "--no-sidecar": writeSidecar = false
            case "--scale":      expectingScale = true
            case _ where arg.hasPrefix("--scale="):
                let raw = String(arg.dropFirst("--scale=".count))
                guard let v = Double(raw), v > 0 else {
                    print("--scale expects a positive number in source units, got '\(raw)'")
                    exit(2)
                }
                scale = v
            default:             positional.append(arg)
            }
        }
        if expectingScale {
            print("--scale expects a value")
            exit(2)
        }

        guard let first = positional.first else {
            print("usage: PDAL2COPC <input> [output.copc.laz] [--scale <metres>] [--no-sidecar]")
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
        print("scale:   \(scale) (coordinate quantum, source units)")
        if writeSidecar { print("sidecar: \(sidecar.path)") }

        let start = Date()
        var lastPct = -1
        let opts = ConvertOptions(
            // Force COPC regardless of the output filename. `extra_dims:
            // "all"` keeps non-standard dimensions; without it the
            // LAS-family writer silently drops them.
            writer: PDALStage("writers.copc", ["extra_dims": .string("all")]),
            // `scale_x/y/z` (+ `offset_*: auto`) are stamped onto the writer
            // above from `coordinateScale`; see ConvertOptions.
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
            },
            coordinateScale: scale
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
