// DeinterleavedGeometry.swift — additive Struct-of-Arrays export.
//
// `PointCloud.read` produces an interleaved (Array-of-Structs) buffer: every
// point's dimensions sit contiguously, one point after another. GPU compute
// consumers that operate per-attribute (compare / math / reduction / filter /
// recolor over a single dimension at a time) want the opposite layout — one
// flat, contiguous `Float32` buffer per dimension (Struct-of-Arrays), plus
// ready-made packed `Position` (centered float3) and `Color` (normalized
// float4) buffers.
//
// This file adds that de-interleave + compose step without touching the
// existing read / data / stride / dimensions / makeBuffer surface. It is
// deliberately NON-DESTRUCTIVE: unlike `PointCloud.makeBuffer`, it never takes
// ownership of `PointCloud.data`, so the source buffer stays valid and is still
// freed by `PointCloud.deinit`.
//
// Two backends produce byte-identical output:
//   • a Metal compute path (runtime-compiled kernels) that scatters every
//     dimension on the GPU and composes Position/Color, and
//   • a vectorized CPU path (Accelerate/vDSP strided conversions).
// `DeinterleaveBackend.auto` picks the benchmark-determined winner. On a
// 13.6M-point PLY the GPU path runs the scatter+compose in ~29 ms vs ~91 ms
// for the CPU path (~3.1x), against a ~2.1 s PDAL read it sits behind; see
// `deinterleaveBenchmark` in SwiftPDALTests to reproduce.

import Foundation
import simd

#if canImport(Accelerate)
import Accelerate
#endif

#if canImport(Metal)
import Metal
#endif

// MARK: - Type codes (shared by the CPU and Metal scatter paths)

/// Compact encoding of a dimension's element type, used to drive both the
/// Metal kernel's typed load and the CPU scatter's fast-path selection.
///
/// The values match the `switch` in the embedded Metal kernel. `Double` never
/// appears in a buffer from ``PointCloud/read(from:readerName:outSrs:)`` — PDAL
/// narrows it to `Float` at read time — but it is handled on the CPU path for
/// completeness (and documented as a precision loss).
enum ScalarTypeCode: UInt32 {
    case uint8 = 0, int8 = 1
    case uint16 = 2, int16 = 3
    case uint32 = 4, int32 = 5
    case uint64 = 6, int64 = 7
    case float32 = 8
    case float64 = 9   // CPU-only; not emitted by PDAL reads.

    init(_ dim: DimensionInfo) {
        if dim.isFloatingPoint {
            self = dim.typeByteSize == 8 ? .float64 : .float32
        } else if dim.isSignedInteger {
            switch dim.typeByteSize {
            case 1: self = .int8
            case 2: self = .int16
            case 4: self = .int32
            default: self = .int64
            }
        } else {
            switch dim.typeByteSize {
            case 1: self = .uint8
            case 2: self = .uint16
            case 4: self = .uint32
            default: self = .uint64
            }
        }
    }
}

// MARK: - Result types

/// A loaded point cloud de-interleaved into platform-neutral, contiguous
/// `Float32` byte buffers (Struct-of-Arrays), plus packed `position`/`color`.
///
/// This is the return type of ``PointCloud/deinterleavedGeometryCPU(wideningIntegersToFloat:)``
/// and the universal result on platforms without Metal. On Apple platforms,
/// prefer ``PointCloud/deinterleavedGeometry(device:backend:wideningIntegersToFloat:options:)``,
/// which returns the same data already wrapped in `MTLBuffer`s.
///
/// All buffers are tightly packed:
/// - `scalars[name]`: `pointCount * 4` bytes of `Float32`.
/// - `position`: `pointCount` elements of `SIMD3<Float>` at a 16-byte stride.
/// - `color`: `pointCount` elements of `SIMD4<Float>` at a 16-byte stride.
public struct DeinterleavedRawGeometry: Sendable {
    /// The number of points; the element count of every buffer.
    public var pointCount: Int
    /// One contiguous `Float32` buffer per source dimension, keyed by
    /// ``DimensionInfo/name`` (e.g. `"X"`, `"Z"`, `"semantic"`).
    public var scalars: [String: Data]
    /// `SIMD3<Float>` positions, centered on the bounds midpoint, 16-byte stride.
    public var position: Data
    /// `SIMD4<Float>` colors, channels normalized to `[0, 1]`, alpha `1`.
    public var color: Data
    /// `bounds` shifted by `-originShift` (so it is centered near the origin).
    public var centeredBounds: Bounds
    /// The midpoint that `position` was centered on: `world = local + originShift`.
    public var originShift: SIMD3<Float>
}

#if canImport(Metal)
/// A loaded point cloud de-interleaved into GPU-ready `MTLBuffer`s
/// (Struct-of-Arrays), plus packed `position`/`color`.
///
/// Returned by ``PointCloud/deinterleavedGeometry(device:backend:wideningIntegersToFloat:options:)``.
/// Buffers use the resource options passed to that method (default
/// `.storageModeShared`, so a Metal compute kernel and the CPU can read them
/// without a copy). Layout matches ``DeinterleavedRawGeometry``.
public struct DeinterleavedGeometry {
    /// The number of points; the element count of every buffer.
    public var pointCount: Int
    /// One contiguous `Float32` buffer per source dimension, keyed by
    /// ``DimensionInfo/name``.
    public var scalars: [String: MTLBuffer]
    /// `float3` positions, centered on the bounds midpoint, 16-byte stride
    /// (`MemoryLayout<SIMD3<Float>>.stride`).
    public var position: MTLBuffer
    /// `float4` colors, channels normalized to `[0, 1]`, alpha `1`.
    public var color: MTLBuffer
    /// `bounds` shifted by `-originShift`.
    public var centeredBounds: Bounds
    /// The midpoint `position` was centered on: `world = local + originShift`.
    public var originShift: SIMD3<Float>
}

/// Selects the compute backend for
/// ``PointCloud/deinterleavedGeometry(device:backend:wideningIntegersToFloat:options:)``.
public enum DeinterleaveBackend: Sendable {
    /// Pick the faster backend for the point count (GPU for large clouds, CPU
    /// for small ones where GPU dispatch overhead dominates). See
    /// ``PointCloud/deinterleaveAutoGPUThreshold``.
    case auto
    /// Force the Metal compute path.
    case gpu
    /// Force the vectorized CPU path (filling shared `MTLBuffer`s).
    case cpu
}
#endif

// MARK: - Centering / color helpers (shared by both backends)

extension PointCloud {
    /// The midpoint of `bounds`, used to center `position` for FP32 precision.
    var boundsMidpoint: SIMD3<Float> {
        (bounds.min + bounds.max) * 0.5
    }

    /// Locates the X/Y/Z dimensions (case-insensitive), if all three exist.
    func xyzDimensions() -> (x: DimensionInfo, y: DimensionInfo, z: DimensionInfo)? {
        func find(_ axis: String) -> DimensionInfo? {
            dimensions.first { $0.name.caseInsensitiveCompare(axis) == .orderedSame }
        }
        guard let x = find("X"), let y = find("Y"), let z = find("Z") else { return nil }
        return (x, y, z)
    }

    /// Locates the Red/Green/Blue dimensions (case-insensitive), if all three exist.
    func rgbDimensions() -> (r: DimensionInfo, g: DimensionInfo, b: DimensionInfo)? {
        func find(_ names: [String]) -> DimensionInfo? {
            dimensions.first { d in names.contains { $0.caseInsensitiveCompare(d.name) == .orderedSame } }
        }
        guard let r = find(["Red", "red"]),
              let g = find(["Green", "green"]),
              let b = find(["Blue", "blue"]) else { return nil }
        return (r, g, b)
    }
}

/// The normalization scale for color channels, matching WABF's heuristic:
/// 16-bit LAS color (`> 255`) → `1/65535`, 8-bit (`> 1`) → `1/255`, already
/// normalized (`<= 1`) → `1`.
@inline(__always)
func colorScale(forChannelMax maxV: Float) -> Float {
    maxV > 255.0 ? 1.0 / 65535.0 : (maxV > 1.0 ? 1.0 / 255.0 : 1.0)
}

// MARK: - CPU scatter core

/// Scatters one interleaved dimension into a contiguous `Float32` destination.
///
/// Uses an Accelerate strided conversion when one exists for the element type
/// (every access is naturally aligned because PDAL aligns each field's offset
/// to its width and the stride to the layout's max alignment), falling back to
/// a scalar `loadUnaligned` loop for 64-bit integers and `Double`.
///
/// - Parameters:
///   - dst: Destination `Float32` buffer, at least `count` elements.
///   - base: Pointer to dimension `dim` of point 0 (`pc.data + dim.offset`).
///   - count: Number of points.
///   - stride: Byte stride between consecutive points.
///   - dim: The source dimension descriptor.
func scatterScalarCPU(_ dst: UnsafeMutablePointer<Float>,
                      base: UnsafeRawPointer,
                      count: Int,
                      stride: Int,
                      dim: DimensionInfo) {
    guard count > 0 else { return }
    let code = ScalarTypeCode(dim)

    #if canImport(Accelerate)
    let n = vDSP_Length(count)
    switch code {
    case .int32:
        vDSP_vflt32(base.assumingMemoryBound(to: Int32.self), stride / 4, dst, 1, n); return
    case .uint32:
        vDSP_vfltu32(base.assumingMemoryBound(to: UInt32.self), stride / 4, dst, 1, n); return
    case .int16:
        vDSP_vflt16(base.assumingMemoryBound(to: Int16.self), stride / 2, dst, 1, n); return
    case .uint16:
        vDSP_vfltu16(base.assumingMemoryBound(to: UInt16.self), stride / 2, dst, 1, n); return
    case .int8:
        vDSP_vflt8(base.assumingMemoryBound(to: Int8.self), stride, dst, 1, n); return
    case .uint8:
        vDSP_vfltu8(base.assumingMemoryBound(to: UInt8.self), stride, dst, 1, n); return
    case .float32, .int64, .uint64, .float64:
        break  // no fused vDSP strided path; fall through to the scalar loop
    }
    #endif

    // Scalar fallback (64-bit integers, Double, or no Accelerate).
    for i in 0..<count {
        let p = base + i * stride
        switch code {
        case .uint8:  dst[i] = Float(p.loadUnaligned(as: UInt8.self))
        case .int8:   dst[i] = Float(p.loadUnaligned(as: Int8.self))
        case .uint16: dst[i] = Float(p.loadUnaligned(as: UInt16.self))
        case .int16:  dst[i] = Float(p.loadUnaligned(as: Int16.self))
        case .uint32: dst[i] = Float(p.loadUnaligned(as: UInt32.self))
        case .int32:  dst[i] = Float(p.loadUnaligned(as: Int32.self))
        case .uint64: dst[i] = Float(p.loadUnaligned(as: UInt64.self))
        case .int64:  dst[i] = Float(p.loadUnaligned(as: Int64.self))
        case .float32: dst[i] = p.loadUnaligned(as: Float.self)
        case .float64: dst[i] = Float(p.loadUnaligned(as: Double.self))  // documented f64→f32 loss
        }
    }
}

/// Computes the maximum across three contiguous `Float32` buffers.
func channelMax(_ r: UnsafePointer<Float>, _ g: UnsafePointer<Float>, _ b: UnsafePointer<Float>, count: Int) -> Float {
    guard count > 0 else { return 0 }
    #if canImport(Accelerate)
    var mr: Float = 0, mg: Float = 0, mb: Float = 0
    let n = vDSP_Length(count)
    vDSP_maxv(r, 1, &mr, n); vDSP_maxv(g, 1, &mg, n); vDSP_maxv(b, 1, &mb, n)
    return Swift.max(mr, Swift.max(mg, mb))
    #else
    var m: Float = 0
    for i in 0..<count { m = Swift.max(m, Swift.max(r[i], Swift.max(g[i], b[i]))) }
    return m
    #endif
}

// MARK: - CPU compose (writes into caller-provided destinations)

/// Shared CPU implementation: scatters every dimension and composes Position /
/// Color into destinations supplied by `allocate`. Both the Linux `Data` path
/// and the macOS shared-`MTLBuffer` CPU path route through here so they produce
/// byte-identical output.
///
/// - Parameter allocate: Vends a zeroed, `Float32`-aligned destination of the
///   given byte length for a logical buffer (a dimension name, `"@position"`,
///   or `"@color"`), returning its base pointer. Returns `nil` to abort.
/// - Returns: `(originShift, centeredBounds)` on success, `nil` on allocation failure.
func composeCPU(_ pc: PointCloud,
                allocate: (_ key: String, _ byteLength: Int) -> UnsafeMutableRawPointer?
) -> (originShift: SIMD3<Float>, centeredBounds: Bounds)? {
    let count = pc.pointCount
    let stride = pc.stride
    let base = pc.data
    let mid = pc.boundsMidpoint

    // 1. Scatter every dimension into its own Float32 buffer.
    var scalarPtrs: [String: UnsafeMutablePointer<Float>] = [:]
    for dim in pc.dimensions {
        guard let raw = allocate(dim.name, count * 4) else { return nil }
        let dst = raw.assumingMemoryBound(to: Float.self)
        scatterScalarCPU(dst, base: base + dim.offset, count: count, stride: stride, dim: dim)
        scalarPtrs[dim.name] = dst
    }

    // 2. Compose centered Position from the scattered X/Y/Z (zeros if absent).
    guard let posRaw = allocate("@position", count * MemoryLayout<SIMD3<Float>>.stride) else { return nil }
    let pos = posRaw.assumingMemoryBound(to: SIMD3<Float>.self)
    if let xyz = pc.xyzDimensions(),
       let xs = scalarPtrs[xyz.x.name], let ys = scalarPtrs[xyz.y.name], let zs = scalarPtrs[xyz.z.name] {
        for i in 0..<count {
            pos[i] = SIMD3<Float>(xs[i] - mid.x, ys[i] - mid.y, zs[i] - mid.z)
        }
    } else {
        for i in 0..<count { pos[i] = .zero }
    }

    // 3. Compose Color from Red/Green/Blue (normalized), else opaque white.
    guard let colRaw = allocate("@color", count * MemoryLayout<SIMD4<Float>>.stride) else { return nil }
    let col = colRaw.assumingMemoryBound(to: SIMD4<Float>.self)
    if let rgb = pc.rgbDimensions(),
       let rp = scalarPtrs[rgb.r.name], let gp = scalarPtrs[rgb.g.name], let bp = scalarPtrs[rgb.b.name] {
        let scale = colorScale(forChannelMax: channelMax(rp, gp, bp, count: count))
        for i in 0..<count {
            col[i] = SIMD4<Float>(rp[i] * scale, gp[i] * scale, bp[i] * scale, 1)
        }
    } else {
        for i in 0..<count { col[i] = SIMD4<Float>(1, 1, 1, 1) }
    }

    let centered = Bounds(min: pc.bounds.min - mid, max: pc.bounds.max - mid)
    return (mid, centered)
}

// MARK: - Public CPU entry point (all platforms)

extension PointCloud {
    /// De-interleaves this point cloud into platform-neutral, contiguous
    /// `Float32` byte buffers (Struct-of-Arrays) on the CPU.
    ///
    /// This is the always-available counterpart to
    /// ``deinterleavedGeometry(device:backend:wideningIntegersToFloat:options:)``;
    /// on platforms without Metal it is the only entry point. The source
    /// ``data`` is read but never freed (this method is non-destructive).
    ///
    /// See ``DeinterleavedRawGeometry`` for the exact buffer layout and the
    /// Position-centering / Color-normalization contract. `Double` dimensions
    /// (which PDAL reads never produce — they are narrowed to `Float`) are
    /// widened with the usual f64→f32 precision loss.
    ///
    /// - Parameter wideningIntegersToFloat: Reserved for symmetry with the
    ///   Metal entry point; integers are always widened to `Float32` so the
    ///   output is uniformly typed. Currently has no effect.
    /// - Returns: The de-interleaved geometry, or `nil` if an allocation failed.
    public func deinterleavedGeometryCPU(wideningIntegersToFloat: Bool = true) -> DeinterleavedRawGeometry? {
        // Own each destination as a manual allocation, then hand it to `Data`
        // via `bytesNoCopy`. This gives `composeCPU` stable base pointers
        // without nesting one `withUnsafeMutableBytes` per dimension.
        let alignment = 16
        var owned: [UnsafeMutableRawPointer] = []
        func make(_ byteLength: Int) -> UnsafeMutableRawPointer {
            let p = UnsafeMutableRawPointer.allocate(byteCount: max(byteLength, alignment), alignment: alignment)
            p.initializeMemory(as: UInt8.self, repeating: 0, count: max(byteLength, alignment))
            owned.append(p)
            return p
        }
        func freeAll() { for p in owned { p.deallocate() } }

        var ptrs: [String: UnsafeMutableRawPointer] = [:]
        let result = composeCPU(self) { key, byteLength in
            let p = make(byteLength)
            ptrs[key] = p
            return p
        }

        guard let r = result else { freeAll(); return nil }

        func wrap(_ p: UnsafeMutableRawPointer, _ len: Int) -> Data {
            Data(bytesNoCopy: p, count: len, deallocator: .custom { ptr, _ in ptr.deallocate() })
        }
        let count = pointCount
        var scalars: [String: Data] = [:]
        for dim in dimensions {
            scalars[dim.name] = wrap(ptrs[dim.name]!, count * 4)
        }
        return DeinterleavedRawGeometry(
            pointCount: count,
            scalars: scalars,
            position: wrap(ptrs["@position"]!, count * MemoryLayout<SIMD3<Float>>.stride),
            color: wrap(ptrs["@color"]!, count * MemoryLayout<SIMD4<Float>>.stride),
            centeredBounds: r.centeredBounds,
            originShift: r.originShift
        )
    }
}

// MARK: - Metal backend

#if canImport(Metal)

/// Embedded Metal source for the de-interleave / compose kernels. Compiled at
/// runtime (`makeLibrary(source:)`) and cached per device — see
/// ``DeinterleaveMetalEngine``. Runtime compilation avoids shipping a `.metal`
/// resource bundle and keeps the path uniform across macOS/iOS/visionOS.
///
/// All loads are naturally aligned: PDAL aligns each field's offset to its
/// width and the point stride to the layout's max alignment, so
/// `gid * strideBytes + offsetBytes` is always element-aligned. `Double` never
/// reaches the GPU (PDAL narrows it to `Float` at read time), and Apple GPUs
/// have no `double` — so the type switch tops out at `float`.
private let deinterleaveMetalSource = """
#include <metal_stdlib>
using namespace metal;

inline float load_typed(device const uchar* src, uint base, uint typeCode) {
    switch (typeCode) {
        case 0: return float(*(device const uchar*)(src + base));
        case 1: return float(*(device const char*)(src + base));
        case 2: return float(*(device const ushort*)(src + base));
        case 3: return float(*(device const short*)(src + base));
        case 4: return float(*(device const uint*)(src + base));
        case 5: return float(*(device const int*)(src + base));
        case 6: return float(*(device const ulong*)(src + base));
        case 7: return float(*(device const long*)(src + base));
        case 8: return *(device const float*)(src + base);
        default: return 0.0f;
    }
}

// params: x=count, y=strideBytes, z=offsetBytes, w=typeCode
kernel void deinterleave_scatter(device const uchar* src [[buffer(0)]],
                                 device float* dst [[buffer(1)]],
                                 constant uint4& params [[buffer(2)]],
                                 uint gid [[thread_position_in_grid]]) {
    if (gid >= params.x) return;
    dst[gid] = load_typed(src, gid * params.y + params.z, params.w);
}

kernel void compose_position(device const float* x [[buffer(0)]],
                             device const float* y [[buffer(1)]],
                             device const float* z [[buffer(2)]],
                             device float3* pos [[buffer(3)]],
                             constant uint& count [[buffer(4)]],
                             constant float3& mid [[buffer(5)]],
                             uint gid [[thread_position_in_grid]]) {
    if (gid >= count) return;
    pos[gid] = float3(x[gid] - mid.x, y[gid] - mid.y, z[gid] - mid.z);
}

kernel void fill_zero3(device float3* pos [[buffer(0)]],
                       constant uint& count [[buffer(1)]],
                       uint gid [[thread_position_in_grid]]) {
    if (gid >= count) return;
    pos[gid] = float3(0.0f, 0.0f, 0.0f);
}

// Non-negative color channels: IEEE-754 bit order matches float order, so an
// atomic max over the bit patterns yields the true channel max.
kernel void channel_max(device const float* r [[buffer(0)]],
                        device const float* g [[buffer(1)]],
                        device const float* b [[buffer(2)]],
                        device atomic_uint* outBits [[buffer(3)]],
                        constant uint& count [[buffer(4)]],
                        uint gid [[thread_position_in_grid]]) {
    if (gid >= count) return;
    float m = max(r[gid], max(g[gid], b[gid]));
    atomic_fetch_max_explicit(outBits, as_type<uint>(m), memory_order_relaxed);
}

kernel void compose_color(device const float* r [[buffer(0)]],
                          device const float* g [[buffer(1)]],
                          device const float* b [[buffer(2)]],
                          device float4* col [[buffer(3)]],
                          constant uint& count [[buffer(4)]],
                          constant float& scale [[buffer(5)]],
                          uint gid [[thread_position_in_grid]]) {
    if (gid >= count) return;
    col[gid] = float4(r[gid] * scale, g[gid] * scale, b[gid] * scale, 1.0f);
}

kernel void fill_white(device float4* col [[buffer(0)]],
                       constant uint& count [[buffer(1)]],
                       uint gid [[thread_position_in_grid]]) {
    if (gid >= count) return;
    col[gid] = float4(1.0f, 1.0f, 1.0f, 1.0f);
}
"""

/// Per-device cache of the compiled de-interleave pipelines. Compilation
/// happens once per `MTLDevice`; subsequent calls reuse the pipelines.
final class DeinterleaveMetalEngine: @unchecked Sendable {
    let scatter: MTLComputePipelineState
    let composePosition: MTLComputePipelineState
    let fillZero3: MTLComputePipelineState
    let channelMaxPipe: MTLComputePipelineState
    let composeColor: MTLComputePipelineState
    let fillWhite: MTLComputePipelineState

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [ObjectIdentifier: DeinterleaveMetalEngine] = [:]

    /// Returns the cached engine for `device`, compiling the kernels on first use.
    static func shared(for device: MTLDevice) -> DeinterleaveMetalEngine? {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(device)
        if let e = cache[key] { return e }
        guard let e = DeinterleaveMetalEngine(device: device) else { return nil }
        cache[key] = e
        return e
    }

    private init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: deinterleaveMetalSource, options: nil) else { return nil }
        func pipe(_ name: String) -> MTLComputePipelineState? {
            guard let fn = lib.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: fn)
        }
        guard let s = pipe("deinterleave_scatter"),
              let p = pipe("compose_position"),
              let z = pipe("fill_zero3"),
              let m = pipe("channel_max"),
              let c = pipe("compose_color"),
              let w = pipe("fill_white") else { return nil }
        scatter = s; composePosition = p; fillZero3 = z
        channelMaxPipe = m; composeColor = c; fillWhite = w
    }
}

extension MTLComputeCommandEncoder {
    /// Dispatches `count` threads for `pipeline` using a portable
    /// (threadgroup-count) dispatch; the kernels bounds-check `gid`.
    func dispatch1D(_ pipeline: MTLComputePipelineState, count: Int) {
        guard count > 0 else { return }
        setComputePipelineState(pipeline)
        let tpg = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        let groups = (count + tpg - 1) / tpg
        dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
    }
}

extension PointCloud {
    /// Point-count threshold at which ``DeinterleaveBackend/auto`` switches from
    /// the CPU path to the Metal path. Below this, GPU dispatch + per-buffer
    /// allocation overhead outweighs the parallel scatter; above it, the GPU
    /// wins. Tuned from the benchmark in `SwiftPDALTests`.
    nonisolated(unsafe) public static var deinterleaveAutoGPUThreshold: Int = 250_000

    /// De-interleaves this point cloud into GPU-ready `MTLBuffer`s
    /// (Struct-of-Arrays), plus packed centered `position` and normalized
    /// `color`. Additive and non-destructive: the source ``data`` is read but
    /// never freed, so it stays valid and is still released by `deinit`.
    ///
    /// See ``DeinterleavedGeometry`` for the buffer layout and the
    /// Position-centering / Color-normalization contract.
    ///
    /// - Parameters:
    ///   - device: The device to allocate the output buffers on.
    ///   - backend: Which compute backend to use. ``DeinterleaveBackend/auto``
    ///     (the default) picks the faster path for this point count via
    ///     ``deinterleaveAutoGPUThreshold``.
    ///   - wideningIntegersToFloat: Reserved for symmetry; integers are always
    ///     widened to `Float32`. Currently has no effect.
    ///   - options: Resource options for every output buffer. The default
    ///     `.storageModeShared` lets a Metal kernel and the CPU read the result
    ///     without a copy.
    /// - Returns: The de-interleaved geometry, or `nil` if Metal setup or an
    ///   allocation failed (callers may fall back to
    ///   ``deinterleavedGeometryCPU(wideningIntegersToFloat:)``).
    public func deinterleavedGeometry(device: MTLDevice,
                                      backend: DeinterleaveBackend = .auto,
                                      wideningIntegersToFloat: Bool = true,
                                      options: MTLResourceOptions = .storageModeShared
    ) -> DeinterleavedGeometry? {
        let useGPU: Bool
        switch backend {
        case .gpu: useGPU = true
        case .cpu: useGPU = false
        case .auto: useGPU = pointCount >= PointCloud.deinterleaveAutoGPUThreshold
        }
        return useGPU
            ? deinterleavedGeometryGPU(device: device, options: options)
            : deinterleavedGeometryCPUBuffers(device: device, options: options)
    }

    // MARK: CPU path filling shared MTLBuffers

    private func deinterleavedGeometryCPUBuffers(device: MTLDevice,
                                                 options: MTLResourceOptions) -> DeinterleavedGeometry? {
        let count = pointCount
        var buffers: [String: MTLBuffer] = [:]
        func make(_ key: String, _ len: Int) -> MTLBuffer? {
            guard let buf = device.makeBuffer(length: max(len, 16), options: options) else { return nil }
            buffers[key] = buf
            return buf
        }

        var failed = false
        let result = composeCPU(self) { key, len in
            guard let buf = make(key, len) else { failed = true; return nil }
            return buf.contents()
        }
        guard !failed, let r = result,
              let pos = buffers["@position"], let col = buffers["@color"] else { return nil }

        var scalars: [String: MTLBuffer] = [:]
        for dim in dimensions { scalars[dim.name] = buffers[dim.name] }
        return DeinterleavedGeometry(pointCount: count, scalars: scalars,
                                     position: pos, color: col,
                                     centeredBounds: r.centeredBounds, originShift: r.originShift)
    }

    // MARK: GPU path

    private func deinterleavedGeometryGPU(device: MTLDevice,
                                          options: MTLResourceOptions) -> DeinterleavedGeometry? {
        let count = pointCount
        guard count > 0,
              let engine = DeinterleaveMetalEngine.shared(for: device),
              let queue = device.makeCommandQueue() else { return nil }

        // Source AoS buffer, wrapped zero-copy (page-aligned by the C reader).
        // A nil deallocator means Metal never frees it — non-destructive. If the
        // no-copy initializer rejects the length, fall back to a one-time copy.
        let srcLen = size
        let srcMutable = UnsafeMutableRawPointer(mutating: data)
        let srcBuf = device.makeBuffer(bytesNoCopy: srcMutable, length: srcLen,
                                       options: .storageModeShared, deallocator: nil)
            ?? device.makeBuffer(bytes: data, length: srcLen, options: .storageModeShared)
        guard let srcBuf else { return nil }

        // Allocate outputs.
        var scalars: [String: MTLBuffer] = [:]
        for dim in dimensions {
            guard let buf = device.makeBuffer(length: max(count * 4, 16), options: options) else { return nil }
            scalars[dim.name] = buf
        }
        guard let position = device.makeBuffer(length: max(count * MemoryLayout<SIMD3<Float>>.stride, 16), options: options),
              let color = device.makeBuffer(length: max(count * MemoryLayout<SIMD4<Float>>.stride, 16), options: options)
        else { return nil }

        let mid = boundsMidpoint
        let xyz = xyzDimensions()
        let rgb = rgbDimensions()

        // 4-byte shared scratch for the atomic channel max.
        guard let maxBuf = device.makeBuffer(length: 4, options: .storageModeShared) else { return nil }
        maxBuf.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        guard let cmd1 = queue.makeCommandBuffer(), let enc1 = cmd1.makeComputeCommandEncoder() else { return nil }

        // Scatter every dimension.
        for dim in dimensions {
            guard let dst = scalars[dim.name] else { return nil }
            enc1.setBuffer(srcBuf, offset: 0, index: 0)
            enc1.setBuffer(dst, offset: 0, index: 1)
            var params = SIMD4<UInt32>(UInt32(count), UInt32(stride), UInt32(dim.offset), ScalarTypeCode(dim).rawValue)
            enc1.setBytes(&params, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 2)
            enc1.dispatch1D(engine.scatter, count: count)
        }

        // Compose centered Position from the scattered X/Y/Z (zeros if absent).
        if let xyz, let xb = scalars[xyz.x.name], let yb = scalars[xyz.y.name], let zb = scalars[xyz.z.name] {
            enc1.setBuffer(xb, offset: 0, index: 0)
            enc1.setBuffer(yb, offset: 0, index: 1)
            enc1.setBuffer(zb, offset: 0, index: 2)
            enc1.setBuffer(position, offset: 0, index: 3)
            var c = UInt32(count); enc1.setBytes(&c, length: 4, index: 4)
            var m = mid; enc1.setBytes(&m, length: MemoryLayout<SIMD3<Float>>.stride, index: 5)
            enc1.dispatch1D(engine.composePosition, count: count)
        } else {
            enc1.setBuffer(position, offset: 0, index: 0)
            var c = UInt32(count); enc1.setBytes(&c, length: 4, index: 1)
            enc1.dispatch1D(engine.fillZero3, count: count)
        }

        // Channel max for the color scale (GPU reduction; storage-agnostic).
        if let rgb, let rb = scalars[rgb.r.name], let gb = scalars[rgb.g.name], let bb = scalars[rgb.b.name] {
            enc1.setBuffer(rb, offset: 0, index: 0)
            enc1.setBuffer(gb, offset: 0, index: 1)
            enc1.setBuffer(bb, offset: 0, index: 2)
            enc1.setBuffer(maxBuf, offset: 0, index: 3)
            var c = UInt32(count); enc1.setBytes(&c, length: 4, index: 4)
            enc1.dispatch1D(engine.channelMaxPipe, count: count)
        }
        enc1.endEncoding()
        cmd1.commit()
        cmd1.waitUntilCompleted()
        guard cmd1.status == .completed else { return nil }

        // Compose Color in a second pass (needs the reduced scale).
        guard let cmd2 = queue.makeCommandBuffer(), let enc2 = cmd2.makeComputeCommandEncoder() else { return nil }
        if let rgb, let rb = scalars[rgb.r.name], let gb = scalars[rgb.g.name], let bb = scalars[rgb.b.name] {
            let maxBits = maxBuf.contents().load(as: UInt32.self)
            let maxV = Float(bitPattern: maxBits)
            var scale = colorScale(forChannelMax: maxV)
            enc2.setBuffer(rb, offset: 0, index: 0)
            enc2.setBuffer(gb, offset: 0, index: 1)
            enc2.setBuffer(bb, offset: 0, index: 2)
            enc2.setBuffer(color, offset: 0, index: 3)
            var c = UInt32(count); enc2.setBytes(&c, length: 4, index: 4)
            enc2.setBytes(&scale, length: 4, index: 5)
            enc2.dispatch1D(engine.composeColor, count: count)
        } else {
            enc2.setBuffer(color, offset: 0, index: 0)
            var c = UInt32(count); enc2.setBytes(&c, length: 4, index: 1)
            enc2.dispatch1D(engine.fillWhite, count: count)
        }
        enc2.endEncoding()
        cmd2.commit()
        cmd2.waitUntilCompleted()
        guard cmd2.status == .completed else { return nil }

        let centered = Bounds(min: bounds.min - mid, max: bounds.max - mid)
        return DeinterleavedGeometry(pointCount: count, scalars: scalars,
                                     position: position, color: color,
                                     centeredBounds: centered, originShift: mid)
    }
}

#endif
