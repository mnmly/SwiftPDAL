// Dev-only one-off: compute per-dimension statistics for a point-cloud
// file and write its STAC sidecar JSON. The stats API requires a write
// pass, so the re-encoded output is sent to a temp file and discarded;
// only the `<input>.json` sidecar is kept.
//
//   swift run -c release SidecarTool <input.copc.laz> [sidecar.json]
#if os(macOS)

import Foundation
import SwiftPDAL

@main
struct SidecarTool {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: SidecarTool <input.(copc.)laz> [sidecar.json]")
            exit(2)
        }
        let input = URL(fileURLWithPath: args[1])
        let sidecar = args.count > 2
            ? URL(fileURLWithPath: args[2])
            : URL(fileURLWithPath: args[1] + ".json")

        // Throwaway re-encode target. We only want the stats that fall
        // out of the write pass; delete it afterwards.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(input.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        print("input:   \(input.path)")
        print("sidecar: \(sidecar.path)")

        let start = Date()
        var lastPct = -1
        let opts = ConvertOptions(
            writer: PDALStage("writers.copc"),
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
            let (_, stats) = try PDALConvert.convertComputingStatistics(
                from: input, to: tmp, options: opts)
            FileHandle.standardError.write(Data("\n".utf8))
            try stats.writeSidecar(to: sidecar)
            print(String(format: "done in %.1fs", Date().timeIntervalSince(start)))
            print("points:  \(stats.count.map(String.init) ?? "?")")
            print("dims:    \(stats.statistics.map(\.name).joined(separator: ", "))")
        } catch {
            FileHandle.standardError.write(Data("\n".utf8))
            print("failed: \(error)")
            exit(1)
        }
    }
}

#endif
