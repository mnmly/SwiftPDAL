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
/// option values (e.g. ``"laszip"``).
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
/// The ``type`` is a PDAL driver name such as ``"readers.ptx"``,
/// ``"filters.reprojection"``, or ``"writers.copc"``. ``options`` are
/// stage-specific keys documented in the PDAL stage reference.
public struct PDALStage: Sendable {
    /// PDAL driver identifier, e.g. ``"writers.copc"``.
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
    /// Reader's preview count, when available. ``0`` when no reader in
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

    public init(reader: PDALStage? = nil,
                filters: [PDALStage] = [],
                writer: PDALStage? = nil,
                streaming: Bool = true,
                streamingChunkSize: Int = 10_000,
                onProgress: ((ConvertProgress) -> Bool)? = nil)
    {
        self.reader = reader
        self.filters = filters
        self.writer = writer
        self.streaming = streaming
        self.streamingChunkSize = streamingChunkSize
        self.onProgress = onProgress
    }
}

// MARK: - Result + errors

/// Outcome of a successful conversion.
public struct ConvertResult: Sendable {
    /// Number of points written. ``0`` when the pipeline ran in
    /// streaming mode (PDAL doesn't surface a streamed point count).
    public let pointCount: UInt64
    /// Pipeline metadata as a JSON string, as emitted by PDAL.
    public let metadataJSON: String
}

/// Errors raised by ``PDALConvert/convert(from:to:options:)``.
public enum ConvertError: Error, CustomStringConvertible {
    /// JSON serialisation of the synthesised pipeline failed.
    case pipelineEncodingFailed(underlying: Error)
    /// PDAL rejected the pipeline or failed mid-execution. ``code``
    /// mirrors ``PDALError``; ``detail`` is the PDAL exception text.
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
    ///   - output: Destination file URL. ``.copc.laz`` requires an
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
        let reader: PDALStage
        if let r = options.reader {
            reader = r
        } else {
            reader = PDALStage(try inferReaderDriver(for: input))
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

        // C trampoline: unbox the Swift closure from the void* context
        // and forward the progress sample. PDAL invokes this
        // synchronously from inside execute_pipeline_json on the
        // calling thread, so we don't need to worry about lifetime
        // beyond the call below.
        let trampoline: swiftpdal.convert.ProgressFn? = options.onProgress == nil ? nil : {
            (pointsSoFar, estimatedTotal, ctx) -> Bool in
            guard let ctx else { return true }
            let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            return box.handler(ConvertProgress(pointsSoFar: pointsSoFar,
                                               estimatedTotal: estimatedTotal))
        }

        let result: swiftpdal.convert.Result
        if let handler = options.onProgress {
            let box = ProgressBox(handler: handler)
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

    /// Holds the Swift progress closure across the C boundary.
    private final class ProgressBox {
        let handler: (ConvertProgress) -> Bool
        init(handler: @escaping (ConvertProgress) -> Bool) { self.handler = handler }
    }

    /// True if the linked pdalcpp build registers the given driver
    /// name (e.g. ``"writers.copc"``).
    public static func isDriverRegistered(_ name: String) -> Bool {
        swiftpdal.convert.driver_is_registered(std.string(name))
    }

    // MARK: Extension inference

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
    /// `.copc.laz` resolves to ``"writers.copc"`` here; plain `.laz`
    /// resolves to ``"writers.las"`` with `compression: "laszip"`.
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
