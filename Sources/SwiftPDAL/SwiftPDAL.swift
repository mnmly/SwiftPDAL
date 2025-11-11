import CxxPDAL
import Foundation
import Metal
import simd

public struct PointCloud {

    public let filePath: String
    public let pointCount: Int
    public let bounds: Bounds
    public let data: UnsafeRawPointer
    public let size: Int
    public let stride: Int
    public let dimensions: [PDALDimensionInfo]
    public struct Bounds {
        public let min: simd_float3
        public let max: simd_float3
    }

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

        return buffer
    }
}

// MARK: - PointCloud Extension

extension PointCloud {
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
    public let data: UnsafeRawPointer
    public let pointCount: Int
    public let stride: Int
    public let isComplete: Bool
    public let totalPointsSoFar: Int
    public let estimatedTotalPoints: Int

    init(from chunkData: ChunkData) {
        self.data = UnsafeRawPointer(chunkData.data)
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
public final class StreamingPointCloud: @unchecked Sendable {
    public let filePath: String
    public let readerName: String
    public let chunkSize: Int

    private let boundsLock = NSLock()
    private var _bounds: PointCloud.Bounds?

    public init(
        filePath: String,
        readerName: String = "readers.text",
        chunkSize: Int = 10000
    ) {
        self.filePath = filePath
        self.readerName = readerName
        self.chunkSize = chunkSize
    }

    /// Stream point cloud chunks progressively
    /// - Returns: AsyncStream yielding progress updates for each chunk
    ///
    /// Example:
    /// ```swift
    /// let stream = StreamingPointCloud(filePath: path)
    /// for try await progress in stream.load() {
    ///     print("Progress: \(progress.chunk.totalPointsSoFar) points")
    ///     if progress.chunk.isComplete {
    ///         print("Bounds: \(stream.loadedBounds)")
    ///     }
    /// }
    /// ```
    public func load() -> AsyncThrowingStream<StreamingProgress, Error> {
        AsyncThrowingStream { continuation in
            Task.detached { [filePath, readerName, chunkSize, weak self] in
                do {
                    let bounds = try Self.readStreamingInternal(
                        from: filePath,
                        readerName: readerName,
                        chunkSize: chunkSize
                    ) { progress in
                        continuation.yield(progress)
                        return !Task.isCancelled
                    }

                    // Store bounds for access after streaming completes
                    self?.setBounds(bounds)

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func setBounds(_ bounds: PointCloud.Bounds) {
        boundsLock.lock()
        defer { boundsLock.unlock() }
        _bounds = bounds
    }

    /// Access bounds after streaming completes
    public var loadedBounds: PointCloud.Bounds? {
        boundsLock.lock()
        defer { boundsLock.unlock() }
        return _bounds
    }

    // MARK: - Internal Implementation

    private static func readStreamingInternal(
        from path: String,
        readerName: String,
        chunkSize: Int,
        onProgress: @escaping (StreamingProgress) -> Bool
    ) throws -> PointCloud.Bounds {
        let isTesting = ProcessInfo.processInfo.environment["SWIFTPDAL_TESTING"] != nil
        let paths = PointCloud.getPaths(isTesting: isTesting)
        print("-=---------------------------")
        print(isTesting)
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

        // Create a box to hold our callback
        final class CallbackContext {
            let box: CallbackBox
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
        let callback: @convention(c) (ChunkData, UnsafePointer<PDALDimensionInfo>?, Int, UnsafeMutableRawPointer?) -> Bool = { chunkData, dimInfo, dimCount, ctx in
            print("DEBUG Swift: C callback invoked, dimCount=\(dimCount)")
            guard let ctx = ctx else {
                print("DEBUG Swift: No context!")
                return false
            }
            let context = Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()
            return context.box.handle(chunkData: chunkData, dimInfo: dimInfo, dimCount: dimCount)
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

        return PointCloud.Bounds(
            min: simd_float3(bbox.min_x, bbox.min_y, bbox.min_z),
            max: simd_float3(bbox.max_x, bbox.max_y, bbox.max_z)
        )
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
