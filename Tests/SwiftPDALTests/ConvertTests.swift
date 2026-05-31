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
