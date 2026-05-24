import CxxPDAL
import Foundation
import Metal
import simd

public protocol PointCloudData {
    var filePath: String { get }
    var pointCount: Int { get }
    var bounds: Bounds { get }
    var stride: Int { get }
    var dimensions: [DimensionInfo] { get }
    var data: UnsafeRawPointer { get }
    var mtlBuffer: MTLBuffer? { get }
    mutating func makeBuffer(device: MTLDevice, options: MTLResourceOptions) -> MTLBuffer?
}
    
public struct Bounds: Sendable {
    public let min: simd_float3
    public let max: simd_float3

    /// Transform the bounds by a 4x4 transformation matrix
    /// - Parameter transform: The transformation matrix to apply
    /// - Returns: A new Bounds with transformed min and max corners
    public func transformed(by transform: simd_float4x4) -> Bounds {
        // Transform all 8 corners of the AABB
        let c0 = simd_float4(min.x, min.y, min.z, 1.0)
        let c1 = simd_float4(max.x, min.y, min.z, 1.0)
        let c2 = simd_float4(min.x, max.y, min.z, 1.0)
        let c3 = simd_float4(max.x, max.y, min.z, 1.0)
        let c4 = simd_float4(min.x, min.y, max.z, 1.0)
        let c5 = simd_float4(max.x, min.y, max.z, 1.0)
        let c6 = simd_float4(min.x, max.y, max.z, 1.0)
        let c7 = simd_float4(max.x, max.y, max.z, 1.0)

        let t0 = transform * c0; let t1 = transform * c1
        let t2 = transform * c2; let t3 = transform * c3
        let t4 = transform * c4; let t5 = transform * c5
        let t6 = transform * c6; let t7 = transform * c7

        func unproject(_ p: simd_float4) -> simd_float3 {
            simd_float3(p.x/p.w, p.y/p.w, p.z/p.w)
        }

        let tc0 = unproject(t0); let tc1 = unproject(t1)
        let tc2 = unproject(t2); let tc3 = unproject(t3)
        let tc4 = unproject(t4); let tc5 = unproject(t5)
        let tc6 = unproject(t6); let tc7 = unproject(t7)

        return Bounds(
            min: simd_min(simd_min(tc0, tc1), simd_min(tc2, simd_min(tc3, simd_min(tc4, simd_min(tc5, simd_min(tc6, tc7)))))),
            max: simd_max(simd_max(tc0, tc1), simd_max(tc2, simd_max(tc3, simd_max(tc4, simd_max(tc5, simd_max(tc6, tc7))))))
        )
    }
    
    public init(min: simd_float3, max: simd_float3) {
        self.min = min
        self.max = max
    }
}

public struct DimensionInfo: Sendable {
    public let name: String
    public let sourceType: pdal.Dimension.`Type`
    public let outputType: pdal.Dimension.`Type`
    public let outputSize: Int
    public let offset: Int
    
    public init(from cInfo: PDALDimensionInfo) {
        self.name = cInfo.name != nil ? String(cString: cInfo.name) : ""
        self.sourceType = cInfo.sourceType
        self.outputType = cInfo.outputType
        self.outputSize = cInfo.outputSize
        self.offset = cInfo.offset
    }
}

public final class PointCloud: PointCloudData {

    public let filePath: String
    public let pointCount: Int
    public let bounds: Bounds
    public let data: UnsafeRawPointer
    public let size: Int
    public let stride: Int
    public let dimensions: [DimensionInfo]
    
    public var mtlBuffer: MTLBuffer?

    private let dataFreedLock = NSLock()
    private var _dataFreed: Bool = false
    private var dataFreed: Bool {
        get { dataFreedLock.withLock { _dataFreed } }
        set { dataFreedLock.withLock { _dataFreed = newValue } }
    }

    public init(filePath: String, pointCount: Int, bounds: Bounds, data: UnsafeRawPointer, size: Int, stride: Int, dimensions: [DimensionInfo]) {
        self.filePath = filePath
        self.pointCount = pointCount
        self.bounds = bounds
        self.data = data
        self.size = size
        self.stride = stride
        self.dimensions = dimensions
    }

    public static func getPaths(isTesting: Bool) -> (projDBURL: String, driversURL: String) {
        if isTesting {
            let bundlePath = Bundle.module.bundlePath as NSString
            let projDBURL = bundlePath.deletingLastPathComponent
                .appending("/SwiftPDAL_SwiftPDAL.bundle")
            let driversURL = Bundle.module.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("pdalcpp.framework/Versions/A/PlugIns").path()
            return (projDBURL, driversURL)
        } else {
            #if os(iOS)
            // iOS bundles are flat — resources sit directly under the
            // .bundle root, not under Contents/Resources/. And there's
            // no PlugIns dir because pdalcpp is statically linked on
            // iOS (no loadable dylib plugins to discover); pass empty
            // driversURL to disable PDAL's plugin search.
            let projDBURL = Bundle.module.bundleURL.path()
            let driversURL = ""
            #else
            // macOS dynamic-framework layout (Versions/A/Resources/ etc.).
            let projDBURL = Bundle.module.bundleURL.appendingPathComponent("Contents/Resources").path()
            let driversURL = Bundle.module.bundleURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Frameworks/pdalcpp.framework/Versions/A/PlugIns").path()
            #endif
            return (projDBURL, driversURL)
        }
    }

    public static func read(from path: String, readerName: String = "readers.text") throws -> PointCloud {
        
        let isTesting = ProcessInfo.processInfo.environment["SWIFTPDAL_TESTING"] != nil
        let paths = Self.getPaths(isTesting: isTesting)
        setenv("PROJ_DATA", paths.projDBURL, 1)
        setenv("PDAL_DRIVER_PATH", paths.driversURL, 1)
        
        var outData: UnsafePointer<CChar>?
        var outSize: Int = 0
        var outCount: Int = 0
        var outStride: Int = 0
        var dimList: UnsafeMutablePointer<PDALDimensionInfo>?
        var dimCount: Int = 0
        var bbox = PDALBounds()
        
        var result: Int32 = 0
        readerName.withCString { readerPtr in
            path.withCString { pathPtr in
                result = pdal_read_binary(
                    readerPtr,
                    pathPtr,
                    &outData,
                    &outSize,
                    &outCount,
                    &outStride,
                    &dimList,
                    &dimCount,
                    &bbox
                )
            }
        }

        guard result == 0, let data = outData else {
            throw PointCloudError.readFailed("Failed to read point cloud from \(path)")
        }

        let bounds = Bounds(
            min: simd_float3(bbox.min_x, bbox.min_y, bbox.min_z),
            max: simd_float3(bbox.max_x, bbox.max_y, bbox.max_z)
        )

        let dimensions: [DimensionInfo] = if let dimList = dimList, dimCount > 0 {
            (0..<dimCount).map { i in DimensionInfo(from: dimList[i]) }
        } else {
            []
        }
        // Note: dimension info extraction would need additional C wrapper functions

        return PointCloud(
            filePath: path,
            pointCount: outCount,
            bounds: bounds,
            data: UnsafeRawPointer(data),
            size: outSize,
            stride: outStride,
            dimensions: dimensions
        )
    }

    deinit {
        if !dataFreed {
            pdal_free_data(UnsafePointer<CChar>(OpaquePointer(data)), nil, 0)
        }
    }

    /**
     * Creates an MTLBuffer that directly references the point cloud's
     * C-allocated memory without copying.
     *
     * This function transfers ownership of the C-buffer to the new
     * MTLBuffer. After calling this, deinit will no longer free the data
     * (to prevent a double-free).
     * The memory will be freed by Metal via the C-API when the
     * MTLBuffer is deallocated.
     *
     * - Parameter device: The MTLDevice to create the buffer with.
     * - Parameter options: Resource options for the buffer.
     * - Returns: A new MTLBuffer or nil if data was already freed.
     */
    public func makeBuffer(
        device: MTLDevice,
        options: MTLResourceOptions = .storageModeShared
    ) -> MTLBuffer? {
        
        guard !dataFreed else {
            assertionFailure("Attempted to create MTLBuffer from already-freed data.")
            return nil
        }

        let mutableDataPtr = UnsafeMutableRawPointer(mutating: self.data)
        let deallocator: (@Sendable (UnsafeMutableRawPointer, Int) -> Void)? = { (pointer, length) in
            pdal_free_data(UnsafePointer<CChar>(OpaquePointer(pointer)), nil, 0)
        }
        
        // Create the buffer using the "no copy" initializer
        let buffer = device.makeBuffer(
            bytesNoCopy: mutableDataPtr,
            length: self.size,
            options: options,
            deallocator: deallocator
        )

        if buffer != nil {
            self.dataFreed = true
        }
        
        mtlBuffer = buffer
        return buffer
    }
}

public enum PointCloudError: Error {
    case readFailed(String)
    case streamingFailed(String)
}

// MARK: - Streaming Support

// Global callback storage (thread-unsafe, but streaming is synchronous)
// Note: Marked nonisolated(unsafe) because PDAL streaming is synchronous single-threaded
nonisolated(unsafe) private var streamingCallbackGlobal: ((ChunkData, UnsafePointer<PDALDimensionInfo>?, Int) -> Bool)?

public struct PointCloudChunk: Sendable {
    private let ownedData: Data  // Owns a copy of the data
    public let pointCount: Int
    public let stride: Int
    public let isComplete: Bool
    public let totalPointsSoFar: Int
    public let estimatedTotalPoints: Int
    public let currentBounds: Bounds

    public var data: UnsafeRawPointer {
        ownedData.withUnsafeBytes { $0.baseAddress.unsafelyUnwrapped }
    }

    public init(data: Data, pointCount: Int, stride: Int, isComplete: Bool, totalPointsSoFar: Int, estimatedTotalPoints: Int, currentBounds: Bounds) {
        self.ownedData = Data(data)
        self.pointCount = pointCount
        self.stride = stride
        self.isComplete = isComplete
        self.totalPointsSoFar = totalPointsSoFar
        self.estimatedTotalPoints = estimatedTotalPoints
        self.currentBounds = currentBounds
    }

    public init(from chunkData: ChunkData) {
        // CRITICAL: Copy the data immediately since the C++ buffer will be reused
        let byteCount = chunkData.pointCount * chunkData.stride
        self.ownedData = Data(bytes: chunkData.data!, count: byteCount)
        self.pointCount = chunkData.pointCount
        self.stride = chunkData.stride
        self.isComplete = chunkData.isComplete
        self.totalPointsSoFar = chunkData.totalPointsSoFar
        self.estimatedTotalPoints = chunkData.estimatedTotalPoints
        self.currentBounds = Bounds(
            min: simd_float3(chunkData.currentBounds.min_x, chunkData.currentBounds.min_y, chunkData.currentBounds.min_z),
            max: simd_float3(chunkData.currentBounds.max_x, chunkData.currentBounds.max_y, chunkData.currentBounds.max_z)
        )
    }
}

public struct StreamingProgress: Sendable {
    public let chunk: PointCloudChunk
    public let dimensions: [DimensionInfo]

    public init(chunk: PointCloudChunk, dimensions: [DimensionInfo]) {
        self.chunk = chunk
        self.dimensions = dimensions
    }
    
    public var progress: Double {
        guard estimatedTotalPoints > 0 else { return 0.0 }
        return Double(chunk.totalPointsSoFar) / Double(chunk.estimatedTotalPoints)
    }

    public var estimatedTotalPoints: Int {
        chunk.estimatedTotalPoints > 0 ? chunk.estimatedTotalPoints : chunk.totalPointsSoFar
    }
}

/// Handles streaming point cloud loading with progressive updates
public final class StreamingPointCloud: PointCloudData, @unchecked Sendable {

    public let filePath: String
    public let readerName: String
    public let chunkSize: Int
    public let dimensionMap: [String: String]  // Stored as Swift dict, converted to DimensionMap for C++

    private let boundsLock = NSLock()

    // Retained PointViewContext from loadInfo (to avoid re-reading file)
    // Swift ARC integrates with std::shared_ptr reference counting automatically
    private var pointViewContext: PointViewContextPtr? = nil

    private var _bounds: Bounds = .init(min: .zero, max: .zero)
    public var bounds: Bounds {
        get { boundsLock.withLock { _bounds } }
        set { boundsLock.withLock { _bounds = newValue } }
    }
    public var pointCount: Int = 0
    public var data: UnsafeRawPointer {
        if let mtlBuffer {
            return UnsafeRawPointer(mtlBuffer.contents())
        }
        fatalError("StreamingPointCloud.data: No buffer available")
    }

    public var mtlBuffer: MTLBuffer?
    public var size: Int = 0
    public var stride: Int = 0
    public var dimensions: [DimensionInfo] = []

    public init(
        filePath: String,
        readerName: String = "readers.text",
        chunkSize: Int = 100000,
        dimensionMap: [String: String] = [:]
    ) {
        self.filePath = filePath
        self.readerName = readerName
        self.chunkSize = chunkSize
        self.dimensionMap = dimensionMap
    }

    // No deinit needed - std::shared_ptr is managed by Swift ARC automatically

    public func loadInfo(readerName: String = "readers.text") throws {

        let isTesting = ProcessInfo.processInfo.environment["SWIFTPDAL_TESTING"] != nil
        let paths = PointCloud.getPaths(isTesting: isTesting)
        setenv("PROJ_DATA", paths.projDBURL, 1)
        setenv("PDAL_DRIVER_PATH", paths.driversURL, 1)

        var outCount: Int = 0
        var outStride: Int = 0
        var dimList: UnsafeMutablePointer<PDALDimensionInfo>?
        var dimCount: Int = 0
        var bbox = PDALBounds()
        var outView = PointViewContextPtr()

        var loadResult: Int32 = 0
        readerName.withCString { readerPtr in
            filePath.withCString { pathPtr in
                loadResult = pdal_load_info(
                    readerPtr,
                    pathPtr,
                    &outCount,
                    &outStride,
                    &dimList,
                    &dimCount,
                    &bbox,
                    &outView
                )
            }
        }

        guard loadResult == 0 else {
            throw PointCloudError.readFailed("Failed to read point cloud from \(filePath)")
        }

        let bounds = Bounds(
            min: simd_float3(bbox.min_x, bbox.min_y, bbox.min_z),
            max: simd_float3(bbox.max_x, bbox.max_y, bbox.max_z)
        )

        let dimensions: [DimensionInfo] = if let dimList = dimList, dimCount > 0 {
            (0..<dimCount).map { i in DimensionInfo(from: dimList[i]) }
        } else {
            []
        }

        self.stride = outStride
        self.pointCount = outCount
        self.dimensions = dimensions
        self.bounds = bounds

        // Retain the PointViewContext for later streaming
        self.pointViewContext = outView
    }

    /// Stream point cloud chunks progressively
    /// - Returns: AsyncStream yielding progress updates for each chunk
    ///
    /// Example:
    /// ```swift
    /// let stream = StreamingPointCloud(filePath: path)
    /// try stream.loadInfo()  // Load metadata first
    /// for try await progress in stream.load() {
    ///     print("Progress: \(progress.chunk.totalPointsSoFar) points")
    ///     print("Current bounds: \(stream.bounds)")
    ///     if progress.chunk.isComplete {
    ///         print("Final bounds: \(stream.bounds)")
    ///     }
    /// }
    /// ```
    public func load() -> AsyncThrowingStream<StreamingProgress, Error> {
        AsyncThrowingStream { continuation in
            let capturedViewContext = self.pointViewContext
            // Convert Swift dict to C++ DimensionMap
            var dimMap = DimensionMap()
            for (key, value) in self.dimensionMap {
                insert_dimension(&dimMap, std.string(key), std.string(value))
            }

            Task.detached { [weak self, filePath, readerName, chunkSize] in
                do {
                    if let viewCtx = capturedViewContext {
                        try Self.readStreamingFromView(
                            viewContext: viewCtx,
                            chunkSize: chunkSize,
                            dimensionMap: dimMap
                        ) { progress in
                            self?.bounds = progress.chunk.currentBounds
                            continuation.yield(progress)
                            return !Task.isCancelled
                        }
                    } else {
                        _ = try Self.readStreamingInternal(
                            from: filePath,
                            readerName: readerName,
                            chunkSize: chunkSize,
                            dimensionMap: dimMap
                        ) { progress in
                            self?.bounds = progress.chunk.currentBounds
                            continuation.yield(progress)
                            return !Task.isCancelled
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    public func makeBuffer(device: any MTLDevice, options: MTLResourceOptions) -> (any MTLBuffer)? {
        let totalByteLength = pointCount * stride
        mtlBuffer = device.makeBuffer(length: totalByteLength, options: options)
        return mtlBuffer
    }
    

    // MARK: - Internal Implementation

    private static func readStreamingInternal(
        from path: String,
        readerName: String,
        chunkSize: Int,
        dimensionMap: DimensionMap,
        onProgress: @escaping (StreamingProgress) -> Bool
    ) throws -> Bounds {
        let isTesting = ProcessInfo.processInfo.environment["SWIFTPDAL_TESTING"] != nil
        let _ = PointCloud.getPaths(isTesting: isTesting)

        var bbox = PDALBounds()

        final class CallbackBox {
            var onProgress: (StreamingProgress) -> Bool
            var savedDimensions: [DimensionInfo]?

            init(onProgress: @escaping (StreamingProgress) -> Bool) {
                self.onProgress = onProgress
            }

            func handle(chunkData: ChunkData, dimInfo: UnsafePointer<PDALDimensionInfo>?, dimCount: Int) -> Bool {
                if savedDimensions == nil && chunkData.dimensionCount > 0 {
                    if let dims = chunkData.dimensions {
                        savedDimensions = (0..<chunkData.dimensionCount).map { i in
                            DimensionInfo(from: dims[i])
                        }
                    }
                }

                let chunk = PointCloudChunk(from: chunkData)
                let progress = StreamingProgress(
                    chunk: chunk,
                    dimensions: savedDimensions ?? []
                )

                return onProgress(progress)
            }
        }

        final class CallbackContext {
            let box: CallbackBox
            var dimensions: [PDALDimensionInfo] = []
            init(box: CallbackBox) {
                self.box = box
            }
        }

        let box = CallbackBox(onProgress: onProgress)
        let context = CallbackContext(box: box)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        defer {
            Unmanaged<CallbackContext>.fromOpaque(contextPtr).release()
        }

        let callback: @convention(c) (
            UnsafePointer<ChunkData>?,
            UnsafeMutableRawPointer?
        ) -> Bool = { chunk, ctx in
            guard let ctx = ctx, let chunk = chunk else {
                return false
            }
            let chunkData = chunk.pointee
            let context = Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.box.handle(chunkData: chunkData, dimInfo: nil, dimCount: context.dimensions.count)
        }
        
        var streamResult: Int32 = 0
        readerName.withCString { readerPtr in
            path.withCString { pathPtr in
                streamResult = pdal_read_binary_stream_progressive(
                    readerPtr,
                    pathPtr,
                    chunkSize,
                    callback,
                    contextPtr,
                    &bbox,
                    dimensionMap
                )
            }
        }

        guard streamResult == 0 else {
            let errorMessage: String
            switch streamResult {
            case -1: errorMessage = "Not implemented on this platform"
            case -2: errorMessage = "PDAL error occurred"
            case -3: errorMessage = "Standard exception occurred"
            case -4: errorMessage = "Failed to create stage"
            case -5: errorMessage = "No points in view"
            case -6: errorMessage = "Unknown error"
            case -7: errorMessage = "Invalid callback"
            case -8: errorMessage = "Invalid chunk size"
            default: errorMessage = "Unknown error code: \(streamResult)"
            }
            throw PointCloudError.streamingFailed("Failed to read point cloud from \(path): \(errorMessage)")
        }

        return Bounds(
            min: simd_float3(bbox.min_x, bbox.min_y, bbox.min_z),
            max: simd_float3(bbox.max_x, bbox.max_y, bbox.max_z)
        )
    }

    private static func readStreamingFromView(
        viewContext: PointViewContextPtr,
        chunkSize: Int,
        dimensionMap: DimensionMap,
        onProgress: @escaping (StreamingProgress) -> Bool
    ) throws {
        final class CallbackBox {
            var onProgress: (StreamingProgress) -> Bool
            var savedDimensions: [DimensionInfo]?

            init(onProgress: @escaping (StreamingProgress) -> Bool) {
                self.onProgress = onProgress
            }

            func handle(chunkData: ChunkData, dimInfo: UnsafePointer<PDALDimensionInfo>?, dimCount: Int) -> Bool {
                if savedDimensions == nil && chunkData.dimensionCount > 0 {
                    if let dims = chunkData.dimensions {
                        savedDimensions = (0..<chunkData.dimensionCount).map { i in
                            DimensionInfo(from: dims[i])
                        }
                    }
                }
                let chunk = PointCloudChunk(from: chunkData)
                let progress = StreamingProgress(
                    chunk: chunk,
                    dimensions: savedDimensions ?? []
                )

                return onProgress(progress)
            }
        }

        final class CallbackContext {
            let box: CallbackBox
            var dimensions: [PDALDimensionInfo] = []
            init(box: CallbackBox) {
                self.box = box
            }
        }

        let box = CallbackBox(onProgress: onProgress)
        let context = CallbackContext(box: box)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        defer {
            Unmanaged<CallbackContext>.fromOpaque(contextPtr).release()
        }

        let callback: @convention(c) (
            UnsafePointer<ChunkData>?,
            UnsafeMutableRawPointer?
        ) -> Bool = { chunk, ctx in
            guard let ctx = ctx, let chunk = chunk else {
                return false
            }
            let chunkData = chunk.pointee
            let context = Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.box.handle(chunkData: chunkData, dimInfo: nil, dimCount: context.dimensions.count)
        }

        let result = pdal_read_binary_stream_from_view(
            viewContext,
            chunkSize,
            callback,
            contextPtr,
            dimensionMap
        )

        guard result == 0 else {
            let errorMessage: String
            switch result {
            case -1: errorMessage = "Not implemented on this platform"
            case -2: errorMessage = "PDAL error occurred"
            case -3: errorMessage = "Standard exception occurred"
            case -7: errorMessage = "Invalid callback"
            case -8: errorMessage = "Invalid chunk size"
            case -9: errorMessage = "Invalid view pointer"
            case -10: errorMessage = "Memory allocation failed"
            default: errorMessage = "Unknown error code: \(result)"
            }
            throw PointCloudError.streamingFailed("Failed to stream from view: \(errorMessage)")
        }
    }
}

// MARK: - Convenience Extension

extension PointCloud {
    /// Convenience method to create a StreamingPointCloud for loading
    /// - Parameters:
    ///   - path: Path to the point cloud file
    ///   - readerName: PDAL reader name (default: "readers.text")
    ///   - chunkSize: Number of points per chunk (default: 10000)
    /// - Returns: StreamingPointCloud ready to load
    public static func streaming(
        from path: String,
        readerName: String = "readers.text",
        chunkSize: Int = 10000
    ) -> StreamingPointCloud {
        StreamingPointCloud(
            filePath: path,
            readerName: readerName,
            chunkSize: chunkSize
        )
    }
}

// MARK: - PDAL Dimension Type Helpers

/// Error codes for PDAL operations
public enum PDALError: Int, Sendable {
    case ok = 0
    case notImplemented = -1
    case pdalError = -2
    case stdException = -3
    case createStageFailed = -4
    case noPoints = -5
    case unknown = -6
    case invalidCallback = -7
    case invalidChunkSize = -8
    case invalidViewPointer = -9
    case allocFailed = -10
    
    public var message: String {
        switch self {
        case .ok: return "OK"
        case .notImplemented: return "Not implemented on this platform"
        case .pdalError: return "PDAL error occurred"
        case .stdException: return "Standard exception occurred"
        case .createStageFailed: return "Failed to create stage"
        case .noPoints: return "No points in view"
        case .unknown: return "Unknown error"
        case .invalidCallback: return "Invalid callback"
        case .invalidChunkSize: return "Invalid chunk size"
        case .invalidViewPointer: return "Invalid view pointer"
        case .allocFailed: return "Memory allocation failed"
        }
    }
}

/// Helper utilities for working with PDAL Dimension Types
public enum PDALDimensionTypeHelper {

    /// Returns the human-readable name for a PDAL dimension type
    public static func name(for type: pdal.Dimension.`Type`) -> String {
        switch type {
        case .None:
            return "None"
        case .Unsigned8:
            return "UInt8"
        case .Signed8:
            return "Int8"
        case .Unsigned16:
            return "UInt16"
        case .Signed16:
            return "Int16"
        case .Unsigned32:
            return "UInt32"
        case .Signed32:
            return "Int32"
        case .Unsigned64:
            return "UInt64"
        case .Signed64:
            return "Int64"
        case .Float:
            return "Float"
        case .Double:
            return "Double"
        default:
            return "Unknown(\(type.rawValue))"
        }
    }
    
    /// Returns the Metal shader language type name for a PDAL dimension type
    public static func mtlName(for type: pdal.Dimension.`Type`) -> String {
        switch type {
        case .None:
            return "void"
        case .Unsigned8:
            return "uchar"
        case .Signed8:
            return "char"
        case .Unsigned16:
            return "ushort"
        case .Signed16:
            return "short"
        case .Unsigned32:
            return "uint"
        case .Signed32:
            return "int"
        case .Unsigned64:
            return "ulong"
        case .Signed64:
            return "long"
        case .Float:
            return "float"
        case .Double:
            return "double"
        default:
            return "void /* Unknown(\(type.rawValue)) */"
        }
    }
    
    /// Returns the size in bytes for a PDAL dimension type
    public static func byteSize(for type: pdal.Dimension.`Type`) -> Int {
        switch type {
        case .None:
            return 0
        case .Unsigned8, .Signed8:
            return 1
        case .Unsigned16, .Signed16:
            return 2
        case .Unsigned32, .Signed32, .Float:
            return 4
        case .Unsigned64, .Signed64, .Double:
            return 8
        default:
            return 0
        }
    }

    /// Returns whether the type is a floating point type
    public static func isFloatingPoint(_ type: pdal.Dimension.`Type`) -> Bool {
        return type == .Float || type == .Double
    }

    /// Returns whether the type is a signed integer type
    public static func isSignedInteger(_ type: pdal.Dimension.`Type`) -> Bool {
        switch type {
        case .Signed8, .Signed16, .Signed32, .Signed64:
            return true
        default:
            return false
        }
    }

    /// Returns whether the type is an unsigned integer type
    public static func isUnsignedInteger(_ type: pdal.Dimension.`Type`) -> Bool {
        switch type {
        case .Unsigned8, .Unsigned16, .Unsigned32, .Unsigned64:
            return true
        default:
            return false
        }
    }
}

// MARK: - PDALDimensionInfo Extension

extension PDALDimensionInfo {
    /// Returns the human-readable name for this dimension's type
    public var typeName: String {
        PDALDimensionTypeHelper.name(for: outputType)
    }
    
    /// Returns the human-readable name for this dimension's type
    public var mtlTypeName: String {
        PDALDimensionTypeHelper.mtlName(for: outputType)
    }

    /// Returns the size in bytes for this dimension's type
    public var typeByteSize: Int {
        PDALDimensionTypeHelper.byteSize(for: outputType)
    }

    /// Returns whether this dimension's type is floating point
    public var isFloatingPoint: Bool {
        PDALDimensionTypeHelper.isFloatingPoint(outputType)
    }

    /// Returns whether this dimension's type is a signed integer
    public var isSignedInteger: Bool {
        PDALDimensionTypeHelper.isSignedInteger(outputType)
    }

    /// Returns whether this dimension's type is an unsigned integer
    public var isUnsignedInteger: Bool {
        PDALDimensionTypeHelper.isUnsignedInteger(outputType)
    }
}

extension DimensionInfo {
    /// Returns the human-readable name for this dimension's type
    public var typeName: String {
        PDALDimensionTypeHelper.name(for: outputType)
    }
    
    /// Returns the Metal shader language type name
    public var mtlTypeName: String {
        PDALDimensionTypeHelper.mtlName(for: outputType)
    }

    /// Returns the size in bytes for this dimension's type
    public var typeByteSize: Int {
        PDALDimensionTypeHelper.byteSize(for: outputType)
    }

    /// Returns whether this dimension's type is floating point
    public var isFloatingPoint: Bool {
        PDALDimensionTypeHelper.isFloatingPoint(outputType)
    }

    /// Returns whether this dimension's type is a signed integer
    public var isSignedInteger: Bool {
        PDALDimensionTypeHelper.isSignedInteger(outputType)
    }

    /// Returns whether this dimension's type is an unsigned integer
    public var isUnsignedInteger: Bool {
        PDALDimensionTypeHelper.isUnsignedInteger(outputType)
    }
}

