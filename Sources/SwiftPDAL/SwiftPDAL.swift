import CxxPDAL
import Foundation
import Metal
import simd

public protocol PointCloudData {
    var filePath: String { get }
    var pointCount: Int { get }
    var bounds: Bounds { get }
    var stride: Int { get }
    var dimensions: [PDALDimensionInfo] { get }
    var data: UnsafeRawPointer { get }
    var mtlBuffer: MTLBuffer? { get }
    mutating func makeBuffer(device: MTLDevice, options: MTLResourceOptions) -> MTLBuffer?
}
    
public struct Bounds {
    public let min: simd_float3
    public let max: simd_float3

    /// Transform the bounds by a 4x4 transformation matrix
    /// - Parameter transform: The transformation matrix to apply
    /// - Returns: A new Bounds with transformed min and max corners
    public func transformed(by transform: simd_float4x4) -> Bounds {
        // Transform the min and max corners
        let minHomogeneous = simd_float4(min.x, min.y, min.z, 1.0)
        let maxHomogeneous = simd_float4(max.x, max.y, max.z, 1.0)

        let transformedMin = transform * minHomogeneous
        let transformedMax = transform * maxHomogeneous

        // Convert back to 3D coordinates (divide by w)
        let min3D = simd_float3(
            transformedMin.x / transformedMin.w,
            transformedMin.y / transformedMin.w,
            transformedMin.z / transformedMin.w
        )
        let max3D = simd_float3(
            transformedMax.x / transformedMax.w,
            transformedMax.y / transformedMax.w,
            transformedMax.z / transformedMax.w
        )

        // After transformation, min and max might swap, so recalculate
        return Bounds(
            min: simd_min(min3D, max3D),
            max: simd_max(min3D, max3D)
        )
    }
}

public struct PointCloud: PointCloudData {

    public let filePath: String
    public let pointCount: Int
    public let bounds: Bounds
    public let data: UnsafeRawPointer
    public let size: Int
    public let stride: Int
    public let dimensions: [PDALDimensionInfo]
    
    public var mtlBuffer: MTLBuffer?

    private var dataFreed: Bool = false

    public static func getPaths(isTesting: Bool) -> (projDBURL: String, driversURL: String) {
        if isTesting {
            let bundlePath = Bundle.module.bundlePath as NSString
            let projDBURL = bundlePath.deletingLastPathComponent
                .appending("/SwiftPDAL_SwiftPDAL.bundle")
            let driversURL = Bundle.module.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("pdalcpp.framework/Versions/A/PlugIns").path()
            return (projDBURL, driversURL)
        } else {
            let projDBURL = Bundle.module.bundleURL.appendingPathComponent("Contents/Resources").path()
            let driversURL = Bundle.module.bundleURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Frameworks/pdalcpp.framework/Versions/A/PlugIns").path()
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
        
        let result = pdal_read_binary(
                    std.string(readerName),
                    std.string(path),
                    &outData,
                    &outSize,
                    &outCount,
                    &outStride,
                    &dimList,
                    &dimCount,
                    &bbox
                )

        guard result == 0, let data = outData else {
            throw PointCloudError.readFailed("Failed to read point cloud from \(path)")
        }

        let bounds = Bounds(
            min: simd_float3(bbox.min_x, bbox.min_y, bbox.min_z),
            max: simd_float3(bbox.max_x, bbox.max_y, bbox.max_z)
        )

        let dimensions: [PDALDimensionInfo] = if let dimList = dimList, dimCount > 0 {
            Array(UnsafeBufferPointer(start: dimList, count: dimCount))
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

    public mutating func cleanup() {
        guard !dataFreed else { return } // Prevent double-free
        pdal_free_data(UnsafePointer<CChar>(OpaquePointer(data)), nil)
        dataFreed = true
    }

    /**
     * Creates an MTLBuffer that directly references the point cloud's
     * C-allocated memory without copying.
     *
     * This function transfers ownership of the C-buffer to the new
     * MTLBuffer. After calling this, the `PointCloud.cleanup()` method
     * will no longer free the data (to prevent a double-free).
     * The memory will be freed by Metal via the C-API when the
     * MTLBuffer is deallocated.
     *
     * - Parameter device: The MTLDevice to create the buffer with.
     * - Parameter options: Resource options for the buffer.
     * - Returns: A new MTLBuffer or nil if data was already freed.
     */
    public mutating func makeBuffer(
        device: MTLDevice,
        options: MTLResourceOptions = .storageModeShared
    ) -> MTLBuffer? {
        
        guard !dataFreed else {
            assertionFailure("Attempted to create MTLBuffer from already-freed data.")
            return nil
        }

        let mutableDataPtr = UnsafeMutableRawPointer(mutating: self.data)
        let deallocator: (@Sendable (UnsafeMutableRawPointer, Int) -> Void)? = { (pointer, length) in
            pdal_free_data(UnsafePointer<CChar>(OpaquePointer(pointer)), nil)
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

// MARK: - PointCloud Extension

extension PointCloudData {
    public func buildOctree(maxPointsPerNode: Int = 100, maxDepth: Int = 8, useMortonOrder: Bool = true) -> Octree {
        Octree(
            pointCloud: self,
            maxPointsPerNode: maxPointsPerNode,
            maxDepth: maxDepth,
            useMortonOrder: useMortonOrder
        )
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

public struct PointCloudChunk: @unchecked Sendable {
    private let ownedData: Data  // Owns a copy of the data
    public let pointCount: Int
    public let stride: Int
    public let isComplete: Bool
    public let totalPointsSoFar: Int
    public let estimatedTotalPoints: Int

    public var data: UnsafeRawPointer {
        ownedData.withUnsafeBytes { $0.baseAddress! }
    }

    init(from chunkData: ChunkData) {
        // CRITICAL: Copy the data immediately since the C++ buffer will be reused
        let byteCount = chunkData.pointCount * chunkData.stride
        self.ownedData = Data(bytes: chunkData.data!, count: byteCount)

        self.pointCount = chunkData.pointCount
        self.stride = chunkData.stride
        self.isComplete = chunkData.isComplete
        self.totalPointsSoFar = chunkData.totalPointsSoFar
        self.estimatedTotalPoints = chunkData.estimatedTotalPoints
    }
}

public struct StreamingProgress: Sendable {
    public let chunk: PointCloudChunk
    public let dimensions: [PDALDimensionInfo]

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

    private let boundsLock = NSLock()

    // Retained PointViewPtr from loadInfo (to avoid re-reading file)
    private var pointViewPtr: UnsafeMutableRawPointer? = nil

    //
    public var pointCount: Int = 0
    public var bounds: Bounds = .init(min: .zero, max: .zero)
    public var data: UnsafeRawPointer {
        if let mtlBuffer {
            return UnsafeRawPointer(mtlBuffer.contents())
        }
        // Return a null pointer if no buffer exists yet
        return UnsafeRawPointer(bitPattern: 0)!
    }
    
    public var mtlBuffer: MTLBuffer?
    public var size: Int = 0
    public var stride: Int = 0
    public var dimensions: [PDALDimensionInfo] = []

    public init(
        filePath: String,
        readerName: String = "readers.text",
        chunkSize: Int = 100000
    ) {
        self.filePath = filePath
        self.readerName = readerName
        self.chunkSize = chunkSize
    }

    deinit {
        // Clean up the retained PointViewPtr if it exists
        if let viewPtr = pointViewPtr {
            pdal_free_point_view(viewPtr)
        }
    }
    
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
        var outView: UnsafeMutableRawPointer? = nil

        let result = pdal_load_info(
                    std.string(readerName),
                    std.string(filePath),
                    &outCount,
                    &outStride,
                    &dimList,
                    &dimCount,
                    &bbox,
                    &outView
                )

        guard result == 0 else {
            throw PointCloudError.readFailed("Failed to read point cloud from \(filePath)")
        }

        let bounds = Bounds(
            min: simd_float3(bbox.min_x, bbox.min_y, bbox.min_z),
            max: simd_float3(bbox.max_x, bbox.max_y, bbox.max_z)
        )

        let dimensions: [PDALDimensionInfo] = if let dimList = dimList, dimCount > 0 {
            Array(UnsafeBufferPointer(start: dimList, count: dimCount))
        } else {
            []
        }

        self.stride = outStride
        self.pointCount = outCount
        self.dimensions = dimensions
        self.bounds = bounds

        // Retain the PointViewPtr for later streaming
        self.pointViewPtr = outView
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
    ///     if progress.chunk.isComplete {
    ///         print("Bounds: \(stream.bounds)")
    ///     }
    /// }
    /// ```
    public func load() -> AsyncThrowingStream<StreamingProgress, Error> {
        AsyncThrowingStream { continuation in
            // Capture the viewPtr before entering the Task to ensure it stays alive
            let capturedViewPtr = self.pointViewPtr

            Task.detached { [filePath, readerName, chunkSize] in
                do {
                    // If we have a retained PointViewPtr, use it (avoids re-reading file)
                    if let viewPtr = capturedViewPtr {
                        try Self.readStreamingFromView(
                            viewPtr: viewPtr,
                            chunkSize: chunkSize
                        ) { progress in
                            continuation.yield(progress)
                            return !Task.isCancelled
                        }
                    } else {
                        // Fallback: read from file (legacy behavior)
                        _ = try Self.readStreamingInternal(
                            from: filePath,
                            readerName: readerName,
                            chunkSize: chunkSize
                        ) { progress in
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
        let options: MTLResourceOptions = .storageModeShared
        mtlBuffer = device.makeBuffer(length: totalByteLength, options: options)
        return mtlBuffer
    }
    

    // MARK: - Internal Implementation

    private static func readStreamingInternal(
        from path: String,
        readerName: String,
        chunkSize: Int,
        onProgress: @escaping (StreamingProgress) -> Bool
    ) throws -> Bounds {
        let isTesting = ProcessInfo.processInfo.environment["SWIFTPDAL_TESTING"] != nil
        let paths = PointCloud.getPaths(isTesting: isTesting)
        
        setenv("PROJ_DATA", paths.projDBURL, 1)
        setenv("PDAL_DRIVER_PATH", paths.driversURL, 1)

        var bbox = PDALBounds()

        // Box to hold our Swift closure and mutable state
        final class CallbackBox {
            var onProgress: (StreamingProgress) -> Bool
            var savedDimensions: [PDALDimensionInfo]?

            init(onProgress: @escaping (StreamingProgress) -> Bool) {
                self.onProgress = onProgress
            }

            func handle(chunkData: ChunkData, dimInfo: UnsafePointer<PDALDimensionInfo>?, dimCount: Int) -> Bool {
                // Save dimensions on first call
                if savedDimensions == nil, dimCount > 0 {
                    savedDimensions = Array(UnsafeBufferPointer(start: dimInfo, count: dimCount))
                }

                let chunk = PointCloudChunk(from: chunkData)
                let progress = StreamingProgress(
                    chunk: chunk,
                    dimensions: savedDimensions ?? []
                )

                return onProgress(progress)
            }
        }

        // Create a box to hold our callback and dimensions
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

        // C-compatible callback function that uses context pointer
        // Parameters match the flattened C callback signature
        let callback: @convention(c) (
            UnsafePointer<CChar>?,  // data
            Int,                     // pointCount
            Int,                     // stride
            Bool,                    // isComplete
            Int,                     // totalPointsSoFar
            Int,                     // estimatedTotalPoints
            UnsafeMutableRawPointer? // context
        ) -> Bool = { data, pointCount, stride, isComplete, totalPointsSoFar, estimatedTotalPoints, ctx in
            guard let ctx = ctx else {
                print("DEBUG Swift: No context!")
                return false
            }
            // Reconstruct ChunkData from individual parameters
            let chunkData = ChunkData(
                data: data,
                pointCount: pointCount,
                stride: stride,
                isComplete: isComplete,
                totalPointsSoFar: totalPointsSoFar,
                estimatedTotalPoints: estimatedTotalPoints
            )
//            print(totalPointsSoFar, estimatedTotalPoints, isComplete)
            let context = Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()
            // Use dimensions stored in context
            return context.box.handle(chunkData: chunkData, dimInfo: nil, dimCount: context.dimensions.count)
        }
        
        // Call C++ function with context-based callback
        let result = pdal_read_binary_stream_progressive(
            std.string(readerName),
            std.string(path),
            chunkSize,
            callback,
            contextPtr,
            &bbox
        )

        guard result == 0 else {
            let errorMessage: String
            switch result {
            case -1: errorMessage = "Not implemented on this platform"
            case -2: errorMessage = "PDAL error occurred"
            case -3: errorMessage = "Standard exception occurred"
            case -4: errorMessage = "Failed to create stage"
            case -5: errorMessage = "No points in view"
            case -6: errorMessage = "Unknown error"
            case -7: errorMessage = "Invalid callback"
            case -8: errorMessage = "Invalid chunk size"
            default: errorMessage = "Unknown error code: \(result)"
            }
            throw PointCloudError.streamingFailed("Failed to read point cloud from \(path): \(errorMessage)")
        }

        return Bounds(
            min: simd_float3(bbox.min_x, bbox.min_y, bbox.min_z),
            max: simd_float3(bbox.max_x, bbox.max_y, bbox.max_z)
        )
    }

    private static func readStreamingFromView(
        viewPtr: UnsafeMutableRawPointer,
        chunkSize: Int,
        onProgress: @escaping (StreamingProgress) -> Bool
    ) throws {
        // Box to hold our Swift closure and mutable state
        final class CallbackBox {
            var onProgress: (StreamingProgress) -> Bool
            var savedDimensions: [PDALDimensionInfo]?

            init(onProgress: @escaping (StreamingProgress) -> Bool) {
                self.onProgress = onProgress
            }

            func handle(chunkData: ChunkData, dimInfo: UnsafePointer<PDALDimensionInfo>?, dimCount: Int) -> Bool {
                // Save dimensions on first call
                if savedDimensions == nil, dimCount > 0 {
                    savedDimensions = Array(UnsafeBufferPointer(start: dimInfo, count: dimCount))
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
            UnsafePointer<CChar>?,
            Int,
            Int,
            Bool,
            Int,
            Int,
            UnsafeMutableRawPointer?
        ) -> Bool = { data, pointCount, stride, isComplete, totalPointsSoFar, estimatedTotalPoints, ctx in
            guard let ctx = ctx else {
                return false
            }
            let chunkData = ChunkData(
                data: data,
                pointCount: pointCount,
                stride: stride,
                isComplete: isComplete,
                totalPointsSoFar: totalPointsSoFar,
                estimatedTotalPoints: estimatedTotalPoints
            )
            let context = Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.box.handle(chunkData: chunkData, dimInfo: nil, dimCount: context.dimensions.count)
        }

        let result = pdal_read_binary_stream_from_view(
            viewPtr,
            chunkSize,
            callback,
            contextPtr
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
