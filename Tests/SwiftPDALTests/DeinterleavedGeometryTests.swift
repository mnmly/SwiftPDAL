import Testing
import Foundation
import CxxPDAL
import simd
@testable import SwiftPDAL

#if canImport(Metal)
import Metal
#endif

// MARK: - Synthetic fixture builder

/// A minimal element-type vocabulary for hand-built fixtures. Maps to the PDAL
/// dimension type + width used to lay out an interleaved point.
private enum FX {
    case f32, i32, u16, u8

    var pdalType: pdal.Dimension.`Type` {
        switch self {
        case .f32: return .Float
        case .i32: return .Signed32
        case .u16: return .Unsigned16
        case .u8:  return .Unsigned8
        }
    }
    var size: Int { switch self { case .f32, .i32: return 4; case .u16: return 2; case .u8: return 1 } }
}

private struct FixtureDim {
    let name: String
    let type: FX
    /// Produces the (float-valued) sample for point `i`; stored in its native width.
    let value: (Int) -> Double
}

/// Builds a synthetic `PointCloud` with a `malloc`'d interleaved buffer (freed by
/// `deinit` via `free`), laid out exactly like the C reader: each field aligned
/// to its width, stride aligned to the max field alignment.
private func makeFixture(count: Int, dims specs: [FixtureDim]) -> (PointCloud, mid: SIMD3<Float>) {
    func alignUp(_ v: Int, _ a: Int) -> Int { (v + a - 1) / a * a }

    var offsets: [Int] = []
    var cur = 0
    var maxAlign = 1
    for s in specs {
        cur = alignUp(cur, s.type.size)
        offsets.append(cur)
        cur += s.type.size
        maxAlign = max(maxAlign, s.type.size)
    }
    let stride = alignUp(cur, maxAlign)

    let raw = malloc(count * stride)!
    memset(raw, 0, count * stride)
    let base = UnsafeMutableRawPointer(raw)

    for (di, s) in specs.enumerated() {
        let off = offsets[di]
        for i in 0..<count {
            let p = base + i * stride + off
            let v = s.value(i)
            switch s.type {
            case .f32: p.storeBytes(of: Float(v), as: Float.self)
            case .i32: p.storeBytes(of: Int32(v), as: Int32.self)
            case .u16: p.storeBytes(of: UInt16(v), as: UInt16.self)
            case .u8:  p.storeBytes(of: UInt8(v), as: UInt8.self)
            }
        }
    }

    let dimInfos = specs.enumerated().map { (di, s) in
        DimensionInfo(name: s.name, sourceType: s.type.pdalType, outputType: s.type.pdalType,
                      outputSize: s.type.size, offset: offsets[di])
    }

    // Bounds from the X/Y/Z producers (indices 0,1,2 by construction).
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    for i in 0..<count {
        let p = SIMD3<Float>(Float(specs[0].value(i)), Float(specs[1].value(i)), Float(specs[2].value(i)))
        lo = simd_min(lo, p); hi = simd_max(hi, p)
    }
    let bounds = Bounds(min: lo, max: hi)
    let pc = PointCloud(filePath: "synthetic", pointCount: count, bounds: bounds,
                        data: UnsafeRawPointer(base), size: count * stride, stride: stride,
                        dimensions: dimInfos)
    return (pc, (lo + hi) * 0.5)
}

private func xyzSpecs(count: Int) -> [FixtureDim] {
    [
        FixtureDim(name: "X", type: .f32) { Double($0) * 1.5 },
        FixtureDim(name: "Y", type: .f32) { Double($0) * 2.0 - 3.0 },
        FixtureDim(name: "Z", type: .f32) { Double($0) * -0.5 + 1.0 },
        FixtureDim(name: "semantic", type: .i32) { Double($0 % 4) },
    ]
}

// MARK: - Reference (independent of the implementation under test)

private struct Reference {
    var scalars: [String: [Float]]
    var position: [SIMD3<Float>]
    var color: [SIMD4<Float>]
}

private func reference(count: Int, specs: [FixtureDim], mid: SIMD3<Float>) -> Reference {
    var scalars: [String: [Float]] = [:]
    for s in specs { scalars[s.name] = (0..<count).map { Float(s.value($0)) } }
    let xs = scalars["X"]!, ys = scalars["Y"]!, zs = scalars["Z"]!
    let position = (0..<count).map { SIMD3<Float>(xs[$0] - mid.x, ys[$0] - mid.y, zs[$0] - mid.z) }

    let color: [SIMD4<Float>]
    if let r = scalars["Red"], let g = scalars["Green"], let b = scalars["Blue"] {
        let maxV = ([r, g, b].flatMap { $0 }).max() ?? 0
        let scale: Float = maxV > 255 ? 1.0 / 65535.0 : (maxV > 1 ? 1.0 / 255.0 : 1.0)
        color = (0..<count).map { SIMD4<Float>(r[$0] * scale, g[$0] * scale, b[$0] * scale, 1) }
    } else {
        color = Array(repeating: SIMD4<Float>(1, 1, 1, 1), count: count)
    }
    return Reference(scalars: scalars, position: position, color: color)
}

// MARK: - Assertions against the CPU (Data) result

private func assertMatches(_ raw: DeinterleavedRawGeometry, _ ref: Reference, count: Int) {
    #expect(raw.pointCount == count)
    for (name, expected) in ref.scalars {
        let got = raw.scalars[name]!.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        #expect(got == expected, "scalar \(name) mismatch")
    }
    let pos = raw.position.withUnsafeBytes { Array($0.bindMemory(to: SIMD3<Float>.self).prefix(count)) }
    #expect(pos == ref.position, "position mismatch")
    let col = raw.color.withUnsafeBytes { Array($0.bindMemory(to: SIMD4<Float>.self).prefix(count)) }
    #expect(col == ref.color, "color mismatch")
}

#if canImport(Metal)
private func extractScalars(_ g: DeinterleavedGeometry, count: Int) -> [String: [Float]] {
    var out: [String: [Float]] = [:]
    for (name, buf) in g.scalars {
        out[name] = buf.contents().withMemoryRebound(to: Float.self, capacity: count) {
            Array(UnsafeBufferPointer(start: $0, count: count))
        }
    }
    return out
}
private func extractPositions(_ g: DeinterleavedGeometry, count: Int) -> [SIMD3<Float>] {
    g.position.contents().withMemoryRebound(to: SIMD3<Float>.self, capacity: count) {
        Array(UnsafeBufferPointer(start: $0, count: count))
    }
}
private func extractColors(_ g: DeinterleavedGeometry, count: Int) -> [SIMD4<Float>] {
    g.color.contents().withMemoryRebound(to: SIMD4<Float>.self, capacity: count) {
        Array(UnsafeBufferPointer(start: $0, count: count))
    }
}
#endif

// MARK: - Tests

@Test func deinterleaveCPU_noRGB_isWhite() {
    let count = 5
    let specs = xyzSpecs(count: count)
    let (pc, mid) = makeFixture(count: count, dims: specs)
    let ref = reference(count: count, specs: specs, mid: mid)
    let raw = pc.deinterleavedGeometryCPU()!
    assertMatches(raw, ref, count: count)
    // No RGB → opaque white.
    #expect(raw.color.withUnsafeBytes { $0.bindMemory(to: SIMD4<Float>.self)[0] } == SIMD4<Float>(1, 1, 1, 1))
    #expect(raw.originShift == mid)
    #expect(raw.centeredBounds.min == pc.bounds.min - mid)
}

@Test func deinterleaveCPU_8bitRGB() {
    let count = 6
    var specs = xyzSpecs(count: count)
    specs += [
        FixtureDim(name: "Red", type: .u8) { Double(($0 * 40) % 256) },
        FixtureDim(name: "Green", type: .u8) { Double(($0 * 17) % 200) },
        FixtureDim(name: "Blue", type: .u8) { Double($0 * 10) },     // max < 256 → 1/255
    ]
    let (pc, mid) = makeFixture(count: count, dims: specs)
    let ref = reference(count: count, specs: specs, mid: mid)
    assertMatches(pc.deinterleavedGeometryCPU()!, ref, count: count)
}

@Test func deinterleaveCPU_16bitRGB() {
    let count = 7
    var specs = xyzSpecs(count: count)
    specs += [
        FixtureDim(name: "Red", type: .u16) { Double($0 * 5000) },   // exceeds 255 → 1/65535
        FixtureDim(name: "Green", type: .u16) { Double($0 * 3000) },
        FixtureDim(name: "Blue", type: .u16) { Double($0 * 1000) },
    ]
    let (pc, mid) = makeFixture(count: count, dims: specs)
    let ref = reference(count: count, specs: specs, mid: mid)
    assertMatches(pc.deinterleavedGeometryCPU()!, ref, count: count)
}

#if canImport(Metal)
@Test func deinterleaveGPU_matchesCPU_allFixtures() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }  // CI without a GPU

    func check(_ specs: [FixtureDim], count: Int) {
        let (pc, mid) = makeFixture(count: count, dims: specs)
        let ref = reference(count: count, specs: specs, mid: mid)
        guard let gpu = pc.deinterleavedGeometry(device: device, backend: .gpu) else {
            Issue.record("GPU backend returned nil"); return
        }
        let gpuScalars = extractScalars(gpu, count: count)
        for (name, expected) in ref.scalars { #expect(gpuScalars[name]! == expected, "GPU scalar \(name)") }
        #expect(extractPositions(gpu, count: count) == ref.position, "GPU position")
        #expect(extractColors(gpu, count: count) == ref.color, "GPU color")
        #expect(gpu.originShift == mid)
    }

    // no-RGB
    check(xyzSpecs(count: 5), count: 5)
    // 8-bit RGB
    var s8 = xyzSpecs(count: 6)
    s8 += [FixtureDim(name: "Red", type: .u8) { Double(($0 * 40) % 256) },
           FixtureDim(name: "Green", type: .u8) { Double(($0 * 17) % 200) },
           FixtureDim(name: "Blue", type: .u8) { Double($0 * 10) }]
    check(s8, count: 6)
    // 16-bit RGB
    var s16 = xyzSpecs(count: 7)
    s16 += [FixtureDim(name: "Red", type: .u16) { Double($0 * 5000) },
            FixtureDim(name: "Green", type: .u16) { Double($0 * 3000) },
            FixtureDim(name: "Blue", type: .u16) { Double($0 * 1000) }]
    check(s16, count: 7)
}

@Test func deinterleaveGPU_cpuBackend_matchesReference() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let count = 6
    var specs = xyzSpecs(count: count)
    specs += [FixtureDim(name: "Red", type: .u16) { Double($0 * 5000) },
              FixtureDim(name: "Green", type: .u16) { Double($0 * 3000) },
              FixtureDim(name: "Blue", type: .u16) { Double($0 * 1000) }]
    let (pc, mid) = makeFixture(count: count, dims: specs)
    let ref = reference(count: count, specs: specs, mid: mid)
    // Force the CPU-into-MTLBuffer path.
    let g = pc.deinterleavedGeometry(device: device, backend: .cpu)!
    for (name, expected) in ref.scalars { #expect(extractScalars(g, count: count)[name]! == expected) }
    #expect(extractPositions(g, count: count) == ref.position)
    #expect(extractColors(g, count: count) == ref.color)
}
#endif

// MARK: - Opt-in benchmark on the large file

/// Set `SWIFTPDAL_BENCH_PLY=/path/to/file.ply` to run. Reports read time vs the
/// CPU and GPU de-interleave/compose times so the `.auto` threshold can be tuned.
@Test func deinterleaveBenchmark() throws {
    guard let path = ProcessInfo.processInfo.environment["SWIFTPDAL_BENCH_PLY"] else { return }
    setenv("SWIFTPDAL_TESTING", "1", 1)

    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    let t0 = now()
    let pc = try PointCloud.read(from: path, readerName: "readers.ply")
    let readSec = now() - t0
    print("[bench] read \(pc.pointCount) pts (\(pc.dimensions.count) dims, stride \(pc.stride)) in \(String(format: "%.3f", readSec))s")

    let c0 = now()
    let cpu = pc.deinterleavedGeometryCPU()!
    let cpuSec = now() - c0
    print("[bench] CPU de-interleave: \(String(format: "%.3f", cpuSec))s  (scalars=\(cpu.scalars.count))")

    #if canImport(Metal)
    if let device = MTLCreateSystemDefaultDevice() {
        // Warm the pipeline cache + driver.
        _ = pc.deinterleavedGeometry(device: device, backend: .gpu)
        let g0 = now()
        let gpu = pc.deinterleavedGeometry(device: device, backend: .gpu)!
        let gpuSec = now() - g0
        print("[bench] GPU de-interleave: \(String(format: "%.3f", gpuSec))s  (scalars=\(gpu.scalars.count))")
        print("[bench] winner: \(gpuSec < cpuSec ? "GPU" : "CPU")  (CPU/GPU = \(String(format: "%.2f", cpuSec / gpuSec))x)")

        // Spot-check parity on the real data (first/last point of each scalar).
        for (name, cdata) in cpu.scalars {
            let cArr = cdata.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(pc.pointCount)) }
            let gArr = gpu.scalars[name]!.contents().withMemoryRebound(to: Float.self, capacity: pc.pointCount) {
                Array(UnsafeBufferPointer(start: $0, count: pc.pointCount))
            }
            #expect(cArr.first == gArr.first && cArr.last == gArr.last, "bench parity \(name)")
        }
    }
    #endif
}
