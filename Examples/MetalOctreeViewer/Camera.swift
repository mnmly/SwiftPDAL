import simd
import SwiftPDAL

class Camera {
    var position: simd_float3
    var target: simd_float3
    var up: simd_float3

    var fov: Float = .pi / 3 // 60 degrees
    var aspectRatio: Float = 16.0 / 9.0
    var nearPlane: Float = 0.1
    var farPlane: Float = 10000.0

    // For rotation
    var distance: Float
    var azimuth: Float = 0  // Rotation around Y axis
    var elevation: Float = .pi / 6  // Rotation around X axis

    init() {
        self.distance = 500.0
        self.position = simd_float3(0, 0, distance)
        self.target = simd_float3(0, 0, 0)
        self.up = simd_float3(0, 1, 0)
        updatePosition()
    }

    func centerOn(bounds: PointCloud.Bounds) {
        // Calculate center
        target = (bounds.min + bounds.max) * 0.5

        // Calculate appropriate distance
        let size = bounds.max - bounds.min
        let maxDimension = max(size.x, max(size.y, size.z))
        distance = maxDimension * 2.5

        // Reset rotation
        azimuth = .pi / 4
        elevation = .pi / 6

        updatePosition()
    }

    func rotate(deltaAzimuth: Float, deltaElevation: Float) {
        azimuth += deltaAzimuth
        elevation += deltaElevation

        // Clamp elevation to avoid gimbal lock
        elevation = max(-Float.pi / 2 + 0.01, min(Float.pi / 2 - 0.01, elevation))

        updatePosition()
    }

    func zoom(delta: Float) {
        distance *= (1.0 - delta)
        distance = max(1.0, min(50000.0, distance))
        updatePosition()
    }

    func pan(deltaX: Float, deltaY: Float) {
        let right = simd_normalize(simd_cross(simd_normalize(position - target), up))
        let actualUp = simd_normalize(simd_cross(right, simd_normalize(position - target)))

        target += right * deltaX + actualUp * deltaY
        updatePosition()
    }

    private func updatePosition() {
        // Calculate position from spherical coordinates
        let x = distance * cos(elevation) * cos(azimuth)
        let y = distance * sin(elevation)
        let z = distance * cos(elevation) * sin(azimuth)

        position = target + simd_float3(x, y, z)
    }

    var viewMatrix: simd_float4x4 {
        lookAt(eye: position, center: target, up: up)
    }

    var projectionMatrix: simd_float4x4 {
        perspective(fov: fov, aspect: aspectRatio, near: nearPlane, far: farPlane)
    }

    var viewProjectionMatrix: simd_float4x4 {
        projectionMatrix * viewMatrix
    }

    // Matrix helper functions
    private func lookAt(eye: simd_float3, center: simd_float3, up: simd_float3) -> simd_float4x4 {
        let z = simd_normalize(eye - center)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)

        return simd_float4x4(
            simd_float4(x.x, y.x, z.x, 0),
            simd_float4(x.y, y.y, z.y, 0),
            simd_float4(x.z, y.z, z.z, 0),
            simd_float4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        )
    }

    private func perspective(fov: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let yScale = 1 / tan(fov * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        let zScale = -(far + near) / zRange
        let wzScale = -2 * far * near / zRange

        return simd_float4x4(
            simd_float4(xScale, 0, 0, 0),
            simd_float4(0, yScale, 0, 0),
            simd_float4(0, 0, zScale, -1),
            simd_float4(0, 0, wzScale, 0)
        )
    }
}
