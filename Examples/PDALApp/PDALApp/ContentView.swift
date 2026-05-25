//
//  ContentView.swift
//  PDALApp
//
//  GUI smoke test for SwiftPDAL on iOS. Loads bundled test files via
//  SwiftPDAL.PointCloud.read and reports point count + bounds so a
//  human can verify the framework actually works in an app context
//  (not just in unit tests).

import SwiftUI
import SwiftPDAL
import simd

struct ContentView: View {
    @State private var results: [ReadResult] = []
    @State private var error: String?
    @State private var streamStatus: String = "idle"
    @State private var streamingTask: Task<Void, Never>?

    private let probedDrivers: [String] = [
        "readers.las", "readers.ply", "readers.text", "readers.copc",
        "writers.las", "writers.ply", "writers.copc", "writers.text",
        "filters.range", "filters.assign", "filters.reprojection", "filters.transformation",
        "readers.e57",
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Static plugin registration (iOS)") {
                    ForEach(probedDrivers, id: \.self) { name in
                        let ok = PDALConvert.isDriverRegistered(name)
                        HStack {
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(ok ? .green : .red)
                            Text(name).font(.caption.monospaced())
                        }
                    }
                }

                Section("Bundled files") {
                    ForEach(bundledFiles, id: \.path) { file in
                        Button {
                            run(file)
                        } label: {
                            HStack {
                                Image(systemName: "doc")
                                VStack(alignment: .leading) {
                                    Text(file.label).font(.headline)
                                    Text(file.path)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("COPC streaming (CopcStreamingPointCloudSource)") {
                    Button {
                        runStreamingSmokeTest()
                    } label: {
                        HStack {
                            Image(systemName: "waveform.path")
                            VStack(alignment: .leading) {
                                Text("Stream test.copc.laz").font(.headline)
                                Text("Reproduces the iOS lazperf vtable crash")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("status: \(streamStatus)")
                        .font(.caption.monospaced())
                }

                if let error {
                    Section("Error") {
                        Text(error).font(.caption.monospaced()).foregroundStyle(.red)
                    }
                }

                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { r in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.label).font(.headline)
                                Text("points: \(r.pointCount)").font(.caption.monospaced())
                                Text("min: \(fmt(r.minXYZ))").font(.caption.monospaced())
                                Text("max: \(fmt(r.maxXYZ))").font(.caption.monospaced())
                                Text("read time: \(String(format: "%.3f", r.duration))s")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("PDALApp")
        }
    }

    private struct BundledFile {
        let label: String
        let resource: String
        let ext: String
        let readerName: String
        var path: String { "\(resource).\(ext)" }
    }

    private var bundledFiles: [BundledFile] {
        [
            BundledFile(label: "test.laz", resource: "test", ext: "laz", readerName: "readers.las"),
            BundledFile(label: "bunnyFloat.e57", resource: "bunnyFloat", ext: "e57", readerName: "readers.e57"),
        ]
    }

    private struct ReadResult: Identifiable {
        let id = UUID()
        let label: String
        let pointCount: Int
        let minXYZ: SIMD3<Float>
        let maxXYZ: SIMD3<Float>
        let duration: Double
    }

    private func run(_ file: BundledFile) {
        error = nil
        guard let url = Bundle.main.url(forResource: file.resource, withExtension: file.ext) else {
            error = "Bundle.main has no resource \(file.path) — check the Xcode target's Resources phase."
            return
        }
        let start = Date()
        // PDAL emits its real error to std::cerr; the Swift wrapper
        // surfaces only a generic "readFailed". Capture stderr around
        // the read call so we can see what actually went wrong.
        let captured = captureStderr {
            do {
                let pc = try PointCloud.read(from: url.path, readerName: file.readerName)
                let elapsed = Date().timeIntervalSince(start)
                results.insert(
                    ReadResult(
                        label: file.label,
                        pointCount: pc.pointCount,
                        minXYZ: pc.bounds.min,
                        maxXYZ: pc.bounds.max,
                        duration: elapsed
                    ),
                    at: 0
                )
            } catch {
                self.error = "\(file.label): \(error)"
                print(self.error!)
            }
        }
        if !captured.isEmpty {
            let prefix = self.error ?? ""
            self.error = (prefix.isEmpty ? "" : prefix + "\n") + "stderr: " + captured
            print(self.error!)
        }
    }

    /// Exercise CopcStreamingPointCloudSource on a bundled COPC file —
    /// this is the path that crashes on iOS device with
    /// `__cxa_pure_virtual` when the two lazperf vtables (PDAL's
    /// vendored copy vs copclib's patched copy) disagree.
    private func runStreamingSmokeTest() {
        streamingTask?.cancel()
        streamStatus = "opening…"
        guard let url = Bundle.main.url(forResource: "test.copc", withExtension: "laz") else {
            streamStatus = "missing test.copc.laz"
            return
        }
        streamingTask = Task { @MainActor in
            do {
                let source = try await CopcStreamingPointCloudSource.open(url, options: .init(
                    decodeConcurrency: 2, prefetchRoot: true,
                    driverTickInterval: .milliseconds(10)
                ))
                defer { source.close() }
                streamStatus = "opened — \(source.info.totalPoints) pts, \(source.info.maxDepth) depth"

                // Wide top-down view of the whole bounds.
                let b = source.info.bounds
                let originShift = source.info.originShift
                let centerWorld = (b.min + b.max) * 0.5
                let center = SIMD3<Float>(
                    centerWorld.x - Float(originShift.x),
                    centerWorld.y - Float(originShift.y),
                    centerWorld.z - Float(originShift.z)
                )
                let span = simd_length(b.max - b.min)
                let eye = center + SIMD3<Float>(0, 0, span)
                let f = simd_normalize(center - eye)
                let s = simd_normalize(simd_cross(f, SIMD3<Float>(0, 1, 0)))
                let u = simd_cross(s, f)
                let view = simd_float4x4(
                    SIMD4<Float>( s.x,  u.x, -f.x, 0),
                    SIMD4<Float>( s.y,  u.y, -f.y, 0),
                    SIMD4<Float>( s.z,  u.z, -f.z, 0),
                    SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye),  simd_dot(f, eye), 1)
                )
                let fov: Float = .pi / 2
                let near: Float = 1
                let far = span * 4
                let yScale = 1 / tan(fov * 0.5)
                let zRange = far - near
                let proj = simd_float4x4(
                    SIMD4<Float>(yScale, 0,      0,                   0),
                    SIMD4<Float>(0,      yScale, 0,                   0),
                    SIMD4<Float>(0,      0,     -(far + near)/zRange, -1),
                    SIMD4<Float>(0,      0,     -2*far*near/zRange,   0)
                )
                source.setBudget(Int.max)
                source.submit(view: StreamingCameraView(
                    position: eye,
                    viewProjection: proj * view,
                    pixelScale: 1000
                ))

                // Drain decoded batches until every node has been served
                // or we time out. The crash (if present) fires inside the
                // decode worker on the first decompress() call.
                let deadline = Date().addingTimeInterval(15)
                var decoded = 0
                var batches = 0
                while Date() < deadline {
                    if let delta = source.pollLatest() {
                        batches += delta.added.reduce(0) { $0 + $1.batches.count }
                        decoded += delta.added.reduce(0) { $0 + $1.totalPointCount }
                        streamStatus = "decoded \(decoded) pts / \(batches) batches"
                    }
                    let snap = await source._debugSnapshot()
                    if snap.totalNodes > 0, snap.wanted > 0,
                       snap.resident >= snap.wanted, snap.inFlight == 0 {
                        streamStatus = "done — \(snap.resident)/\(snap.totalNodes) nodes resident, \(decoded) pts"
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                streamStatus = "timeout — \(decoded) pts decoded"
            } catch {
                streamStatus = "open failed: \(error)"
                self.error = "streaming: \(error)"
            }
        }
    }

    /// Redirect stderr (fd 2) through a pipe for the duration of
    /// `block` and return whatever was written.
    private func captureStderr(_ block: () -> Void) -> String {
        let pipe = Pipe()
        let oldFD = dup(2)
        dup2(pipe.fileHandleForWriting.fileDescriptor, 2)
        block()
        fflush(stderr)
        dup2(oldFD, 2)
        close(oldFD)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func fmt(_ v: SIMD3<Float>) -> String {
        String(format: "(%.3f, %.3f, %.3f)", v.x, v.y, v.z)
    }
}

#Preview {
    ContentView()
}
