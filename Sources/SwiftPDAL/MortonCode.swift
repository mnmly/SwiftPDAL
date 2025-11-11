import simd

/// Morton Code (Z-order curve) implementation for 3D spatial indexing.
///
/// Morton codes interleave the bits of X, Y, Z coordinates to create a 1D ordering
/// that preserves spatial locality - points close in 3D space tend to have nearby Morton codes.
/// This is useful for:
/// - Faster octree construction via sorting
/// - Better cache locality when traversing spatial data
/// - Efficient range queries and nearest neighbor searches
public struct MortonCode: Comparable, Hashable {
    public let code: UInt64

    public init(code: UInt64) {
        self.code = code
    }

    /// Create Morton code from 3D coordinates within normalized [0, 1] space
    public init(x: Float, y: Float, z: Float) {
        // Convert normalized coordinates to 21-bit integers (63 bits total for interleaving)
        let maxValue: UInt32 = (1 << 21) - 1
        let xi = min(UInt32(x * Float(maxValue)), maxValue)
        let yi = min(UInt32(y * Float(maxValue)), maxValue)
        let zi = min(UInt32(z * Float(maxValue)), maxValue)

        self.code = Self.encode(x: xi, y: yi, z: zi)
    }

    /// Create Morton code from 3D point within given bounds
    public init(point: simd_float3, bounds: AABB) {
        let size = bounds.size
        let normalized = simd_float3(
            (point.x - bounds.min.x) / size.x,
            (point.y - bounds.min.y) / size.y,
            (point.z - bounds.min.z) / size.z
        )

        self.init(x: normalized.x, y: normalized.y, z: normalized.z)
    }

    /// Encode 3D coordinates into Morton code by interleaving bits
    private static func encode(x: UInt32, y: UInt32, z: UInt32) -> UInt64 {
        let xx = expandBits(x)
        let yy = expandBits(y)
        let zz = expandBits(z)

        return xx | (yy << 1) | (zz << 2)
    }

    /// Decode Morton code back to 3D coordinates
    public func decode() -> (x: UInt32, y: UInt32, z: UInt32) {
        let x = Self.compactBits(code)
        let y = Self.compactBits(code >> 1)
        let z = Self.compactBits(code >> 2)

        return (x, y, z)
    }

    /// Decode Morton code to normalized float coordinates
    public func decodeNormalized() -> simd_float3 {
        let (x, y, z) = decode()
        let maxValue = Float((1 << 21) - 1)

        return simd_float3(
            Float(x) / maxValue,
            Float(y) / maxValue,
            Float(z) / maxValue
        )
    }

    /// Expand bits by inserting two zeros after each bit (Magic Numbers approach)
    /// Input:  xxxx xxxx xxxx xxxx xxxx x
    /// Output: x00x 00x0 0x00 x00x 00x0 0x00 x00x 00x0 0x00 x00x 00x0 0x00 x
    private static func expandBits(_ value: UInt32) -> UInt64 {
        var x = UInt64(value) & 0x1fffff // 21 bits

        x = (x | (x << 32)) & 0x1f00000000ffff
        x = (x | (x << 16)) & 0x1f0000ff0000ff
        x = (x | (x << 8))  & 0x100f00f00f00f00f
        x = (x | (x << 4))  & 0x10c30c30c30c30c3
        x = (x | (x << 2))  & 0x1249249249249249

        return x
    }

    /// Compact bits by extracting every third bit
    private static func compactBits(_ value: UInt64) -> UInt32 {
        var x = value & 0x1249249249249249

        x = (x ^ (x >> 2))  & 0x10c30c30c30c30c3
        x = (x ^ (x >> 4))  & 0x100f00f00f00f00f
        x = (x ^ (x >> 8))  & 0x1f0000ff0000ff
        x = (x ^ (x >> 16)) & 0x1f00000000ffff
        x = (x ^ (x >> 32)) & 0x1fffff

        return UInt32(x)
    }

    // MARK: - Comparable

    public static func < (lhs: MortonCode, rhs: MortonCode) -> Bool {
        lhs.code < rhs.code
    }

    public static func == (lhs: MortonCode, rhs: MortonCode) -> Bool {
        lhs.code == rhs.code
    }
}

// MARK: - Extensions

extension MortonCode: CustomStringConvertible {
    public var description: String {
        "MortonCode(0x\(String(code, radix: 16)))"
    }
}

/// Utility for sorting point indices by Morton code
public struct MortonSorter {

    /// Sort point indices by their Morton code
    public static func sortIndices(
        _ indices: [Int],
        positions: UnsafeBufferPointer<simd_float3>,
        bounds: AABB
    ) -> [Int] {

        // Compute Morton codes for all points
        let mortonCodes = indices.map { index -> (index: Int, code: MortonCode) in
            let point = positions[index]
            let code = MortonCode(point: point, bounds: bounds)
            return (index, code)
        }

        // Sort by Morton code
        let sorted = mortonCodes.sorted { $0.code < $1.code }

        // Extract indices
        return sorted.map { $0.index }
    }

    /// Sort points in place by their Morton code (modifies the positions array)
    public static func sortPoints(
        _ points: inout [simd_float3],
        bounds: AABB
    ) {
        // Compute Morton codes
        let mortonCodes = points.enumerated().map { index, point -> (index: Int, code: MortonCode) in
            let code = MortonCode(point: point, bounds: bounds)
            return (index, code)
        }

        // Sort by Morton code
        let sorted = mortonCodes.sorted { $0.code < $1.code }

        // Reorder points
        points = sorted.map { points[$0.index] }
    }
}
