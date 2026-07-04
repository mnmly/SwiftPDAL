import Testing
import Foundation
import CxxCOPC
import CxxStdlib
@testable import SwiftPDAL

// MARK: - Pure clustering logic

private func cid(_ i: Int) -> ChunkID { ChunkID(depth: 3, x: i, y: 0, z: 0) }

// Three contiguous blocks (no gap) coalesce into a single cluster, preserving
// load order.
@Test func cluster_coalescesContiguousBlocks() {
    let nodes: [(id: ChunkID, offset: UInt64, size: Int)] = [
        (cid(0), 0, 100),
        (cid(1), 100, 100),
        (cid(2), 200, 100),
    ]
    let clusters = NodePrefetch.cluster(nodes, gapBytes: 256 * 1024)
    #expect(clusters.count == 1)
    #expect(clusters[0] == [cid(0), cid(1), cid(2)])
}

// Blocks separated by a gap larger than the threshold split into two clusters;
// a within-threshold gap is bridged.
@Test func cluster_splitsOnGapBeyondThreshold() {
    let nodes: [(id: ChunkID, offset: UInt64, size: Int)] = [
        (cid(0), 0, 100),          // block [0, 100)
        (cid(1), 600, 100),        // gap 500 <= 1024 → same cluster
        (cid(2), 100_000, 100),    // gap ~99KB > 1024 → new cluster
    ]
    let clusters = NodePrefetch.cluster(nodes, gapBytes: 1024)
    #expect(clusters.count == 2)
    #expect(clusters[0] == [cid(0), cid(1)])
    #expect(clusters[1] == [cid(2)])
}

// The node-count cap splits an otherwise-contiguous run.
@Test func cluster_capsNodesPerCluster() {
    let nodes = (0..<10).map { (id: cid($0), offset: UInt64($0 * 100), size: 100) }
    let clusters = NodePrefetch.cluster(nodes, gapBytes: 256 * 1024, maxNodes: 4, maxBytes: .max)
    #expect(clusters.map(\.count) == [4, 4, 2])
    #expect(clusters[0] == [cid(0), cid(1), cid(2), cid(3)])
    #expect(clusters[2] == [cid(8), cid(9)])
}

// The byte cap splits a contiguous run: three 10 MB blocks can't share a 16 MB
// cluster, so each gets its own (single oversized nodes are always allowed).
@Test func cluster_capsBytesPerCluster() {
    let tenMB = 10 * 1024 * 1024
    let nodes = (0..<3).map { (id: cid($0), offset: UInt64($0 * tenMB), size: tenMB) }
    let clusters = NodePrefetch.cluster(nodes, gapBytes: 256 * 1024, maxNodes: 8, maxBytes: 16 * 1024 * 1024)
    #expect(clusters.count == 3)
    #expect(clusters.allSatisfy { $0.count == 1 })
}

// Clusters are ordered by their best (earliest-in-input) member, so load
// priority survives the offset sort — the higher-priority node's cluster leads
// even when its file offset is larger.
@Test func cluster_ordersClustersByBestPriority() {
    let a = ChunkID(depth: 3, x: 1, y: 0, z: 0)   // priority 0, far offset
    let b = ChunkID(depth: 3, x: 2, y: 0, z: 0)   // priority 1, near offset
    let nodes: [(id: ChunkID, offset: UInt64, size: Int)] = [
        (a, 1_000_000, 100),
        (b, 0, 100),
    ]
    let clusters = NodePrefetch.cluster(nodes, gapBytes: 1024)  // huge gap → split
    #expect(clusters.count == 2)
    #expect(clusters[0] == [a])   // better priority first, despite larger offset
    #expect(clusters[1] == [b])
}

// Within a coalesced cluster, members are ordered best-priority-first (decode
// order), not by file offset.
@Test func cluster_ordersWithinClusterByPriority() {
    let hi = ChunkID(depth: 3, x: 1, y: 0, z: 0)  // priority 0, offset 100
    let lo = ChunkID(depth: 3, x: 2, y: 0, z: 0)  // priority 1, offset 0
    let nodes: [(id: ChunkID, offset: UInt64, size: Int)] = [
        (hi, 100, 100),
        (lo, 0, 100),
    ]
    let clusters = NodePrefetch.cluster(nodes, gapBytes: 256 * 1024)
    #expect(clusters.count == 1)
    #expect(clusters[0] == [hi, lo])
}

@Test func cluster_emptyInput() {
    #expect(NodePrefetch.cluster([], gapBytes: 1024).isEmpty)
}

@Test func gapThreshold_selectsHttpVsLocal() {
    #expect(NodePrefetch.gapBytes(isRemote: false) == NodePrefetch.gapLocalBytes)
    #expect(NodePrefetch.gapBytes(isRemote: true) == NodePrefetch.gapHttpBytes)
    #expect(NodePrefetch.gapHttpBytes > NodePrefetch.gapLocalBytes)
}

// MARK: - Bridge-level: prefetched reads == direct reads (byte-identical)

private func copyDoubles(_ p: UnsafePointer<Double>?, _ count: Int) -> [Double] {
    guard let p, count > 0 else { return [] }
    return Array(UnsafeBufferPointer(start: p, count: count))
}

private func copyU16(_ p: UnsafePointer<UInt16>?, _ count: Int) -> [UInt16] {
    guard let p, count > 0 else { return [] }
    return Array(UnsafeBufferPointer(start: p, count: count))
}

// Warming the per-slot cache with prefetch_nodes then reading each node must
// decode byte-for-byte the same output as reading each node without any
// prefetch — the coalesced span read + slice path feeds read_node the exact
// same compressed blocks as the direct GetPointDataCompressed path.
@Test func prefetch_thenRead_matchesDirectRead() throws {
    guard let path = Bundle.module.path(forResource: "test.copc", ofType: "laz") else {
        Issue.record("test.copc.laz fixture missing")
        return
    }

    // Collect several node keys (root + first children).
    guard let scan = swiftpdal.copc.Reader.open(std.string(path), 1) else {
        Issue.record("open failed for key scan"); return
    }
    let nodeCount = Int(scan.node_count())
    #expect(nodeCount > 1)
    var keys: [CopcNodeKey] = []
    for i in 0..<min(nodeCount, 8) {
        var n = CopcNodeInfo()
        guard scan.node_at(Int32(i), &n) else { continue }
        var k = CopcNodeKey()
        k.depth = n.depth; k.x = n.x; k.y = n.y; k.z = n.z
        keys.append(k)
    }
    scan.close()
    #expect(keys.count > 1)

    // Reference: direct reads, no prefetch.
    guard let refReader = swiftpdal.copc.Reader.open(std.string(path), 1) else {
        Issue.record("open failed for reference reader"); return
    }
    var refXYZ: [[Double]] = []
    var refRGB: [[UInt16]] = []
    for k in keys {
        let chunk = refReader.read_node(k.depth, k.x, k.y, k.z, 0, nil, 0)
        let n = Int(chunk.point_count())
        refXYZ.append(copyDoubles(chunk.__xyz_dataUnsafe(), 3 * n))
        refRGB.append(copyU16(chunk.__rgb_dataUnsafe(), 3 * n))
    }
    refReader.close()

    // Prefetched: warm the whole set in one call, then read each node.
    guard let pfReader = swiftpdal.copc.Reader.open(std.string(path), 1) else {
        Issue.record("open failed for prefetch reader"); return
    }
    keys.withUnsafeBufferPointer { buf in
        pfReader.prefetch_nodes(buf.baseAddress, Int32(buf.count), 0)
    }
    for (idx, k) in keys.enumerated() {
        let chunk = pfReader.read_node(k.depth, k.x, k.y, k.z, 0, nil, 0)
        let n = Int(chunk.point_count())
        let xyz = copyDoubles(chunk.__xyz_dataUnsafe(), 3 * n)
        let rgb = copyU16(chunk.__rgb_dataUnsafe(), 3 * n)
        #expect(xyz == refXYZ[idx], "node \(idx) xyz mismatch after prefetch")
        #expect(rgb == refRGB[idx], "node \(idx) rgb mismatch after prefetch")
        #expect(n > 0)
    }
    pfReader.close()
}

// A no-op / defensive prefetch (empty key set) leaves read_node working exactly
// as before — proving the single-node / no-prefetch path is untouched.
@Test func prefetch_emptyThenRead_stillWorks() throws {
    guard let path = Bundle.module.path(forResource: "test.copc", ofType: "laz") else {
        Issue.record("test.copc.laz fixture missing")
        return
    }
    guard let reader = swiftpdal.copc.Reader.open(std.string(path), 1) else {
        Issue.record("open failed"); return
    }
    defer { reader.close() }

    // Prefetch nothing, then read the root directly (cache miss → direct read).
    reader.prefetch_nodes(nil, 0, 0)
    let chunk = reader.read_node(0, 0, 0, 0, 0, nil, 0)
    #expect(chunk.point_count() > 0)
}
