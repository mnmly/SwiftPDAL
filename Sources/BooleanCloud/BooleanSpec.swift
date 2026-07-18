// Boolean spec model + point-in-mesh containment.
//
// The spec is produced by the bl_copc_renderer Blender addon
// (boolean.build_spec). Every cutter mesh is already expressed in the
// source file's CRS coordinate frame, so a point read straight from the
// original COPC (world-space doubles) can be tested against the mesh
// with no transform: a source point is inside a cutter iff its Blender
// world position was inside that cutter — the export bakes exactly that
// equivalence into `verts`.

import Foundation

// MARK: - JSON model

struct BooleanSpec: Decodable {
    let version: Int
    let clouds: [CloudSpec]
}

struct CloudSpec: Decodable {
    let name: String
    let source: String
    let origin: [Double]
    let meshes: [MeshSpec]
}

struct MeshSpec: Decodable {
    let name: String
    let op: String            // "subtract" | "intersect"
    let verts: [[Double]]     // CRS coordinates
    let faces: [[Int]]        // triangles (export triangulates)
}

// MARK: - Prepared cutter

enum BoolOp { case subtract, intersect }

/// A cutter mesh prepared for fast containment tests: triangles as flat
/// vertex triples plus a world AABB for cheap rejection.
struct Cutter {
    let op: BoolOp
    let tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]
    let lo: SIMD3<Double>
    let hi: SIMD3<Double>

    init?(_ mesh: MeshSpec) {
        guard !mesh.verts.isEmpty, !mesh.faces.isEmpty else { return nil }
        let vs = mesh.verts.map { SIMD3<Double>($0[0], $0[1], $0[2]) }
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        tris.reserveCapacity(mesh.faces.count)
        for f in mesh.faces where f.count >= 3 {
            // Fan-triangulate defensively in case a face isn't already a triangle.
            for k in 1..<(f.count - 1) {
                tris.append((vs[f[0]], vs[f[k]], vs[f[k + 1]]))
            }
        }
        guard !tris.isEmpty else { return nil }
        var lo = vs[0], hi = vs[0]
        for v in vs {
            lo = pointwiseMin(lo, v)
            hi = pointwiseMax(hi, v)
        }
        self.op = mesh.op == "intersect" ? .intersect : .subtract
        self.tris = tris
        self.lo = lo
        self.hi = hi
    }
}

// MARK: - Containment

@inline(__always)
private func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    a.x * b.x + a.y * b.y + a.z * b.z
}

@inline(__always)
private func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y,
          a.z * b.x - a.x * b.z,
          a.x * b.y - a.y * b.x)
}

/// Möller–Trumbore ray/triangle. Ray origin `o`, direction `d`. Returns the
/// hit parameter t (> eps) or nil. Used for even–odd (parity) inside tests.
@inline(__always)
private func rayHitsTriangle(_ o: SIMD3<Double>, _ d: SIMD3<Double>,
                             _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Bool {
    let eps = 1e-9
    let e1 = b - a
    let e2 = c - a
    let h = cross(d, e2)
    let det = dot(e1, h)
    if det > -eps && det < eps { return false }   // ray parallel to triangle
    let invDet = 1.0 / det
    let s = o - a
    let u = invDet * dot(s, h)
    if u < 0.0 || u > 1.0 { return false }
    let q = cross(s, e1)
    let v = invDet * dot(d, q)
    if v < 0.0 || u + v > 1.0 { return false }
    let t = invDet * dot(e2, q)
    return t > eps
}

/// True if `p` lies inside the closed cutter mesh, via a +X ray parity test.
@inline(__always)
private func inside(_ p: SIMD3<Double>, _ c: Cutter) -> Bool {
    if p.x < c.lo.x || p.y < c.lo.y || p.z < c.lo.z ||
       p.x > c.hi.x || p.y > c.hi.y || p.z > c.hi.z { return false }
    let dir = SIMD3<Double>(1, 0, 0)
    var hits = 0
    for (a, b, cc) in c.tris where rayHitsTriangle(p, dir, a, b, cc) { hits += 1 }
    return (hits & 1) == 1
}

/// Build a keep-mask over `count` interleaved XYZ doubles.
/// Rule: keep = (no intersect cutters OR inside any intersect) AND NOT inside any subtract.
func keepMask(xyz: UnsafePointer<Double>, count: Int, cutters: [Cutter]) -> [UInt8] {
    let hasIntersect = cutters.contains { $0.op == .intersect }
    var mask = [UInt8](repeating: 0, count: count)
    let threads = max(1, ProcessInfo.processInfo.activeProcessorCount)
    let chunk = (count + threads - 1) / threads
    mask.withUnsafeMutableBufferPointer { out in
        // Each iteration writes a disjoint index range and only reads `xyz`,
        // so sharing these raw pointers across threads is safe by construction.
        nonisolated(unsafe) let src = xyz
        nonisolated(unsafe) let dst = out.baseAddress!
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            let start = t * chunk
            let end = min(start + chunk, count)
            var i = start
            while i < end {
                let p = SIMD3<Double>(src[3 * i], src[3 * i + 1], src[3 * i + 2])
                var insideSub = false
                var insideInt = false
                for c in cutters {
                    if inside(p, c) {
                        if c.op == .subtract { insideSub = true }
                        else { insideInt = true }
                    }
                }
                let keep = (hasIntersect ? insideInt : true) && !insideSub
                dst[i] = keep ? 1 : 0
                i += 1
            }
        }
    }
    return mask
}
