//
//  PointCloudStatistics.swift
//  SwiftPDAL
//
//  Single-pass per-dimension statistics for a conversion, plus a
//  STAC pointcloud-extension sidecar writer.
//
//  Computing exact mean/stddev/min/max for a point cloud does not need a
//  second read: PDAL's `filters.stats` accumulates them as the points
//  flow through the pipeline. ``PDALConvert/convertComputingStatistics(from:to:options:)``
//  inserts that filter and parses the result, so the same pass that
//  writes COPC also yields stats. Pair it with ``PointCloudStatistics/writeSidecar(to:type:encoding:)``
//  to drop a `.json` next to the output that downstream STAC tooling can
//  fold straight into an Item's `properties`.
//

import Foundation

// MARK: - Value types

/// One dimension's storage layout, matching the STAC pointcloud-extension
/// `pc:schemas` object.
public struct PointCloudDimensionSchema: Codable, Sendable, Equatable {
    /// Dimension name, e.g. `"X"`, `"Intensity"`, `"semantic"`.
    public let name: String
    /// Size in bytes of one value.
    public let size: Int
    /// Base type: `"signed"`, `"unsigned"`, or `"floating"`.
    public let type: String

    public init(name: String, size: Int, type: String) {
        self.name = name
        self.size = size
        self.type = type
    }
}

/// One dimension's summary statistics, matching the STAC pointcloud-extension
/// `pc:statistics` object. Field names are passed through from PDAL's
/// `filters.stats`, which already uses the STAC vocabulary.
public struct PointCloudDimensionStatistic: Codable, Sendable, Equatable {
    /// Dimension name.
    public let name: String
    /// Index of this dimension in the schema.
    public let position: Int
    /// Number of points contributing to the statistic.
    public let count: UInt64
    /// Minimum observed value.
    public let minimum: Double
    /// Maximum observed value.
    public let maximum: Double
    /// Arithmetic mean.
    public let average: Double
    /// Standard deviation.
    public let stddev: Double
    /// Variance.
    public let variance: Double

    public init(name: String, position: Int, count: UInt64,
                minimum: Double, maximum: Double, average: Double,
                stddev: Double, variance: Double) {
        self.name = name
        self.position = position
        self.count = count
        self.minimum = minimum
        self.maximum = maximum
        self.average = average
        self.stddev = stddev
        self.variance = variance
    }
}

/// Native-CRS axis-aligned bounds, in `Double` precision (point-cloud
/// coordinates routinely exceed `Float`'s ~7 significant digits).
public struct PointCloudBounds: Codable, Sendable, Equatable {
    public let minx: Double, miny: Double, minz: Double
    public let maxx: Double, maxy: Double, maxz: Double

    public init(minx: Double, miny: Double, minz: Double,
                maxx: Double, maxy: Double, maxz: Double) {
        self.minx = minx; self.miny = miny; self.minz = minz
        self.maxx = maxx; self.maxy = maxy; self.maxz = maxz
    }
}

/// Per-dimension statistics and schema parsed from a conversion that ran
/// `filters.stats`. Build one via
/// ``PDALConvert/convertComputingStatistics(from:to:options:)``.
public struct PointCloudStatistics: Sendable {
    /// Total point count, when the reader exposed it.
    public let count: UInt64?
    /// Source CRS as WKT, when present.
    public let srsWKT: String?
    /// Native-CRS bounds, when derivable.
    public let bounds: PointCloudBounds?
    /// Dimension layout (`pc:schemas`).
    public let schemas: [PointCloudDimensionSchema]
    /// Per-dimension statistics (`pc:statistics`).
    public let statistics: [PointCloudDimensionStatistic]

    public init(count: UInt64?, srsWKT: String?, bounds: PointCloudBounds?,
                schemas: [PointCloudDimensionSchema],
                statistics: [PointCloudDimensionStatistic]) {
        self.count = count
        self.srsWKT = srsWKT
        self.bounds = bounds
        self.schemas = schemas
        self.statistics = statistics
    }
}

// MARK: - Parsing

extension PointCloudStatistics {
    /// Parse statistics from a conversion's `metadataJSON` (which carries
    /// the `filters.stats` node and reader header) and `schemaJSON` (the
    /// dimension layout). Both come from ``ConvertResult``.
    ///
    /// Returns empty/`nil` fields rather than throwing when a node is
    /// absent — the result is best-effort metadata, not a hard contract.
    public static func parse(metadataJSON: String, schemaJSON: String) -> PointCloudStatistics {
        let root = (try? JSONSerialization.jsonObject(with: Data(metadataJSON.utf8))) as? [String: Any]
        // PDAL nests stage metadata under a top-level "metadata" node.
        let meta = (root?["metadata"] as? [String: Any]) ?? root ?? [:]

        // Stage nodes are keyed by driver name, possibly suffixed when a
        // driver appears more than once (filters.stats, filters.stats1, …).
        let statsNode = firstChild(of: meta, withPrefix: "filters.stats")
        let readerNode = firstChild(of: meta, withPrefix: "readers.")

        let statistics: [PointCloudDimensionStatistic] =
            (statsNode?["statistic"] as? [[String: Any]] ?? []).compactMap(parseStatistic)

        let schemas: [PointCloudDimensionSchema] = parseSchemas(schemaJSON)

        let count = readerNode.flatMap { asUInt64($0["count"]) }
            ?? statistics.first.map(\.count)
        let srsWKT = parseSRS(readerNode)
        let bounds = parseBounds(reader: readerNode, stats: statsNode)

        return PointCloudStatistics(count: count, srsWKT: srsWKT, bounds: bounds,
                                    schemas: schemas, statistics: statistics)
    }

    private static func firstChild(of node: [String: Any], withPrefix prefix: String) -> [String: Any]? {
        // Prefer an exact match; otherwise the lexicographically-first
        // suffixed variant for determinism.
        if let exact = node[prefix] as? [String: Any] { return exact }
        let key = node.keys.filter { $0.hasPrefix(prefix) }.sorted().first
        return key.flatMap { node[$0] as? [String: Any] }
    }

    private static func parseStatistic(_ d: [String: Any]) -> PointCloudDimensionStatistic? {
        guard let name = d["name"] as? String else { return nil }
        return PointCloudDimensionStatistic(
            name: name,
            position: Int(asDouble(d["position"]) ?? 0),
            count: asUInt64(d["count"]) ?? 0,
            minimum: asDouble(d["minimum"]) ?? 0,
            maximum: asDouble(d["maximum"]) ?? 0,
            average: asDouble(d["average"]) ?? 0,
            stddev: asDouble(d["stddev"]) ?? 0,
            variance: asDouble(d["variance"]) ?? 0)
    }

    private static func parseSchemas(_ schemaJSON: String) -> [PointCloudDimensionSchema] {
        guard !schemaJSON.isEmpty,
              let arr = (try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { d in
            guard let name = d["name"] as? String else { return nil }
            return PointCloudDimensionSchema(
                name: name,
                size: Int(asDouble(d["size"]) ?? 0),
                type: (d["type"] as? String) ?? "unknown")
        }
    }

    private static func parseSRS(_ reader: [String: Any]?) -> String? {
        guard let reader else { return nil }
        if let srs = reader["srs"] as? [String: Any] {
            for key in ["compoundwkt", "wkt"] {
                if let s = srs[key] as? String, !s.isEmpty { return s }
            }
        }
        for key in ["comp_spatialreference", "spatialreference"] {
            if let s = reader[key] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    private static func parseBounds(reader: [String: Any]?, stats: [String: Any]?) -> PointCloudBounds? {
        // Reader header bounds are native-CRS and always present for
        // LAS/COPC; prefer them.
        if let r = reader,
           let minx = asDouble(r["minx"]), let miny = asDouble(r["miny"]),
           let maxx = asDouble(r["maxx"]), let maxy = asDouble(r["maxy"]) {
            return PointCloudBounds(
                minx: minx, miny: miny, minz: asDouble(r["minz"]) ?? 0,
                maxx: maxx, maxy: maxy, maxz: asDouble(r["maxz"]) ?? 0)
        }
        // Fall back to the stats filter's native bbox (e.g. non-LAS readers).
        if let bbox = (stats?["bbox"] as? [String: Any]),
           let native = (bbox["native"] as? [String: Any])?["bbox"] as? [String: Any],
           let minx = asDouble(native["minx"]), let miny = asDouble(native["miny"]),
           let maxx = asDouble(native["maxx"]), let maxy = asDouble(native["maxy"]) {
            return PointCloudBounds(
                minx: minx, miny: miny, minz: asDouble(native["minz"]) ?? 0,
                maxx: maxx, maxy: maxy, maxz: asDouble(native["maxz"]) ?? 0)
        }
        return nil
    }

    private static func asDouble(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func asUInt64(_ v: Any?) -> UInt64? {
        if let n = v as? NSNumber { return n.uint64Value }
        if let s = v as? String { return UInt64(s) }
        return nil
    }
}

// MARK: - STAC sidecar

extension PointCloudStatistics {
    /// Build the STAC pointcloud-extension property dictionary. The `pc:*`
    /// keys drop straight into a STAC Item's `properties`; `srs` and
    /// `bounds` are convenience fields for deriving geometry.
    ///
    /// - Parameters:
    ///   - type: `pc:type` value (e.g. `"lidar"`, `"radar"`, `"sonar"`).
    ///   - encoding: `pc:encoding` value (e.g. `"copc"`, `"laszip"`).
    /// - Returns: A JSON-serialisable dictionary.
    public func stacProperties(type: String = "lidar",
                               encoding: String = "copc") -> [String: Any] {
        var out: [String: Any] = [
            "pc:type": type,
            "pc:encoding": encoding,
        ]
        if let count { out["pc:count"] = count }
        if !schemas.isEmpty {
            out["pc:schemas"] = schemas.map {
                ["name": $0.name, "size": $0.size, "type": $0.type]
            }
        }
        if !statistics.isEmpty {
            out["pc:statistics"] = statistics.map {
                [
                    "name": $0.name, "position": $0.position, "count": $0.count,
                    "minimum": $0.minimum, "maximum": $0.maximum,
                    "average": $0.average, "stddev": $0.stddev,
                    "variance": $0.variance,
                ] as [String: Any]
            }
        }
        if let srsWKT { out["srs"] = ["wkt": srsWKT] }
        if let bounds {
            out["bounds"] = [
                "minx": bounds.minx, "miny": bounds.miny, "minz": bounds.minz,
                "maxx": bounds.maxx, "maxy": bounds.maxy, "maxz": bounds.maxz,
            ]
        }
        return out
    }

    /// Encode ``stacProperties(type:encoding:)`` to pretty-printed JSON.
    /// - Throws: Re-throws `JSONSerialization` errors.
    public func sidecarData(type: String = "lidar",
                            encoding: String = "copc") throws -> Data {
        try JSONSerialization.data(
            withJSONObject: stacProperties(type: type, encoding: encoding),
            options: [.prettyPrinted, .sortedKeys])
    }

    /// Write the STAC sidecar JSON to `url`.
    ///
    /// - Parameters:
    ///   - url: Destination. Convention is the output path with `.json`
    ///     appended, e.g. `cloud.copc.laz.json`.
    ///   - type: `pc:type` value.
    ///   - encoding: `pc:encoding` value.
    /// - Throws: Encoding or file-write errors.
    public func writeSidecar(to url: URL,
                             type: String = "lidar",
                             encoding: String = "copc") throws {
        try sidecarData(type: type, encoding: encoding).write(to: url, options: .atomic)
    }
}

// MARK: - Convert entry point

extension PDALConvert {
    /// Convert `input` to `output`, computing per-dimension statistics in
    /// the same pass.
    ///
    /// Inserts a `filters.stats` stage (unless the caller already supplied
    /// one) immediately before the writer, runs the conversion, and parses
    /// the resulting metadata and schema into a ``PointCloudStatistics``.
    /// Because `filters.stats` accumulates as points stream through, this
    /// adds no extra read of the source — the statistics fall out of the
    /// write pass for free.
    ///
    /// - Parameters:
    ///   - input: Source file URL.
    ///   - output: Destination file URL (e.g. `.copc.laz`).
    ///   - options: Reader/writer/filter overrides and streaming config.
    ///     `filters.stats` is appended after any filters here, so stats
    ///     reflect the post-filter (e.g. post-reprojection) values.
    /// - Returns: The ``ConvertResult`` and parsed ``PointCloudStatistics``.
    /// - Throws: ``ConvertError`` on conversion failure.
    @discardableResult
    public static func convertComputingStatistics(
        from input: URL,
        to output: URL,
        options: ConvertOptions = .init()
    ) throws -> (result: ConvertResult, statistics: PointCloudStatistics) {
        var opts = options
        if !opts.filters.contains(where: { $0.type == "filters.stats" }) {
            opts.filters.append(PDALStage("filters.stats"))
        }
        let result = try convert(from: input, to: output, options: opts)
        let statistics = PointCloudStatistics.parse(metadataJSON: result.metadataJSON,
                                                    schemaJSON: result.schemaJSON)
        return (result, statistics)
    }
}
