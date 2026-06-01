import Testing
import Foundation
@testable import SwiftPDAL

@Test func convertComputingStatisticsToCOPC() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let input = Bundle.module.path(forResource: "test", ofType: "laz") else {
        Issue.record("test.laz missing from bundle"); return
    }
    let inputURL = URL(fileURLWithPath: input)
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("stats-\(UUID().uuidString).copc.laz")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let (_, stats) = try PDALConvert.convertComputingStatistics(
        from: inputURL, to: outputURL,
        options: .init(writer: PDALStage("writers.copc")))

    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    // Statistics: every dimension reports a full set, and X/Y/Z carry
    // sensible bounds + a mean inside [min, max].
    #expect(!stats.statistics.isEmpty)
    let byName = Dictionary(uniqueKeysWithValues: stats.statistics.map { ($0.name, $0) })
    for axis in ["X", "Y", "Z"] {
        let s = try #require(byName[axis], "missing \(axis) statistic")
        #expect(s.count > 0)
        #expect(s.minimum <= s.maximum)
        #expect(s.average >= s.minimum && s.average <= s.maximum)
        #expect(s.stddev >= 0)
    }

    // Schema: name/size/type populated from the C++ layout, STAC vocabulary.
    #expect(!stats.schemas.isEmpty)
    let xSchema = try #require(stats.schemas.first { $0.name == "X" })
    #expect(xSchema.size > 0)
    #expect(["signed", "unsigned", "floating"].contains(xSchema.type))

    // Header-derived fields.
    #expect(stats.count == byName["X"]?.count)
    #expect(stats.bounds != nil)
    #expect(stats.srsWKT?.isEmpty == false)
}

@Test func statisticsSidecarRoundTrips() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)
    guard let input = Bundle.module.path(forResource: "test", ofType: "laz") else {
        Issue.record("test.laz missing from bundle"); return
    }
    let inputURL = URL(fileURLWithPath: input)
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sidecar-\(UUID().uuidString).copc.laz")
    let sidecarURL = outputURL.appendingPathExtension("json")
    defer {
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    let (_, stats) = try PDALConvert.convertComputingStatistics(
        from: inputURL, to: outputURL,
        options: .init(writer: PDALStage("writers.copc")))
    try stats.writeSidecar(to: sidecarURL)

    let json = try JSONSerialization.jsonObject(
        with: Data(contentsOf: sidecarURL)) as? [String: Any]
    let props = try #require(json)

    #expect(props["pc:type"] as? String == "lidar")
    #expect(props["pc:encoding"] as? String == "copc")
    #expect(props["pc:count"] != nil)

    let pcStats = try #require(props["pc:statistics"] as? [[String: Any]])
    #expect(!pcStats.isEmpty)
    // STAC pc:statistics field names present.
    let first = try #require(pcStats.first)
    for key in ["name", "position", "count", "minimum", "maximum",
                "average", "stddev", "variance"] {
        #expect(first[key] != nil, "pc:statistics entry missing \(key)")
    }

    let pcSchemas = try #require(props["pc:schemas"] as? [[String: Any]])
    #expect(!pcSchemas.isEmpty)
    #expect(pcSchemas.first?["type"] != nil)
}

@Test func parseHandlesMissingNodesGracefully() {
    // Empty inputs must not crash and yield empty/nil fields.
    let s = PointCloudStatistics.parse(metadataJSON: "", schemaJSON: "")
    #expect(s.statistics.isEmpty)
    #expect(s.schemas.isEmpty)
    #expect(s.count == nil)
    #expect(s.bounds == nil)
    #expect(s.srsWKT == nil)
}
