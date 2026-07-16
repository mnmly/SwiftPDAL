import Testing
import Foundation
import simd
import CxxCOPC
import CxxStdlib
@testable import SwiftPDAL

// Env-gated per-chunk decode profiler. Splits the streaming decode pipeline
// into its two big halves — C++ `read_node` (find + fetch-compressed +
// lazperf-decode + xyz/rgb-extract) and Swift `ChunkPacker.pack` (morton sort,
// LOD, quantize) — and reports µs/chunk for each, single-threaded and
// deterministic. Also enables the C++ per-stage profiler (find/fetch/decode/
// extract) and dumps it. Skips cleanly unless SWIFTPDAL_TEST_COPC is set.
//
//   SWIFTPDAL_TEST_COPC=/path/to/file.copc.laz \
//     swift test --filter streamingDecodeStageProfile
@Test func streamingDecodeStageProfile() async throws {
    guard let path = ProcessInfo.processInfo.environment["SWIFTPDAL_TEST_COPC"] else {
        print("[SKIP] streamingDecodeStageProfile: set SWIFTPDAL_TEST_COPC to run."); return
    }
    setenv("SWIFTPDAL_DECODE_PROFILE", "1", 1)   // C++ read_node stage timers

    guard let reader = swiftpdal.copc.Reader.open(std.string(path), 1) else {
        Issue.record("failed to open \(path)"); return
    }
    let bMin = reader.bounds_min(), bMax = reader.bounds_max()
    let originShift = SIMD3<Double>(
        (bMin[0] + bMax[0]) * 0.5, (bMin[1] + bMax[1]) * 0.5, (bMin[2] + bMax[2]) * 0.5)

    // Snapshot every node's key + point count.
    struct Key { let d, x, y, z: Int32; let pts: Int }
    var keys: [Key] = []
    let nodeCount = reader.node_count()
    for i in 0..<nodeCount {
        var n = swiftpdal.copc.NodeInfo()
        if !reader.node_at(i, &n) { continue }
        keys.append(Key(d: Int32(n.depth), x: Int32(n.x), y: Int32(n.y), z: Int32(n.z),
                        pts: Int(n.point_count)))
    }

    // Cap the sample so the single-thread pass stays quick on huge files.
    let sample = keys.count > 4000 ? Array(keys.prefix(4000)) : keys

    // One reusable pack workspace across the whole loop, matching the worker
    // path (see ``ChunkPacker/Workspace``) so the reported pack µs reflect the
    // buffer-reuse cost, not fresh per-chunk allocation.
    let ws = ChunkPacker.Workspace()
    var tReadNs = 0.0, tPackNs = 0.0
    var decoded = 0, points = 0
    for k in sample {
        let r0 = DispatchTime.now().uptimeNanoseconds
        let chunk = reader.read_node(k.d, k.x, k.y, k.z, 0, nil, 0)
        let count = Int(chunk.point_count())
        let r1 = DispatchTime.now().uptimeNanoseconds
        tReadNs += Double(r1 &- r0)
        guard count > 0,
              let xyz = chunk.__xyz_dataUnsafe(),
              let rgb = chunk.__rgb_dataUnsafe() else { continue }
        let p0 = DispatchTime.now().uptimeNanoseconds
        _ = ChunkPacker.pack(
            positionsXYZ: xyz, rgb16: rgb, count: count,
            hasRgb: chunk.has_rgb(), originShift: originShift, rgbShiftBits: 8,
            workspace: ws)
        let p1 = DispatchTime.now().uptimeNanoseconds
        tPackNs += Double(p1 &- p0)
        decoded += 1; points += count
    }

    let perChunkRead = tReadNs / Double(max(decoded, 1)) / 1000.0
    let perChunkPack = tPackNs / Double(max(decoded, 1)) / 1000.0
    let avgPts = Double(points) / Double(max(decoded, 1))
    let singleThreadRate = Double(points) / ((tReadNs + tPackNs) / 1e9)

    print("""

    === SwiftPDAL single-thread decode+pack profile ===
    file: \(path)
    nodes total: \(keys.count)  sampled: \(sample.count)  decoded: \(decoded)
    avg pts/chunk: \(String(format: "%.0f", avgPts))
    read_node (C++ find+fetch+decode+extract): \(String(format: "%.2f", perChunkRead)) µs/chunk
    pack (Swift morton+LOD+quantize):          \(String(format: "%.2f", perChunkPack)) µs/chunk
    TOTAL per chunk:                           \(String(format: "%.2f", perChunkRead + perChunkPack)) µs
    single-thread throughput:                  \(String(format: "%.2f M pts/s", singleThreadRate / 1e6))
    """)

    swiftpdal.copc.dump_decode_profile()   // C++ per-stage breakdown to stderr
    reader.close()
    #expect(decoded > 0)
}
