import simd
import Metal

// MARK: - Frustum

public struct Frustum {
    public let planes: [simd_float4] // Each plane as (A, B, C, D) where Ax + By + Cz + D = 0

    public init(viewProjection: simd_float4x4) {
        var planes: [simd_float4] = []
        planes.reserveCapacity(6)
        let vp = simd_transpose(viewProjection);
        
        // Now vp.columns[i] gives us the i-th row of the original matrix
        let row0 = vp.columns.0;
        let row1 = vp.columns.1;
        let row2 = vp.columns.2;
        let row3 = vp.columns.3;
    
        // Extract and normalize planes
        // Left plane: row3 + row0
        planes.append(row3 + row0)
        
        // Right plane: row3 - row0
        planes.append(row3 - row0)
        
        // Bottom plane: row3 + row1
        planes.append(row3 + row1)
        
        // Top plane: row3 - row1
        planes.append(row3 - row1)
        
        // For Reverse-Z (near=1, far=0):
planes.append(row2)           // Near plane: just row2
planes.append(row3 - row2) 

        self.planes = planes.map { plane in
            let normal = simd_float3(plane.x, plane.y, plane.z)
            let length = simd_length(normal)
            return plane / length
        }
    }
    
    /// Create a frustum directly from plane equations
    public init(planes: [simd_float4]) {
        self.planes = planes
    }
    
    public func intersects(_ bounds: AABB) -> Bool {
        let planeNames = ["leftPlane", "rightPlane", "bottomPlane", "topPlane", "nearPlane", "farPlane"]    
        for (i, plane) in planes.enumerated() {
            // Select positive vertex components based on plane normal signs
            let p = SIMD3<Float>(
                plane.x > 0 ? bounds.max.x : bounds.min.x,
                plane.y > 0 ? bounds.max.y : bounds.min.y,
                plane.z > 0 ? bounds.max.z : bounds.min.z
            )
            let pp = simd_float3(plane.x, plane.y, plane.z)
            // Dot product + distance
            if simd_dot(pp, p) + plane.w < 0 {
                // print("\(planeNames[i]) clls the box.")
                return false
            }
        }
        return true
    }

    public enum IntersectionResult {
        case outside
        case inside
        case intersecting
    }

    public func intersectsResult(_ bounds: AABB) -> IntersectionResult {
        var inside = true
       
        let planeNames = ["leftPlane", "rightPlane", "bottomPlane", "topPlane", "nearPlane", "farPlane"]
        for (i, plane) in planes.enumerated() {
            let center = bounds.center
            let extent = bounds.size * 0.5
            
            // Calculate the effective radius of the box along the plane normal
            let radius = (abs(extent.x * plane.x)) + (abs(extent.y * plane.y)) + (abs(extent.z * plane.z))
            
            // Calculate signed distance from center to plane
            let distance = plane.x * center.x +
                          plane.y * center.y +
                          plane.z * center.z +
                          plane.w
            
            if distance < -radius {
                print(planeNames[i] + " culls the box.")
                return .outside // Box is completely outside this plane
            }
            
            if distance < radius {
                inside = false // Box intersects this plane
            }
        }
        
        return inside ? .inside : .intersecting
    }

    public static func fromCameraParameters(
        fov: Float,           // Field of view in radians
        aspect: Float,        // Width/Height ratio
        near: Float,          // Near plane distance
        far: Float,           // Far plane distance
        reversedZ: Bool = true // For Metal's reversed depth buffer
    ) -> Frustum {
        // In view space:
        // - Camera is at origin (0, 0, 0)
        // - Camera looks down -Z axis
        // - Up is +Y, Right is +X

        // Calculate half-angles
        let halfFovY = fov * 0.5
        let halfFovX = atan(tan(halfFovY) * aspect)

        // Calculate plane normals using rotation angles
        let cosX = cos(halfFovX)
        let sinX = sin(halfFovX)
        let cosY = cos(halfFovY)
        let sinY = sin(halfFovY)

        // Left plane: tilted inward from -X direction
        // Normal points right-inward
        let leftNormal = simd_normalize(
            SIMD3<Float>(cosX, 0, -sinX)  // Rotated around Y axis
        )
        let leftPlane = simd_float4(leftNormal.x, leftNormal.y, leftNormal.z, 0)

        // Right plane: tilted inward from +X direction
        // Normal points left-inward
        let rightNormal = simd_normalize(
            SIMD3<Float>(-cosX, 0, -sinX)  // Rotated around Y axis
        )
        let rightPlane = simd_float4(rightNormal.x, rightNormal.y, rightNormal.z, 0)

        // Bottom plane: tilted inward from -Y direction
        // Normal points up-inward
        let bottomNormal = simd_normalize(
            SIMD3<Float>(0, cosY, -sinY)  // Rotated around X axis
        )
        let bottomPlane = simd_float4(bottomNormal.x, bottomNormal.y, bottomNormal.z, 0)

        // Top plane: tilted inward from +Y direction
        // Normal points down-inward
        let topNormal = simd_normalize(
            SIMD3<Float>(0, -cosY, -sinY)  // Rotated around X axis
        )
        let topPlane = simd_float4(topNormal.x, topNormal.y, topNormal.z, 0)

        let nearPlane: simd_float4
        let farPlane: simd_float4

        if reversedZ {
            // For reversed-Z (Metal):
            // Near plane at Z = -near (in view space)
            // Normal points toward camera (+Z direction for reversed-Z culling)
            nearPlane = simd_float4(0, 0, -1, -near)

            // Far plane at Z = -far (in view space)
            // Normal points toward camera (+Z direction for reversed-Z culling)
            farPlane = simd_float4(0, 0, 1, far)
        } else {
            // Standard depth buffer:
            // Near plane normal points away from camera (-Z)
            nearPlane = simd_float4(0, 0, -1, -near)

            // Far plane normal points toward camera (+Z)
            farPlane = simd_float4(0, 0, 1, -far)
        }

        return Frustum(planes: [leftPlane, rightPlane, bottomPlane, topPlane, nearPlane, farPlane])
    }
}

// MARK: - AABB

public struct AABB {
    public var min: simd_float3
    public var max: simd_float3
    
    public init(min: simd_float3, max: simd_float3) {
        self.min = min
        self.max = max
    }
    
    public var center: simd_float3 {
        (min + max) * 0.5
    }
    
    public var size: simd_float3 {
        max - min
    }
    
    public func contains(_ point: simd_float3) -> Bool {
        point.x >= min.x && point.x <= max.x &&
        point.y >= min.y && point.y <= max.y &&
        point.z >= min.z && point.z <= max.z
    }
    
    public func intersects(_ other: AABB) -> Bool {
        min.x <= other.max.x && max.x >= other.min.x &&
        min.y <= other.max.y && max.y >= other.min.y &&
        min.z <= other.max.z && max.z >= other.min.z
    }
}

// MARK: - Octree Cell Code

/// Wrapper for MortonCode with level information for octree cells
public struct OctreeCellCode: Hashable, Comparable {
    public let morton: MortonCode
    public let level: UInt8

    public init(morton: MortonCode, level: UInt8) {
        self.morton = morton
        self.level = level
    }

    public static func < (lhs: OctreeCellCode, rhs: OctreeCellCode) -> Bool {
        if lhs.level == rhs.level {
            return lhs.morton < rhs.morton
        }
        return lhs.level < rhs.level
    }
}

// MARK: - Octree Cell

/// Represents a visible octree cell with metadata for rendering
public struct OctreeCell {
    public let bounds: AABB
    public let level: UInt8
    public let cellCode: OctreeCellCode
    public let pointIndices: [Int]
    public let pointCount: Int

    /// Distance from cell center to camera position
    public func distance(to cameraPosition: simd_float3) -> Float {
        simd_distance(bounds.center, cameraPosition)
    }
}

// MARK: - Octree Node

private class OctreeNode {
    var bounds: AABB
    var points: [Int] // Indices into point cloud
    var children: [OctreeNode]?
    var cellCode: OctreeCellCode // Cell identifier for this node

    init(bounds: AABB, cellCode: OctreeCellCode) {
        self.bounds = bounds
        self.points = []
        self.children = nil
        self.cellCode = cellCode
    }

    var isLeaf: Bool {
        children == nil
    }
}

// MARK: - Octree

public class Octree {
    private var root: OctreeNode
    private let maxPointsPerNode: Int
    private let maxDepth: Int
    private let pointCloud: PointCloud

    // For accessing point positions efficiently
    private let positions: UnsafeBufferPointer<simd_float3>?

    public init(
        pointCloud: PointCloud,
        maxPointsPerNode: Int = 100,
        maxDepth: Int = 8,
        useMortonOrder: Bool = true
    ) {
        self.pointCloud = pointCloud
        self.maxPointsPerNode = maxPointsPerNode
        self.maxDepth = maxDepth

        let rootBounds = AABB(
            min: pointCloud.bounds.min,
            max: pointCloud.bounds.max
        )
        let rootCellCode = OctreeCellCode(morton: MortonCode(code: 0), level: 0)
        self.root = OctreeNode(bounds: rootBounds, cellCode: rootCellCode)

        // Initialize positions before using self
        self.positions = Self.extractPositions(from: pointCloud)

        // Build the tree
        var indices = Array(0..<pointCloud.pointCount)

        // Optionally sort by Morton code for better cache locality
        if useMortonOrder, let positions = self.positions {
            indices = MortonSorter.sortIndices(
                indices,
                positions: positions,
                bounds: root.bounds
            )
        }

        build(node: root, indices: indices, depth: 0)
    }
    
    deinit {
        positions?.deallocate()
    }
    
    private static func extractPositions(from pointCloud: PointCloud) -> UnsafeBufferPointer<simd_float3>? {
        // Find X, Y, Z dimensions
        guard let xDim = pointCloud.dimensions.first(where: { String($0.name) == "X" }),
              let yDim = pointCloud.dimensions.first(where: { String($0.name) == "Y" }),
              let zDim = pointCloud.dimensions.first(where: { String($0.name) == "Z" }) else {
            return nil
        }
        
        let count = pointCloud.pointCount
        let positions = UnsafeMutableBufferPointer<simd_float3>.allocate(capacity: count)
        
        let data = pointCloud.data.assumingMemoryBound(to: UInt8.self)
        
        for i in 0..<count {
            let offset = i * pointCloud.stride
            
            let x = data.advanced(by: offset + Int(xDim.offset))
                .withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
            let y = data.advanced(by: offset + Int(yDim.offset))
                .withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
            let z = data.advanced(by: offset + Int(zDim.offset))
                .withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
            
            positions[i] = simd_float3(x, y, z)
        }
        
        return UnsafeBufferPointer(positions)
    }
    
    private func build(node: OctreeNode, indices: [Int], depth: Int) {
        // Stop conditions
        if indices.count <= maxPointsPerNode || depth >= maxDepth {
            node.points = indices
            return
        }
        
        // Create 8 children
        let center = node.bounds.center
        let halfSize = node.bounds.size * 0.5
        
        var childBounds: [AABB] = []
        for z in 0..<2 {
            for y in 0..<2 {
                for x in 0..<2 {
                    let offset = simd_float3(
                        Float(x) - 0.5,
                        Float(y) - 0.5,
                        Float(z) - 0.5
                    )
                    let childCenter = center + halfSize * offset
                    let childMin = childCenter - halfSize * 0.5
                    let childMax = childCenter + halfSize * 0.5
                    childBounds.append(AABB(min: childMin, max: childMax))
                }
            }
        }
        
        // Distribute points to children
        var childIndices: [[Int]] = Array(repeating: [], count: 8)
        
        for index in indices {
            guard let positions = positions else { continue }
            let point = positions[index]
            
            let childIndex = 
                (point.x >= center.x ? 1 : 0) +
                (point.y >= center.y ? 2 : 0) +
                (point.z >= center.z ? 4 : 0)
            
            childIndices[childIndex].append(index)
        }
        
        // Create non-empty children
        node.children = []
        for (i, bounds) in childBounds.enumerated() {
            if !childIndices[i].isEmpty {
                // Calculate proper Morton code for child based on its center position
                let childMorton = MortonCode(point: bounds.center, bounds: root.bounds)
                let childCellCode = OctreeCellCode(morton: childMorton, level: UInt8(depth + 1))

                let child = OctreeNode(bounds: bounds, cellCode: childCellCode)
                node.children?.append(child)
                build(node: child, indices: childIndices[i], depth: depth + 1)
            }
        }
    }
    
    /// Query points visible in frustum
    public func queryFrustum(_ frustum: Frustum) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(1000)
        queryFrustumRecursive(node: root, frustum: frustum, result: &result)
        return result
    }

    /// Query cells visible in frustum with level and distance information for LOD rendering
    public func queryCells(
        frustum: Frustum,
        cameraPosition: simd_float3,
        minLevel: UInt8? = nil,
        maxLevel: UInt8? = nil
    ) -> [OctreeCell] {
        var result: [OctreeCell] = []
        queryCellsRecursive(
            node: root,
            frustum: frustum,
            cameraPosition: cameraPosition,
            minLevel: minLevel,
            maxLevel: maxLevel,
            result: &result
        )
        return result
    }

    /// Query cells with custom filtering using a closure
    /// - Parameters:
    ///   - minLevel: Minimum level to query (optional)
    ///   - maxLevel: Maximum level to query (optional)
    ///   - shouldInclude: Closure that determines whether to include a cell
    /// - Returns: Array of cells that pass the filter
    public func queryCells(
        minLevel: UInt8? = nil,
        maxLevel: UInt8? = nil,
        shouldInclude: (OctreeCell) -> Bool
    ) -> [OctreeCell] {
        var result: [OctreeCell] = []
        queryCellsWithClosure(
            node: root,
            minLevel: minLevel,
            maxLevel: maxLevel,
            shouldInclude: shouldInclude,
            result: &result
        )
        return result
    }

    private func queryCellsWithClosure(
        node: OctreeNode,
        minLevel: UInt8?,
        maxLevel: UInt8?,
        shouldInclude: (OctreeCell) -> Bool,
        result: inout [OctreeCell]
    ) {
        let currentLevel = node.cellCode.level

        // Check level constraints
        if let min = minLevel, currentLevel < min {
            // Keep traversing deeper
            if let children = node.children {
                for child in children {
                    queryCellsWithClosure(
                        node: child,
                        minLevel: minLevel,
                        maxLevel: maxLevel,
                        shouldInclude: shouldInclude,
                        result: &result
                    )
                }
            }
            return
        }

        if let max = maxLevel, currentLevel > max {
            // Stop traversing
            return
        }

        // Check if we should return cells at this level
        let shouldReturnCell = (minLevel == nil || currentLevel >= minLevel!) &&
                               (maxLevel == nil || currentLevel <= maxLevel!)

        // If leaf and within level range, test with closure
        if node.isLeaf && shouldReturnCell {
            let cell = OctreeCell(
                bounds: node.bounds,
                level: currentLevel,
                cellCode: node.cellCode,
                pointIndices: node.points,
                pointCount: node.points.count
            )
            if shouldInclude(cell) {
                result.append(cell)
            }
            return
        }

        // If we've reached max level, test with closure
        if let max = maxLevel, currentLevel == max {
            let cell = OctreeCell(
                bounds: node.bounds,
                level: currentLevel,
                cellCode: node.cellCode,
                pointIndices: node.points,
                pointCount: node.points.count
            )
            if shouldInclude(cell) {
                result.append(cell)
            }
            return
        }

        // Continue traversing to children
        if let children = node.children {
            for child in children {
                queryCellsWithClosure(
                    node: child,
                    minLevel: minLevel,
                    maxLevel: maxLevel,
                    shouldInclude: shouldInclude,
                    result: &result
                )
            }
        }
    }

    private func queryCellsRecursive(
        node: OctreeNode,
        frustum: Frustum,
        cameraPosition: simd_float3,
        minLevel: UInt8?,
        maxLevel: UInt8?,
        result: inout [OctreeCell]
    ) {
        // Test if node bounds intersect frustum
        guard frustum.intersects(node.bounds) else {
            return
        }

        let currentLevel = node.cellCode.level

        // Check level constraints
        if let min = minLevel, currentLevel < min {
            // Keep traversing deeper
            if let children = node.children {
                for child in children {
                    queryCellsRecursive(
                        node: child,
                        frustum: frustum,
                        cameraPosition: cameraPosition,
                        minLevel: minLevel,
                        maxLevel: maxLevel,
                        result: &result
                    )
                }
            }
            return
        }

        if let max = maxLevel, currentLevel > max {
            // Stop traversing
            return
        }

        // Check if we should return cells at this level
        let shouldReturnCell = (minLevel == nil || currentLevel >= minLevel!) &&
                               (maxLevel == nil || currentLevel <= maxLevel!)

        // If leaf and within level range, add this cell
        if node.isLeaf && shouldReturnCell {
            let cell = OctreeCell(
                bounds: node.bounds,
                level: currentLevel,
                cellCode: node.cellCode,
                pointIndices: node.points,
                pointCount: node.points.count
            )
            result.append(cell)
            return
        }

        // If we've reached max level, return this node even if not a leaf
        if let max = maxLevel, currentLevel == max {
            let cell = OctreeCell(
                bounds: node.bounds,
                level: currentLevel,
                cellCode: node.cellCode,
                pointIndices: node.points,
                pointCount: node.points.count
            )
            result.append(cell)
            return
        }

        // Continue traversing to children
        if let children = node.children {
            for child in children {
                queryCellsRecursive(
                    node: child,
                    frustum: frustum,
                    cameraPosition: cameraPosition,
                    minLevel: minLevel,
                    maxLevel: maxLevel,
                    result: &result
                )
            }
        }
    }

    /// Get all cells at a specific level
    /// - Parameter level: The octree level to query
    /// - Returns: Array of all cells at the specified level
    public func getAllCells(atLevel level: UInt8) -> [OctreeCell] {
        var result: [OctreeCell] = []
        executeFunctionRecursive(node: root, targetLevel: level) { cell in
            result.append(cell)
        }
        return result
    }

    /// Get all leaf cells in the octree
    /// - Returns: Array of all leaf cells (cells with no children)
    public func getAllLeafCells() -> [OctreeCell] {
        var result: [OctreeCell] = []
        collectAllLeafCells(node: root, result: &result)
        return result
    }

    private func collectAllLeafCells(node: OctreeNode, result: inout [OctreeCell]) {
        if node.isLeaf {
            let cell = OctreeCell(
                bounds: node.bounds,
                level: node.cellCode.level,
                cellCode: node.cellCode,
                pointIndices: node.points,
                pointCount: node.points.count
            )
            result.append(cell)
            return
        }

        if let children = node.children {
            for child in children {
                collectAllLeafCells(node: child, result: &result)
            }
        }
    }

    /// Get all cells in the octree
    /// - Parameters:
    ///   - minLevel: Minimum level (optional, defaults to 0)
    ///   - maxLevel: Maximum level (optional, defaults to tree depth)
    /// - Returns: Array of all cells within the level range
    public func getAllCells(minLevel: UInt8 = 0, maxLevel: UInt8? = nil) -> [OctreeCell] {
        var result: [OctreeCell] = []
        collectAllCells(node: root, minLevel: minLevel, maxLevel: maxLevel, result: &result)
        return result
    }

    private func collectAllCells(
        node: OctreeNode,
        minLevel: UInt8,
        maxLevel: UInt8?,
        result: inout [OctreeCell]
    ) {
        let currentLevel = node.cellCode.level

        // Check if we're past max level
        if let max = maxLevel, currentLevel > max {
            return
        }

        // Add this cell if within level range
        if currentLevel >= minLevel {
            let cell = OctreeCell(
                bounds: node.bounds,
                level: currentLevel,
                cellCode: node.cellCode,
                pointIndices: node.points,
                pointCount: node.points.count
            )
            result.append(cell)
        }

        // Continue to children if not at max level
        if let children = node.children {
            for child in children {
                collectAllCells(node: child, minLevel: minLevel, maxLevel: maxLevel, result: &result)
            }
        }
    }

    /// Execute a function for all cells at a specific level
    public func executeFunctionForAllCellsAtLevel(
        _ level: UInt8,
        function: (OctreeCell) -> Void
    ) {
        executeFunctionRecursive(node: root, targetLevel: level, function: function)
    }

    private func executeFunctionRecursive(
        node: OctreeNode,
        targetLevel: UInt8,
        function: (OctreeCell) -> Void
    ) {
        let currentLevel = node.cellCode.level

        if currentLevel == targetLevel {
            let cell = OctreeCell(
                bounds: node.bounds,
                level: currentLevel,
                cellCode: node.cellCode,
                pointIndices: node.points,
                pointCount: node.points.count
            )
            function(cell)
            return
        }

        // Keep traversing if not at target level yet
        if currentLevel < targetLevel, let children = node.children {
            for child in children {
                executeFunctionRecursive(node: child, targetLevel: targetLevel, function: function)
            }
        }
    }

    private func queryFrustumRecursive(
        node: OctreeNode,
        frustum: Frustum,
        result: inout [Int]
    ) {
        // Test if node bounds intersect frustum
        guard frustum.intersects(node.bounds) else {
            return
        }

        // If leaf, add all points
        if node.isLeaf {
            result.append(contentsOf: node.points)
            return
        }

        // Recurse to children
        if let children = node.children {
            for child in children {
                queryFrustumRecursive(node: child, frustum: frustum, result: &result)
            }
        }
    }
    
    /// Get statistics about the tree
    public struct Statistics {
        public let nodeCount: Int
        public let leafCount: Int
        public let maxDepth: Int
        public let averagePointsPerLeaf: Double
    }
    
    public func getStatistics() -> Statistics {
        var nodeCount = 0
        var leafCount = 0
        var maxDepth = 0
        var totalPoints = 0
        
        func traverse(node: OctreeNode, depth: Int) {
            nodeCount += 1
            maxDepth = max(maxDepth, depth)
            
            if node.isLeaf {
                leafCount += 1
                totalPoints += node.points.count
            }
            
            if let children = node.children {
                for child in children {
                    traverse(node: child, depth: depth + 1)
                }
            }
        }
        
        traverse(node: root, depth: 0)
        
        let avgPoints = leafCount > 0 ? Double(totalPoints) / Double(leafCount) : 0
        
        return Statistics(
            nodeCount: nodeCount,
            leafCount: leafCount,
            maxDepth: maxDepth,
            averagePointsPerLeaf: avgPoints
        )
    }
}
