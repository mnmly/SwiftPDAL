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
}
