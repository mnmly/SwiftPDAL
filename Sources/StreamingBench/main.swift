// StreamingBench is a dev-only CLI for the COPC streaming path. It's
// macOS-only by design (CommandLine-driven, runs on the host). On iOS
// the file degenerates into an empty module so the package still builds.
#if os(macOS)

import Foundation
import SwiftPDAL
import simd

@main
struct StreamingBench {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: StreamingBench <file.copc.laz | http(s)://host/file.copc.laz> [decodeConcurrency=4] [seconds=20] [maxInFlightLoadsPerTick=16] [budgetMB=8192]")
            exit(2)
        }
        // An http(s):// argument streams over range requests; anything else is
        // treated as a local file path.
        let arg = args[1]
        let isRemote = arg.hasPrefix("http://") || arg.hasPrefix("https://")
        let url: URL
        if isRemote {
            guard let u = URL(string: arg) else {
                print("invalid URL: \(arg)")
                exit(2)
            }
            url = u
        } else {
            url = URL(fileURLWithPath: arg)
        }
        let concurrency = args.count > 2 ? Int(args[2]) ?? 4 : 4
        let seconds = args.count > 3 ? Double(args[3]) ?? 20 : 20
        let perTick = args.count > 4 ? Int(args[4]) ?? 16 : 16
        let budgetMB = args.count > 5 ? Int(args[5]) ?? 8192 : 8192

        let opts = StreamingOptions(
            maxInFlightLoads: perTick,
            decodeConcurrency: concurrency,
            driverTickInterval: .milliseconds(16)
        )

        print("file:         \(isRemote ? url.absoluteString : url.path)")
        print("concurrency:  \(concurrency)")
        print("perTick cap:  \(perTick)")
        print("tick:         16 ms")
        print("duration:     \(seconds) s")

        let openStart = Date()
        let source: CopcStreamingPointCloudSource
        do {
            source = isRemote
                ? try await CopcStreamingPointCloudSource.open(remoteURL: url, options: opts)
                : try await CopcStreamingPointCloudSource.open(url, options: opts)
        } catch {
            print("open failed: \(error)")
            exit(1)
        }
        print(String(format: "opened in:    %.2f s", Date().timeIntervalSince(openStart)))
        print("total points: \(source.info.totalPoints)")
        print("max depth:    \(source.info.maxDepth)")

        // View that wants everything: large frustum centered on the data,
        // budget set high so wanted-set ≈ full hierarchy.
        let b = source.info.bounds
        let center = (b.min + b.max) * 0.5
        let radius = simd_length(b.max - b.min) * 2
        let position = center + SIMD3<Float>(0, 0, radius)

        // Zero matrix with column.3 = (0,0,0,1). All six frustum planes
        // become (0,0,0,1) — `intersects` then evaluates `0+0+0+1 ≥ 0`
        // for every AABB, admitting the whole hierarchy. Pure decode
        // throughput, no culling.
        var vp = simd_float4x4(0)
        vp.columns.3 = SIMD4<Float>(0, 0, 0, 1)

        let view = StreamingCameraView(
            position: position,
            viewProjection: vp,
            pixelScale: 1000,
            depthTolerance: 32
        )
        source.submit(view: view)
        source.setBudget(budgetMB * 1_048_576)
        print("budget:       \(budgetMB) MB")

        var totalAdded = 0
        var totalPointsLoaded: UInt64 = 0
        var bytesLoaded: UInt64 = 0
        let start = Date()
        var lastReport = start

        while Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(for: .milliseconds(50))
            if let update = source.pollLatest() {
                totalAdded += update.added.count
                for chunk in update.added {
                    totalPointsLoaded += UInt64(chunk.totalPointCount)
                    bytesLoaded += UInt64(chunk.xyzLow.count + chunk.xyzMed.count
                                          + chunk.xyzHigh.count + chunk.colors.count
                                          + chunk.levels.count)
                }
            }
            if Date().timeIntervalSince(lastReport) >= 1 {
                let elapsed = Date().timeIntervalSince(start)
                let snap = await source._debugSnapshot()
                let totalTicks = snap.cacheHits + snap.cacheMisses
                let hitRate = totalTicks > 0 ? Double(snap.cacheHits) / Double(totalTicks) * 100 : 0
                print(String(
                    format: "  t=%5.1fs  chunks=%5d  pts=%10llu  MB=%7.1f  rate=%6.0f chunks/s  %7.1f Mpts/s   resident=%d inFlight=%d wanted=%d/%d  cacheHits=%d (%.0f%%)",
                    elapsed, totalAdded, totalPointsLoaded, Double(bytesLoaded) / 1_048_576,
                    Double(totalAdded) / elapsed, Double(totalPointsLoaded) / elapsed / 1_000_000,
                    snap.resident, snap.inFlight, snap.wanted, snap.totalNodes,
                    snap.cacheHits, hitRate
                ))
                lastReport = Date()
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        print("------")
        print(String(format: "TOTAL  chunks=%d  pts=%llu  MB=%.1f  in %.2fs",
                     totalAdded, totalPointsLoaded, Double(bytesLoaded) / 1_048_576, elapsed))
        print(String(format: "       %.0f chunks/s   %.2f Mpts/s",
                     Double(totalAdded) / elapsed, Double(totalPointsLoaded) / elapsed / 1_000_000))

        let finalSnap = await source._debugSnapshot()
        print("--- depth distribution (final tick) ---")
        print(String(format: "totalNodes=%d  frustumVisible=%d  wanted=%d  resident=%d  inFlight=%d",
                     finalSnap.totalNodes, finalSnap.frustumVisible,
                     finalSnap.wanted, finalSnap.resident, finalSnap.inFlight))
        for d in 0..<finalSnap.residentByDepth.count {
            print(String(format: "  depth %d:  resident=%-6d  wanted=%-6d",
                         d, finalSnap.residentByDepth[d], finalSnap.wantedByDepth[d]))
        }

        source.close()
    }
}

#endif
