import Metal
import simd

// MARK: - Bounding Box Rendering

extension OctreeCell {

    /// Get the 8 corner vertices of this cell's bounding box
    public var boundingBoxVertices: [simd_float3] {
        [
            simd_float3(bounds.min.x, bounds.min.y, bounds.min.z), // 0: min corner
            simd_float3(bounds.max.x, bounds.min.y, bounds.min.z), // 1
            simd_float3(bounds.max.x, bounds.max.y, bounds.min.z), // 2
            simd_float3(bounds.min.x, bounds.max.y, bounds.min.z), // 3
            simd_float3(bounds.min.x, bounds.min.y, bounds.max.z), // 4
            simd_float3(bounds.max.x, bounds.min.y, bounds.max.z), // 5
            simd_float3(bounds.max.x, bounds.max.y, bounds.max.z), // 6: max corner
            simd_float3(bounds.min.x, bounds.max.y, bounds.max.z)  // 7
        ]
    }

    /// Get line indices for rendering the bounding box edges (12 edges, 24 vertices)
    public static var boundingBoxLineIndices: [UInt32] {
        [
            // Bottom face (z = min)
            0, 1,  1, 2,  2, 3,  3, 0,
            // Top face (z = max)
            4, 5,  5, 6,  6, 7,  7, 4,
            // Vertical edges
            0, 4,  1, 5,  2, 6,  3, 7
        ]
    }

    /// Create a Metal buffer containing the bounding box vertices
    /// - Parameter device: Metal device
    /// - Returns: Metal buffer with 8 vertices (simd_float3)
    public func createBoundingBoxVertexBuffer(device: MTLDevice) -> MTLBuffer? {
        let vertices = boundingBoxVertices
        let bufferSize = vertices.count * MemoryLayout<simd_float3>.stride

        guard let buffer = device.makeBuffer(
            bytes: vertices,
            length: bufferSize,
            options: .storageModeShared
        ) else {
            return nil
        }

        return buffer
    }

    /// Create a Metal buffer containing line indices for the bounding box
    /// - Parameter device: Metal device
    /// - Returns: Metal buffer with 24 indices (12 lines)
    public static func createBoundingBoxIndexBuffer(device: MTLDevice) -> MTLBuffer? {
        let indices = boundingBoxLineIndices
        let bufferSize = indices.count * MemoryLayout<UInt16>.stride

        guard let buffer = device.makeBuffer(
            bytes: indices,
            length: bufferSize,
            options: .storageModeShared
        ) else {
            return nil
        }

        return buffer
    }
}

// MARK: - Batch Bounding Box Rendering

extension Array where Element == OctreeCell {

    /// Create a single Metal buffer containing all bounding box vertices for multiple cells
    /// - Parameter device: Metal device
    /// - Returns: Tuple of (vertex buffer, index buffer, vertex count per cell)
    public func createBatchedBoundingBoxBuffers(device: MTLDevice) -> (vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer, vertexCount: Int)? {
        guard !isEmpty else { return nil }

        // Each cell has 8 vertices
        var allVertices: [simd_float3] = []
        allVertices.reserveCapacity(count * 8)

        for cell in self {
            allVertices.append(contentsOf: cell.boundingBoxVertices)
        }

        // Create vertex buffer
        let vertexBufferSize = allVertices.count * MemoryLayout<simd_float3>.stride
        guard let vertexBuffer = device.makeBuffer(
            bytes: allVertices,
            length: vertexBufferSize,
            options: .storageModeShared
        ) else {
            return nil
        }

        // Create index buffer - adjust indices for each cell
        var allIndices: [UInt32] = []
        allIndices.reserveCapacity(count * 24)

        let baseIndices = OctreeCell.boundingBoxLineIndices
        for i in 0..<count {
            let offset = UInt32(i * 8)
            for index in baseIndices {
                allIndices.append(index + offset)
            }
        }

        let indexBufferSize = allIndices.count * MemoryLayout<UInt16>.stride
        guard let indexBuffer = device.makeBuffer(
            bytes: allIndices,
            length: indexBufferSize,
            options: .storageModeShared
        ) else {
            return nil
        }

        return (vertexBuffer, indexBuffer, allVertices.count)
    }

    /// Get total number of bounding box edges (lines) for all cells
    public var totalBoundingBoxEdges: Int {
        count * 12 // Each box has 12 edges
    }
}
