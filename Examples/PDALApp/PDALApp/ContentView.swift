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

struct ContentView: View {
    @State private var results: [ReadResult] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
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
        }
    }

    private func fmt(_ v: SIMD3<Float>) -> String {
        String(format: "(%.3f, %.3f, %.3f)", v.x, v.y, v.z)
    }
}

#Preview {
    ContentView()
}
