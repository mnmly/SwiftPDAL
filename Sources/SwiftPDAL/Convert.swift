//
//  Convert.swift
//  SwiftPDAL
//
//  `pdal convert`-equivalent API for synthesising and executing a
//  Reader → [Filters] → Writer pipeline from Swift.
//

import Foundation
import CxxPDAL
import CxxStdlib

// MARK: - Pipeline option values

/// A JSON-encodable value used for PDAL stage options.
///
/// Mirrors the subset of JSON that PDAL pipeline stages accept for
/// their option values: scalars, arrays, and nested objects. Use
/// ``PDALValue/string(_:)`` for SRS strings, filenames, and enumerated
/// option values (e.g. `"laszip"`).
///
/// Declared `indirect` because the Swift 6.2 compiler crashes when
/// emitting the module under C++ interop for a recursive non-indirect
/// enum.
public indirect enum PDALValue: Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case array([PDALValue])
    case object([String: PDALValue])

    fileprivate var jsonObject: Any {
        switch self {
        case .string(let s): return s
        case .int(let i):    return NSNumber(value: i)
        case .double(let d): return NSNumber(value: d)
        case .bool(let b):   return NSNumber(value: b)
        case .array(let a):  return a.map { $0.jsonObject }
        case .object(let o): return o.mapValues { $0.jsonObject }
        }
    }

    /// Flat string form for protocols that take options as plain
    /// strings (e.g. PDAL's command-line / Options.add(name, string)
    /// path used by the E57→COPC bridge). PDAL coerces the string back
    /// to the writer's expected type when the option is consumed.
    /// Nested arrays / objects are serialised as JSON.
    fileprivate var stringRepresentation: String {
        switch self {
        case .string(let s): return s
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        case .bool(let b):   return b ? "true" : "false"
        case .array, .object:
            let data = (try? JSONSerialization.data(withJSONObject: jsonObject)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
}

extension PDALValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension PDALValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}
extension PDALValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension PDALValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

// MARK: - Stage

/// A single PDAL pipeline stage — a reader, filter, or writer.
///
/// The ``type`` is a PDAL driver name such as `"readers.ptx"`,
/// `"filters.reprojection"`, or `"writers.copc"`. ``options`` are
/// stage-specific keys documented in the PDAL stage reference.
public struct PDALStage: Sendable {
    /// PDAL driver identifier, e.g. `"writers.copc"`.
    public var type: String
    /// Stage options, keyed by PDAL option name.
    public var options: [String: PDALValue]

    public init(_ type: String, _ options: [String: PDALValue] = [:]) {
        self.type = type
        self.options = options
    }

    fileprivate func jsonDict(adding extras: [String: PDALValue] = [:]) -> [String: Any] {
        var merged = options
        for (k, v) in extras { merged[k] = v }
        var out: [String: Any] = ["type": type]
        for (k, v) in merged { out[k] = v.jsonObject }
        return out
    }
}

// MARK: - Progress

/// A single progress update reported by ``ConvertOptions/onProgress``.
public struct ConvertProgress: Sendable {
    /// Cumulative writer-side points processed so far.
    public let pointsSoFar: UInt64
    /// Reader's preview count, when available. `0` when no reader in
    /// the pipeline exposes a usable point-count preview.
    public let estimatedTotal: UInt64
    /// `pointsSoFar / estimatedTotal`, clamped to `0...1`. `nil` when
    /// the reader didn't expose a total.
    public var fraction: Double? {
        guard estimatedTotal > 0 else { return nil }
        return min(1.0, Double(pointsSoFar) / Double(estimatedTotal))
    }
}

// MARK: - Convert options

/// Configuration for a single ``PDALConvert/convert(from:to:options:)`` call.
public struct ConvertOptions: @unchecked Sendable {
    /// Reader override. When `nil`, the driver is inferred from the
    /// input URL's path extension via ``PDALConvert/inferReaderDriver(for:)``.
    /// Set this to force a specific reader or supply reader-side options.
    public var reader: PDALStage?

    /// Filters applied in order between reader and writer.
    public var filters: [PDALStage]

    /// Writer override. When `nil`, the driver is inferred from the
    /// output URL's path extension via ``PDALConvert/inferWriterDriver(for:)``.
    /// You **must** set this explicitly when targeting `.copc.laz`,
    /// since PDAL's by-extension inference picks `writers.las` for
    /// `.laz` outputs regardless of the COPC double-extension.
    public var writer: PDALStage?

    /// Execute in streaming mode when every stage supports it. Falls
    /// back to whole-file execution otherwise. Recommended for large
    /// inputs (PTX, multi-GB LAZ) where loading the full cloud into
    /// RAM is not desirable.
    public var streaming: Bool

    /// Streaming point-table capacity. Ignored when ``streaming`` is
    /// false. Defaults to 10000.
    public var streamingChunkSize: Int

    /// Optional progress hook. Called on PDAL's executing thread,
    /// once per streaming chunk (or once at the end in whole-file
    /// mode). Return `false` to cancel — the call site will throw
    /// ``ConvertError/cancelled``.
    ///
    /// Not declared `Sendable`; the closure runs synchronously inside
    /// the executing thread for the duration of the call. Capturing
    /// non-Sendable state from the caller is fine as long as the
    /// caller doesn't mutate it concurrently.
    public var onProgress: ((ConvertProgress) -> Bool)?

    /// Optional override for ``ConvertProgress/estimatedTotal``. Set this
    /// when PDAL's `preview()` can't surface a point count for the input
    /// (notably `readers.text`/`readers.pts`/`readers.ptx` ASCII formats —
    /// they don't pre-scan), and you want the progress callback to report
    /// a usable fraction.
    ///
    /// When `nil`, ``PDALConvert/convert(from:to:options:)`` calls
    /// ``PDALConvert/estimatePointTotal(for:)`` to derive a best-effort
    /// estimate from the file — exact for LAS/LAZ/COPC/Cyclone-PTS,
    /// heuristic (file-size ÷ average-line-bytes) for headerless ASCII.
    public var pointTotalHint: UInt64?

    public init(reader: PDALStage? = nil,
                filters: [PDALStage] = [],
                writer: PDALStage? = nil,
                streaming: Bool = true,
                streamingChunkSize: Int = 10_000,
                onProgress: ((ConvertProgress) -> Bool)? = nil,
                pointTotalHint: UInt64? = nil)
    {
        self.reader = reader
        self.filters = filters
        self.writer = writer
        self.streaming = streaming
        self.streamingChunkSize = streamingChunkSize
        self.onProgress = onProgress
        self.pointTotalHint = pointTotalHint
    }
}

// MARK: - Result + errors

/// Outcome of a successful conversion.
public struct ConvertResult: Sendable {
    /// Number of points written. `0` when the pipeline ran in
    /// streaming mode (PDAL doesn't surface a streamed point count).
    public let pointCount: UInt64
    /// Pipeline metadata as a JSON string, as emitted by PDAL.
    public let metadataJSON: String
}

/// Errors raised by ``PDALConvert/convert(from:to:options:)``.
public enum ConvertError: Error, CustomStringConvertible {
    /// JSON serialisation of the synthesised pipeline failed.
    case pipelineEncodingFailed(underlying: Error)
    /// PDAL rejected the pipeline or failed mid-execution. `code`
    /// mirrors ``PDALError``; `detail` is the PDAL exception text.
    case pipelineFailed(code: PDALError, detail: String)
    /// The progress callback returned `false`.
    case cancelled
    /// No reader/writer driver could be inferred from the URL's
    /// extension. Supply ``ConvertOptions/reader`` or ``ConvertOptions/writer``.
    case cannotInferDriver(String)
    /// A driver named in ``ConvertOptions`` (or inferred) is not
    /// registered in the linked pdalcpp build.
    case driverNotRegistered(String)

    public var description: String {
        switch self {
        case .pipelineEncodingFailed(let e):
            return "Failed to encode PDAL pipeline JSON: \(e)"
        case .pipelineFailed(let code, let detail):
            return "PDAL pipeline failed (\(code.message)): \(detail)"
        case .cancelled:
            return "PDAL pipeline cancelled by caller"
        case .cannotInferDriver(let s):
            return "Cannot infer PDAL driver: \(s)"
        case .driverNotRegistered(let name):
            return "PDAL driver '\(name)' is not registered in this build"
        }
    }
}

// MARK: - Convert API

/// `pdal convert`-equivalent entry point.
///
/// Synthesises a `Reader → [Filters] → Writer` pipeline from the
/// supplied URLs and options, then executes it. Reader and writer
/// drivers are inferred from the file extensions unless explicitly
/// overridden in ``ConvertOptions``.
public enum PDALConvert {

    /// Run a one-shot conversion.
    ///
    /// - Parameters:
    ///   - input: Source file URL. Must be a file URL with a recognised
    ///     extension, or you must supply ``ConvertOptions/reader``.
    ///   - output: Destination file URL. `.copc.laz` requires an
    ///     explicit ``ConvertOptions/writer`` of `writers.copc`.
    ///   - options: Optional reader/writer overrides, filters, and
    ///     streaming configuration.
    /// - Returns: Point count and pipeline metadata JSON.
    /// - Throws: ``ConvertError`` on failure.
    @discardableResult
    public static func convert(from input: URL,
                               to output: URL,
                               options: ConvertOptions = .init()) throws -> ConvertResult
    {
        // Point PDAL at the bundled plugin/PROJ data directories. The
        // `PointCloud.read` path does the same — without it, plugin-based
        // drivers (notably `readers.e57` / `writers.e57`, which live as a
        // separate dylib under the framework's PlugIns/) fail with
        // "Couldn't create reader stage of type 'readers.e57'".
        let isTesting = ProcessInfo.processInfo.environment["SWIFTPDAL_TESTING"] != nil
        let paths = PointCloud.getPaths(isTesting: isTesting)
        setenv("PROJ_DATA", paths.projDBURL, 1)
        setenv("PDAL_DRIVER_PATH", paths.driversURL, 1)

        // .e57 inputs route through the libE57Format → writers.copc
        // bridge in CxxPDAL — PDAL 2.10's `readers.e57` throws partway
        // through certain multi-scan files. The bypass uses
        // libE57Format directly (which reads those files end-to-end),
        // captures points into a long-lived PointView, then runs the
        // user's writer over the captured data via BufferReader. Same
        // API surface; same progress contract.
        if normalizedExtension(input) == "e57" {
            return try convertE57(input: input, output: output, options: options)
        }

        let reader: PDALStage
        if let r = options.reader {
            reader = r
        } else {
            reader = try inferReaderStage(for: input)
        }
        let writer: PDALStage
        if let w = options.writer {
            writer = w
        } else {
            writer = PDALStage(try inferWriterDriver(for: output),
                               writerExtras(for: output))
        }

        var stages: [[String: Any]] = []
        stages.append(reader.jsonDict(adding: ["filename": .string(input.path)]))
        for f in options.filters { stages.append(f.jsonDict()) }
        stages.append(writer.jsonDict(adding: ["filename": .string(output.path)]))

        let pipeline: [String: Any] = ["pipeline": stages]
        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: pipeline, options: [])
        } catch {
            throw ConvertError.pipelineEncodingFailed(underlying: error)
        }
        let jsonString = String(decoding: jsonData, as: UTF8.self)

        // Resolve the point-total hint once, up front. Explicit
        // `pointTotalHint` always wins; otherwise we ask the Swift-side
        // estimator (cheap file-header peek for binary formats, a
        // file-size / avg-line-bytes heuristic for ASCII formats where
        // PDAL's preview() returns 0).
        let resolvedTotalHint: UInt64 =
            options.pointTotalHint
            ?? Self.estimatePointTotal(for: input)
            ?? 0

        // C trampoline: unbox the Swift closure from the void* context
        // and forward the progress sample. PDAL invokes this
        // synchronously from inside execute_pipeline_json on the
        // calling thread, so we don't need to worry about lifetime
        // beyond the call below.
        let trampoline: swiftpdal.convert.ProgressFn? = options.onProgress == nil ? nil : {
            (pointsSoFar, estimatedTotal, ctx) -> Bool in
            guard let ctx else { return true }
            let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            // Prefer PDAL's count when it exposes one, fall back to the
            // Swift-side hint otherwise.
            let total = estimatedTotal > 0 ? estimatedTotal : box.totalHint
            return box.handler(ConvertProgress(pointsSoFar: pointsSoFar,
                                               estimatedTotal: total))
        }

        let result: swiftpdal.convert.Result
        if let handler = options.onProgress {
            let box = ProgressBox(handler: handler, totalHint: resolvedTotalHint)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<ProgressBox>.fromOpaque(ctx).release() }
            result = swiftpdal.convert.execute_pipeline_json(
                std.string(jsonString),
                options.streaming,
                Int32(options.streamingChunkSize),
                trampoline,
                ctx
            )
        } else {
            result = swiftpdal.convert.execute_pipeline_json(
                std.string(jsonString),
                options.streaming,
                Int32(options.streamingChunkSize),
                nil,
                nil
            )
        }

        let metadataString = swiftStringFromCxx(result.metadata_json)
        let errorString = swiftStringFromCxx(result.error_message)

        // kCancelled is -11; expressed as a literal because Swift's
        // cxx-interop import of `constexpr int32_t kCancelled` doesn't
        // expose it as an addressable member of the namespace.
        if result.status == -11 {
            throw ConvertError.cancelled
        }
        if result.status != 0 {
            let code = PDALError(rawValue: Int(result.status)) ?? .unknown
            throw ConvertError.pipelineFailed(code: code, detail: errorString)
        }

        return ConvertResult(pointCount: result.point_count,
                             metadataJSON: metadataString)
    }

    /// Dispatch path for `.e57` inputs — funnels through the
    /// libE57Format → writers.copc bridge in CxxPDAL instead of
    /// PDAL's `readers.e57` pipeline. Same `ConvertOptions` semantics
    /// as the main `convert(...)`; the only fields not honoured are
    /// ``ConvertOptions/reader`` (always libE57Format) and
    /// ``ConvertOptions/filters`` (no PDAL filter stages in this path,
    /// since the points never become a PDAL view until after the read).
    private static func convertE57(input: URL,
                                   output: URL,
                                   options: ConvertOptions) throws -> ConvertResult
    {
        // The C++ side builds the writer programmatically via
        // PDAL's StageFactory rather than parsing pipeline JSON
        // (PDAL doesn't ship `readers.null`, and the full nlohmann
        // header isn't on its public include path). So we hand it
        // the driver type + a flat `key=value\n`-separated bag of
        // options. PDAL's Option coerces these strings to whatever
        // each writer expects.
        let writer: PDALStage
        if let w = options.writer {
            writer = w
        } else {
            writer = PDALStage(try inferWriterDriver(for: output),
                               writerExtras(for: output))
        }
        let writerType = writer.type
        let writerOptsKV: String = writer.options
            .filter { $0.key != "filename" }
            .map { "\($0.key)=\($0.value.stringRepresentation)" }
            .joined(separator: "\n")

        let resolvedTotalHint: UInt64 =
            options.pointTotalHint
            ?? Self.estimatePointTotal(for: input)
            ?? 0

        let trampoline: swiftpdal.convert.ProgressFn? = options.onProgress == nil ? nil : {
            (pointsSoFar, estimatedTotal, ctx) -> Bool in
            guard let ctx else { return true }
            let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            // The E57 path supplies its own running total from the
            // pre-summed scan headers, so `estimatedTotal` is usually
            // populated — but fall back to the hint when not.
            let total = estimatedTotal > 0 ? estimatedTotal : box.totalHint
            return box.handler(ConvertProgress(pointsSoFar: pointsSoFar,
                                               estimatedTotal: total))
        }

        let result: swiftpdal.convert.E57Result
        if let handler = options.onProgress {
            let box = ProgressBox(handler: handler, totalHint: resolvedTotalHint)
            let ctx = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<ProgressBox>.fromOpaque(ctx).release() }
            result = swiftpdal.convert.execute_e57_to_copc(
                std.string(input.path),
                std.string(output.path),
                std.string(writerType),
                std.string(writerOptsKV),
                Int32(options.streamingChunkSize),
                trampoline,
                ctx
            )
        } else {
            result = swiftpdal.convert.execute_e57_to_copc(
                std.string(input.path),
                std.string(output.path),
                std.string(writerType),
                std.string(writerOptsKV),
                Int32(options.streamingChunkSize),
                nil,
                nil
            )
        }

        let errorString = swiftStringFromCxx(result.error_message)
        let metadataString = swiftStringFromCxx(result.metadata_json)

        if result.status == -11 {
            throw ConvertError.cancelled
        }
        if result.status != 0 {
            let code = PDALError(rawValue: Int(result.status)) ?? .unknown
            throw ConvertError.pipelineFailed(code: code, detail: errorString)
        }
        return ConvertResult(pointCount: result.point_count,
                             metadataJSON: metadataString)
    }

    /// Holds the Swift progress closure across the C boundary, plus the
    /// resolved point-total hint we want to fall back on whenever PDAL's
    /// native estimate is 0.
    private final class ProgressBox {
        let handler: (ConvertProgress) -> Bool
        let totalHint: UInt64
        init(handler: @escaping (ConvertProgress) -> Bool, totalHint: UInt64) {
            self.handler = handler
            self.totalHint = totalHint
        }
    }

    /// True if the linked pdalcpp build registers the given driver
    /// name (e.g. `"writers.copc"`).
    public static func isDriverRegistered(_ name: String) -> Bool {
        swiftpdal.convert.driver_is_registered(std.string(name))
    }

    // MARK: Extension inference

    /// Pick a fully-configured reader stage for `url`.
    ///
    /// Extension-based inference (see ``inferReaderDriver(for:)``) is the
    /// default. For ASCII formats — `.pts`, `.xyz`, `.txt` — this peeks at
    /// the file's first non-blank, non-comment line to decide whether it
    /// can route through PDAL's strict format-specific reader or whether
    /// it has to fall back to the generic `readers.text` with an inferred
    /// column map and separator.
    ///
    /// The most common case this covers is **headerless PTS**: PDAL's
    /// `readers.pts` requires a Cyclone-style first-line point count, but
    /// FARO and many other tools export raw `X Y Z [I] [R G B]` rows.
    /// Those would otherwise fail mid-pipeline with
    /// `"Unable to read expected point count at top of the file"`.
    ///
    /// Column heuristic for headerless ASCII:
    ///
    /// | columns | mapping                                        |
    /// |--------:|------------------------------------------------|
    /// | 3       | `X,Y,Z`                                        |
    /// | 4       | `X,Y,Z,Intensity`                              |
    /// | 6       | `X,Y,Z,Red,Green,Blue`                         |
    /// | 7       | `X,Y,Z,Intensity,Red,Green,Blue`               |
    /// | 9       | `X,Y,Z,Intensity,ReturnNumber,NumberOfReturns,Red,Green,Blue` |
    /// | other   | `X,Y,Z`                                        |
    ///
    /// Separator is detected from the line (tab > comma > space).
    /// Override via ``ConvertOptions/reader`` if the heuristic guesses
    /// wrong.
    public static func inferReaderStage(for url: URL) throws -> PDALStage {
        let ext = normalizedExtension(url)
        guard ext == "pts" || ext == "xyz" || ext == "txt" else {
            return PDALStage(try inferReaderDriver(for: url))
        }
        guard let line = firstNonEmptyLine(of: url) else {
            return PDALStage(try inferReaderDriver(for: url))
        }
        let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
        // Cyclone-style PTS: first line is the point count.
        if ext == "pts", cols.count == 1, Int(cols[0]) != nil {
            return PDALStage("readers.pts")
        }
        let names: [String]
        switch cols.count {
        case 3:  names = ["X", "Y", "Z"]
        case 4:  names = ["X", "Y", "Z", "Intensity"]
        case 6:  names = ["X", "Y", "Z", "Red", "Green", "Blue"]
        case 7:  names = ["X", "Y", "Z", "Intensity", "Red", "Green", "Blue"]
        case 9:  names = ["X", "Y", "Z", "Intensity", "ReturnNumber",
                          "NumberOfReturns", "Red", "Green", "Blue"]
        default: names = ["X", "Y", "Z"]
        }
        let sep: String
        if line.contains("\t") { sep = "\t" }
        else if line.contains(",") { sep = "," }
        else { sep = " " }
        // PDAL `readers.text` splits the `header` string using the
        // configured `separator`, so the two must match — joining names
        // with `,` and setting separator to ` ` (or vice versa) blows up
        // with "Invalid character ',' in dimension name."
        let header = names.joined(separator: sep)
        return PDALStage("readers.text", [
            "header": .string(header),
            "separator": .string(sep),
            "skip": .int(0),
        ])
    }

    /// Read the first non-blank, non-comment line of a text file. ~4 KiB
    /// peek; returns `nil` if the file can't be opened or contains no
    /// usable line in the prefix.
    private static func firstNonEmptyLine(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 4096)) ?? Data()
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii)
        else { return nil }
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return line
        }
        return nil
    }

    /// Best-effort point-count estimate from the file alone, used by
    /// ``convert(from:to:options:)`` to populate
    /// ``ConvertProgress/estimatedTotal`` when PDAL's `preview()` returns
    /// 0. Returns `nil` when no estimate is possible — callers that need
    /// a number should fall back to `0` and surface the progress without
    /// a fraction.
    ///
    /// Per-format strategy:
    /// - **LAS / LAZ**: reads point count from the 32-bit `PointRecords`
    ///   header field at offset 107 (LAS 1.0–1.4). Exact.
    /// - **COPC LAZ**: same as LAS — the COPC writer sets the legacy
    ///   point count field. Exact.
    /// - **Cyclone PTS**: first line is the point count. Exact.
    /// - **Headerless PTS / XYZ / TXT**: samples the first ~256 KiB,
    ///   computes average bytes/line over non-blank lines, divides total
    ///   file size by that average. Heuristic — within ~5% for
    ///   uniformly-formatted files.
    /// - Anything else: `nil` (PDAL's own `preview()` is the source of
    ///   truth for those formats).
    public static func estimatePointTotal(for url: URL) -> UInt64? {
        let ext = normalizedExtension(url)
        switch ext {
        case "las", "laz", "copc.laz":
            return estimateLASPointCount(url)
        case "pts", "xyz", "txt":
            return estimateAsciiPointCount(url, ext: ext)
        default:
            return nil
        }
    }

    /// LAS header at offset 107 carries a 32-bit little-endian point
    /// count (`Legacy Number of point records` in LAS ≥ 1.4). LAZ wraps
    /// LAS, so the same offset is valid in the uncompressed header
    /// region. COPC is LAS 1.4 underneath.
    private static func estimateLASPointCount(_ url: URL) -> UInt64? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let header = try? fh.read(upToCount: 256), header.count >= 111
        else { return nil }
        // First sanity-check the LAS magic ("LASF" at offset 0).
        guard header[0] == 0x4C, header[1] == 0x41,
              header[2] == 0x53, header[3] == 0x46
        else { return nil }
        let count: UInt32 = header.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 107, as: UInt32.self).littleEndian
        }
        // LAS ≥ 1.4 also has a 64-bit point count at offset 247. Prefer
        // it when present (file is large enough and version ≥ 1.4).
        let versionMinor = header[25]
        if versionMinor >= 4, header.count >= 255 {
            let count64: UInt64 = header.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: 247, as: UInt64.self).littleEndian
            }
            if count64 > 0 { return count64 }
        }
        return count > 0 ? UInt64(count) : nil
    }

    /// Cyclone PTS: header line is just the point count. Headerless
    /// PTS/XYZ/TXT: sample the first 256 KiB, divide file size by the
    /// average line length. Skips blanks and `#` comments.
    private static func estimateAsciiPointCount(_ url: URL, ext: String) -> UInt64? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let sample = (try? fh.read(upToCount: 256 * 1024)) ?? Data()
        guard !sample.isEmpty else { return nil }
        guard let text = String(data: sample, encoding: .utf8)
                ?? String(data: sample, encoding: .ascii)
        else { return nil }
        // Cyclone PTS: first non-blank line is the integer count.
        if ext == "pts" {
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if let n = UInt64(line) { return n }
                break
            }
        }
        // Average bytes per data line over the sample.
        var lines = 0
        var bytes = 0
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            lines += 1
            // +1 for the newline byte we split on.
            bytes += raw.utf8.count + 1
        }
        // Drop the last sampled line — likely truncated mid-row.
        if lines >= 2 {
            lines -= 1
            bytes = max(1, bytes - (text.utf8.count / max(1, lines + 1)))
        }
        guard lines >= 16 else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attrs[.size] as? NSNumber)?.int64Value
        else { return nil }
        let avg = Double(bytes) / Double(lines)
        guard avg > 0 else { return nil }
        return UInt64(Double(fileSize) / avg)
    }

    /// Pick a reader driver from a file URL's extension.
    public static func inferReaderDriver(for url: URL) throws -> String {
        switch normalizedExtension(url) {
        case "las":          return "readers.las"
        case "laz":          return "readers.las"
        case "copc.laz":     return "readers.copc"
        case "ply":          return "readers.ply"
        case "ptx":          return "readers.ptx"
        case "pts":          return "readers.pts"
        case "e57":          return "readers.e57"
        case "xyz", "txt":   return "readers.text"
        case "bpf":          return "readers.bpf"
        case "pcd":          return "readers.pcd"
        case "tif", "tiff":  return "readers.gdal"
        default:
            throw ConvertError.cannotInferDriver(
                "no reader for extension in '\(url.lastPathComponent)'")
        }
    }

    /// Pick a writer driver from a file URL's extension. Note that
    /// `.copc.laz` resolves to `"writers.copc"` here; plain `.laz`
    /// resolves to `"writers.las"` with `compression: "laszip"`.
    public static func inferWriterDriver(for url: URL) throws -> String {
        switch normalizedExtension(url) {
        case "las", "laz":   return "writers.las"
        case "copc.laz":     return "writers.copc"
        case "ply":          return "writers.ply"
        case "pcd":          return "writers.pcd"
        case "bpf":          return "writers.bpf"
        case "e57":          return "writers.e57"
        case "xyz", "txt":   return "writers.text"
        default:
            throw ConvertError.cannotInferDriver(
                "no writer for extension in '\(url.lastPathComponent)'")
        }
    }

    private static func writerExtras(for url: URL) -> [String: PDALValue] {
        switch normalizedExtension(url) {
        case "laz":
            return ["compression": .string("laszip")]
        default:
            return [:]
        }
    }

    private static func swiftStringFromCxx(_ s: std.string) -> String {
        // std::string is contiguous UTF-8 bytes. Going via the raw
        // pointer dodges the overload ambiguity between String inits
        // for std.string / std.u16string / std.u32string in CxxStdlib.
        let len = Int(s.size())
        if len == 0 { return "" }
        return s.__c_strUnsafe().withMemoryRebound(to: UInt8.self, capacity: len) { ptr in
            String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
        }
    }

    private static func normalizedExtension(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".copc.laz") { return "copc.laz" }
        return (name as NSString).pathExtension
    }
}
