import Testing
import Foundation
import CxxCOPC
import CxxStdlib
@testable import SwiftPDAL

// Regression: COPC files whose LAS point record exceeds 256 bytes (e.g. clouds
// with many Extra Bytes dimensions) used to crash the decoder. PooledDecompressor
// decompressed each record into a fixed `char buf[256]`, so a wider record
// overflowed that stack buffer and SIGSEGV'd. It surfaced first in
// `CopcStreamingPointCloudSource.computeGlobalRgbShift` (run during `open()`),
// but every decode caller — including the streaming workers — hit the same path.
//
// `wide_record.copc.laz` is `test.laz` (capped to 20k points) with 80 ferried
// extra dimensions, giving a 676-byte record. Decoding its root node would
// crash before the fix; now it returns points.
@Test func readNode_wideRecord_doesNotOverflowStackBuffer() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let path = Bundle.module.path(forResource: "wide_record.copc", ofType: "laz") else {
        Issue.record("wide_record.copc.laz not found in bundle")
        return
    }

    guard let reader = swiftpdal.copc.Reader.open(std.string(path), 1) else {
        Issue.record("FileReader failed to open wide_record.copc.laz")
        return
    }
    defer { reader.close() }

    // Sanity: this is the wide-Extra-Bytes fixture (80 ferried dims → 676-byte
    // record, well past the old 256-byte buffer).
    #expect(reader.total_points() == 20_000)
    #expect(reader.eb_field_count() > 0)

    // Root node, fast path (no extra dims requested) — the exact call that
    // overflowed the 256-byte stack buffer during decode.
    let chunk = reader.read_node(0, 0, 0, 0, 0, nil, 0)
    #expect(chunk.point_count() > 0)
}
