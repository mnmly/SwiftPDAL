import Testing
import Foundation
@testable import SwiftPDAL

@Test func convertLazRoundTrip() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let input = Bundle.module.path(forResource: "test", ofType: "laz") else {
        Issue.record("test.laz missing from bundle"); return
    }

    let inputURL = URL(fileURLWithPath: input)
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("convert-\(UUID().uuidString).laz")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let result = try PDALConvert.convert(from: inputURL, to: outputURL)

    #expect(FileManager.default.fileExists(atPath: outputURL.path))
    let size = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0
    #expect(size > 0)
    print("Converted laz→laz, wrote \(size) bytes, point_count=\(result.pointCount) (0 expected for streaming)")
}

@Test func convertPlyToLaz() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let input = Bundle.module.path(forResource: "Stanford_Dragon", ofType: "ply") else {
        Issue.record("Stanford_Dragon.ply missing from bundle"); return
    }

    let inputURL = URL(fileURLWithPath: input)
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dragon-\(UUID().uuidString).laz")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    // PLY -> LAZ typically isn't streamable end-to-end; let it fall back.
    let result = try PDALConvert.convert(from: inputURL, to: outputURL,
                                         options: .init(streaming: false))

    #expect(FileManager.default.fileExists(atPath: outputURL.path))
    #expect(result.pointCount > 0)
    print("Converted ply→laz, points=\(result.pointCount)")
}

@Test func convertPreservesExtraDimensionsAsExtraBytes() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let input = Bundle.module.path(forResource: "test", ofType: "laz") else {
        Issue.record("test.laz missing from bundle"); return
    }
    let inputURL = URL(fileURLWithPath: input)
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("extradims-\(UUID().uuidString).copc.laz")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    // Ferry X into a non-standard dimension. The inferred COPC writer must
    // carry it through as Extra Bytes — regression for `writerExtras` setting
    // `extra_dims: "all"`. Without that flag the LAS-family writer silently
    // drops `my_score`, so a graph that filters on it would see nothing.
    let options = ConvertOptions(
        filters: [PDALStage("filters.ferry", ["dimensions": .string("X=>my_score")])],
        streaming: false
    )
    _ = try PDALConvert.convert(from: inputURL, to: outputURL, options: options)

    let pc = try PointCloud.read(from: outputURL.path, readerName: "readers.copc")
    #expect(pc.dimensions.contains { $0.name == "my_score" },
            "ferried custom dim should survive conversion as Extra Bytes (got \(pc.dimensions.map(\.name)))")
}

@Test func convertStreamingPreservesExtraDimensions() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let input = Bundle.module.path(forResource: "test", ofType: "laz") else {
        Issue.record("test.laz missing from bundle"); return
    }
    let inputURL = URL(fileURLWithPath: input)
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("extradims-stream-\(UUID().uuidString).copc.laz")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    // Like `convertPreservesExtraDimensionsAsExtraBytes`, but exercises the
    // STREAMING two-pass capture path (CapturingStreamTable) used for the
    // non-streamable COPC writer — the case that bites real files. Regression
    // for the capture mirroring custom dims into the sink layout by raw Id,
    // which dropped their names and made writers.copc `extra_dims: "all"` fail
    // with "Dimension '' ... not found" on any file carrying custom dims.
    //
    // The two-pass path is only taken when an `onProgress` handler is set
    // (otherwise the wrapper falls back to a plain non-streaming execute), so
    // the no-op handler below is load-bearing. Two ferried dims also exercise
    // the source→sink dim-Id remap in the value copy.
    let options = ConvertOptions(
        filters: [PDALStage("filters.ferry",
                            ["dimensions": .string("X=>my_score, Y=>my_tag")])],
        streaming: true,
        onProgress: { _ in true }
    )
    _ = try PDALConvert.convert(from: inputURL, to: outputURL, options: options)

    let pc = try PointCloud.read(from: outputURL.path, readerName: "readers.copc")
    #expect(pc.dimensions.contains { $0.name == "my_score" },
            "ferried custom dim should survive the streaming path (got \(pc.dimensions.map(\.name)))")
    #expect(pc.dimensions.contains { $0.name == "my_tag" })

    // Values must round-trip, not just the names: the capture remaps dim Ids
    // between the source and sink layouts, so a wrong mapping would silently
    // corrupt point data. Ferry copies X verbatim, so my_score == X per point.
    guard let xDim = pc.dimensions.first(where: { $0.name == "X" }),
          let scoreDim = pc.dimensions.first(where: { $0.name == "my_score" }) else {
        Issue.record("X / my_score missing from output"); return
    }
    var mismatches = 0
    let sampleCount = min(pc.pointCount, 1000)
    for i in 0..<sampleCount {
        let p = pc.data + i * pc.stride
        let x = p.loadUnaligned(fromByteOffset: xDim.offset, as: Float.self)
        let s = p.loadUnaligned(fromByteOffset: scoreDim.offset, as: Float.self)
        if x != s { mismatches += 1 }
    }
    #expect(mismatches == 0, "ferried my_score should equal X (\(mismatches)/\(sampleCount) mismatched)")
}

@Test func convertReportsProgress() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let input = Bundle.module.path(forResource: "test", ofType: "laz") else {
        Issue.record("test.laz missing from bundle"); return
    }
    let inputURL = URL(fileURLWithPath: input)
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("progress-\(UUID().uuidString).laz")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    final class Recorder: @unchecked Sendable {
        var calls = 0
        var lastPoints: UInt64 = 0
        var sawTotal: UInt64 = 0
    }
    let rec = Recorder()

    let result = try PDALConvert.convert(
        from: inputURL, to: outputURL,
        options: .init(streamingChunkSize: 50_000, onProgress: { p in
            rec.calls += 1
            rec.lastPoints = p.pointsSoFar
            rec.sawTotal = p.estimatedTotal
            return true
        })
    )

    #expect(rec.calls > 1, "should fire multiple times for a streamed file")
    #expect(rec.lastPoints == result.pointCount)
    print("progress calls=\(rec.calls), final=\(rec.lastPoints), estTotal=\(rec.sawTotal)")
}

@Test func convertCancellation() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let input = Bundle.module.path(forResource: "test", ofType: "laz") else {
        Issue.record("test.laz missing from bundle"); return
    }
    let inputURL = URL(fileURLWithPath: input)
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cancel-\(UUID().uuidString).laz")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    do {
        _ = try PDALConvert.convert(
            from: inputURL, to: outputURL,
            options: .init(streamingChunkSize: 10_000, onProgress: { _ in false })
        )
        Issue.record("expected cancellation to throw")
    } catch ConvertError.cancelled {
        // expected
    }
}

@Test func driverProbe() async throws {
    // Sanity: readers.las and writers.las must be present.
    #expect(PDALConvert.isDriverRegistered("readers.las"))
    #expect(PDALConvert.isDriverRegistered("writers.las"))
    #expect(!PDALConvert.isDriverRegistered("writers.does_not_exist"))

    // Surface whether writers.copc is in this build (used for .copc.laz).
    print("writers.copc available: \(PDALConvert.isDriverRegistered("writers.copc"))")
}

/// `inferReaderStage` must count columns correctly regardless of line
/// ending. Swift stores `\r\n` as a single grapheme cluster equal to
/// neither `"\n"` nor `"\r"`, so a naive newline split collapses a CRLF
/// file into one giant line and the column heuristic falls through to the
/// 3-column default — which then rejects every real 6-field row. Regression
/// for headerless RGB `.xyz` exports (FARO/Cyclone) that use CRLF.
@Test func inferReaderStageHandlesCRLF() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("crlf-infer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func header(_ contents: String, _ name: String) throws -> String? {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        let stage = try PDALConvert.inferReaderStage(for: url)
        if case .string(let h)? = stage.options["header"] { return h }
        return nil
    }

    let rows6crlf = (0..<4).map { "0.1\($0) 0.2\($0) 0.3\($0) 10 20 30" }.joined(separator: "\r\n") + "\r\n"
    let rows6lf   = rows6crlf.replacingOccurrences(of: "\r\n", with: "\n")
    let rows3crlf = (0..<4).map { "0.1\($0) 0.2\($0) 0.3\($0)" }.joined(separator: "\r\n") + "\r\n"

    #expect(try header(rows6crlf, "rgb_crlf.xyz") == "X Y Z Red Green Blue")
    #expect(try header(rows6lf,   "rgb_lf.xyz")   == "X Y Z Red Green Blue")
    #expect(try header(rows3crlf, "plain_crlf.xyz") == "X Y Z")
}

// MARK: - Coordinate scale

/// LAS public-header block: `scale_x/y/z` at byte 131, `offset_x/y/z` at
/// byte 155, both as three little-endian doubles. Reading them directly
/// keeps the assertion independent of whatever reader we'd otherwise use
/// to inspect the file.
private func lasScaleAndOffset(_ url: URL) throws -> (scale: (Double, Double, Double),
                                                      offset: (Double, Double, Double)) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard let head = try handle.read(upToCount: 400), head.count >= 179 else {
        throw ConvertError.cannotInferDriver("short LAS header in \(url.lastPathComponent)")
    }
    #expect(head.prefix(4) == Data("LASF".utf8))
    func double(at byte: Int) -> Double {
        head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: byte, as: Double.self) }
    }
    return ((double(at: 131), double(at: 139), double(at: 147)),
            (double(at: 155), double(at: 163), double(at: 171)))
}

/// LAS quantizes X/Y/Z onto an `Int32` lattice of `scale_*` units, and
/// PDAL's default of 1 cm is coarse enough to collapse a dense scan onto a
/// visible cubic grid (which then moirés against the pixel grid under camera
/// motion). SwiftPDAL defaults to 1 mm instead. Regression for
/// ``ConvertOptions/coordinateScale`` reaching both writer families.
@Test func convertDefaultsToMillimetreCoordinateScale() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let input = Bundle.module.path(forResource: "test", ofType: "laz") else {
        Issue.record("test.laz missing from bundle"); return
    }
    let inputURL = URL(fileURLWithPath: input)

    // `.copc.laz` (writers.copc, non-streamable — buffers and computes true
    // bounds) and plain `.laz` (writers.las, streams).
    for (suffix, streaming) in [("copc.laz", false), ("laz", true)] {
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scale-\(UUID().uuidString).\(suffix)")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let writer: PDALStage? = suffix == "copc.laz"
            ? PDALStage("writers.copc", ["extra_dims": .string("all")])
            : nil
        _ = try PDALConvert.convert(from: inputURL, to: outputURL,
                                    options: .init(writer: writer, streaming: streaming))

        let (scale, offset) = try lasScaleAndOffset(outputURL)
        #expect(scale == (0.001, 0.001, 0.001), "\(suffix): got scale \(scale)")
        // `offset_*: auto` re-bases onto the data, so the Int32 range covers
        // the extent rather than the distance from the origin. test.laz sits
        // at ~114 km easting; a 1 mm scale with offset 0 would still fit, but
        // a UTM northing would not.
        #expect(offset.0 != 0 && offset.1 != 0, "\(suffix): expected auto offset, got \(offset)")
    }
}

/// The scale is a knob, not a constant: an explicit value wins, `nil`
/// restores PDAL's own default, and a `scale_x` already set on a
/// caller-supplied writer stage is never overwritten.
@Test func convertCoordinateScaleIsOverridable() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let input = Bundle.module.path(forResource: "test", ofType: "laz") else {
        Issue.record("test.laz missing from bundle"); return
    }
    let inputURL = URL(fileURLWithPath: input)

    func scaleOfConversion(_ options: ConvertOptions) throws -> (Double, Double, Double) {
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scaleopt-\(UUID().uuidString).laz")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = try PDALConvert.convert(from: inputURL, to: outputURL, options: options)
        return try lasScaleAndOffset(outputURL).scale
    }

    #expect(try scaleOfConversion(.init(coordinateScale: 0.005)) == (0.005, 0.005, 0.005))
    // nil = inherit PDAL, which is 1 cm.
    #expect(try scaleOfConversion(.init(coordinateScale: nil)) == (0.01, 0.01, 0.01))
    // Explicit stage options win over `coordinateScale`.
    let explicit = ConvertOptions(
        writer: PDALStage("writers.las", ["compression": .string("laszip"),
                                          "scale_x": .string("0.02"),
                                          "scale_y": .string("0.02"),
                                          "scale_z": .string("0.02")]),
        coordinateScale: 0.001)
    #expect(try scaleOfConversion(explicit) == (0.02, 0.02, 0.02))
}

/// `coordinateScale` must not leak onto writers that have no LAS header.
@Test func coordinateScaleOnlyTouchesLASFamilyWriters() throws {
    let ply = PDALConvert.applyingCoordinateScale(0.001, to: PDALStage("writers.ply"))
    #expect(ply.options.isEmpty)

    let copc = PDALConvert.applyingCoordinateScale(0.001, to: PDALStage("writers.copc"))
    #expect(copc.options.count == 6)
    if case .string(let s)? = copc.options["scale_z"] { #expect(s == "0.001") }
    else { Issue.record("scale_z missing or not a string: \(copc.options)") }
    if case .string(let o)? = copc.options["offset_y"] { #expect(o == "auto") }
    else { Issue.record("offset_y missing or not a string: \(copc.options)") }

    // Disabled: nothing stamped at all.
    #expect(PDALConvert.applyingCoordinateScale(nil, to: PDALStage("writers.las")).options.isEmpty)
}
