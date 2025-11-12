import Foundation
import SwiftPDAL
import Metal
import simd

@main
struct StreamingExample {
    static func main() async {
        print("=== Streaming Point Cloud Example ===\n")

        // Get the path to a test file
        let currentDirectory = FileManager.default.currentDirectoryPath
        let testPath = "\(currentDirectory)/Tests/SwiftPDALTests/Resources/test.laz"

        guard FileManager.default.fileExists(atPath: testPath) else {
            print("❌ Error: test.laz not found at \(testPath)")
            print("   Please ensure the test file exists in Tests/SwiftPDALTests/Resources/")
            return
        }

        print("📂 Streaming point cloud from: \(testPath)")
        print("   Using AsyncStream for progressive loading\n")

        do {
            // Example 1: Basic streaming with progress updates
            print("━━━ Example 1: Basic Streaming ━━━")
            try await basicStreamingExample(path: testPath)

            // Example 2: Streaming with custom chunk processing
            print("\n━━━ Example 2: Custom Chunk Processing ━━━")
            try await chunkProcessingExample(path: testPath)

            // Example 3: Streaming with cancellation
            print("\n━━━ Example 3: Early Cancellation ━━━")
            try await cancellationExample(path: testPath)

            // Example 4: Memory-efficient large file processing
            print("\n━━━ Example 4: Memory-Efficient Processing ━━━")
            try await memoryEfficientExample(path: testPath)

        } catch {
            print("❌ Error: \(error)")
        }
    }

    // MARK: - Example 1: Basic Streaming

    static func basicStreamingExample(path: String) async throws {
        let stream = StreamingPointCloud(
            filePath: path,
            readerName: "readers.las",
            chunkSize: 10000  // Load 10k points at a time
        )

        // Load metadata first to get dimensions
        try stream.loadInfo(readerName: "readers.las")

        var totalPoints = 0
        var chunkCount = 0
        var firstStreamingPoints: [(x: Float, y: Float, z: Float)] = []

        for try await progress in stream.load() {
            chunkCount += 1
            totalPoints = progress.chunk.totalPointsSoFar

            // Show progress
            print("   Chunk \(chunkCount): \(progress.chunk.pointCount) points loaded")
            print("   Total so far: \(totalPoints) points")

            // Capture first 10 points from streaming (from first chunk only)
            if firstStreamingPoints.isEmpty && progress.chunk.pointCount > 0 {
                let data = progress.chunk.data
                let stride = progress.chunk.stride
                let pointsToCapture = min(10, progress.chunk.pointCount)

                // Find X, Y, Z dimensions - try both progress.dimensions and stream.dimensions
                let dims = !progress.dimensions.isEmpty ? progress.dimensions : stream.dimensions
                print("   📍 Dimension count: \(dims.count), Names: \(dims.map { String($0.name) })")

                let xDim = dims.first { String($0.name) == "X" }
                let yDim = dims.first { String($0.name) == "Y" }
                let zDim = dims.first { String($0.name) == "Z" }

                if let xDim, let yDim, let zDim {
                    print("   📍 X offset: \(xDim.offset), Y offset: \(yDim.offset), Z offset: \(zDim.offset), Stride: \(stride)")
                    for i in 0..<pointsToCapture {
                        let pointOffset = i * stride
                        let x = data.load(fromByteOffset: pointOffset + xDim.offset, as: Float.self)
                        let y = data.load(fromByteOffset: pointOffset + yDim.offset, as: Float.self)
                        let z = data.load(fromByteOffset: pointOffset + zDim.offset, as: Float.self)
                        firstStreamingPoints.append((x, y, z))
                    }
                } else {
                    print("   ⚠️  Could not find X, Y, Z dimensions")
                    print("   Available dimensions: \(dims.map { String($0.name) })")
                }
            }

            if progress.chunk.isComplete {
                print("   ✅ Loading complete!")
            }
        }

        print("\n   Final Results:")
        print("   └─ Total points: \(totalPoints)")
        print("   └─ Total chunks: \(chunkCount)")
        print("   └─ Bounds: [\(stream.bounds.min.x), \(stream.bounds.min.y), \(stream.bounds.min.z)]")
        print("               to [\(stream.bounds.max.x), \(stream.bounds.max.y), \(stream.bounds.max.z)]")

        // Now load with regular PointCloud.read and compare
        print("\n   📊 Comparing with regular PointCloud.read()...")
        var regularCloud = try PointCloud.read(from: path, readerName: "readers.las")
        defer { regularCloud.cleanup() }
        print("   Regular cloud point count: \(regularCloud.pointCount)")

        // Find X, Y, Z dimensions in regular cloud
        let dims = regularCloud.dimensions
        print("   Regular cloud dimensions: \(dims.map { String($0.name) })")
        let xDim = dims.first { String($0.name) == "X" }
        let yDim = dims.first { String($0.name) == "Y" }
        let zDim = dims.first { String($0.name) == "Z" }

        if let xDim, let yDim, let zDim {
            print("   Regular X offset: \(xDim.offset), Y offset: \(yDim.offset), Z offset: \(zDim.offset), Stride: \(regularCloud.stride)")
            print("\n   First 10 points comparison:")
            print("   ┌─────┬─────────────────────────────────┬─────────────────────────────────┬───────┐")
            print("   │ Idx │          Streaming              │           Regular               │ Match │")
            print("   ├─────┼─────────────────────────────────┼─────────────────────────────────┼───────┤")

            var allMatch = true
            for i in 0..<min(10, firstStreamingPoints.count) {
                let pointOffset = i * regularCloud.stride
                let regX = regularCloud.data.load(fromByteOffset: pointOffset + xDim.offset, as: Float.self)
                let regY = regularCloud.data.load(fromByteOffset: pointOffset + yDim.offset, as: Float.self)
                let regZ = regularCloud.data.load(fromByteOffset: pointOffset + zDim.offset, as: Float.self)

                let stream = firstStreamingPoints[i]
                let matches = abs(stream.x - regX) < 0.0001 &&
                             abs(stream.y - regY) < 0.0001 &&
                             abs(stream.z - regZ) < 0.0001

                allMatch = allMatch && matches
                let matchIcon = matches ? "✓" : "✗"

                print(String(format: "   │ %-3d │ (%.3f, %.3f, %.3f) │ (%.3f, %.3f, %.3f) │   %@   │",
                    i, stream.x, stream.y, stream.z, regX, regY, regZ, matchIcon))
            }
            print("   └─────┴─────────────────────────────────┴─────────────────────────────────┴───────┘")

            if allMatch {
                print("   ✅ All points match! Streaming is fetching data correctly.")
            } else {
                print("   ⚠️  Some points don't match. There may be an issue.")
            }
        }
    }

    // MARK: - Example 2: Custom Chunk Processing

    static func chunkProcessingExample(path: String) async throws {
        let stream = StreamingPointCloud(
            filePath: path,
            readerName: "readers.las",
            chunkSize: 5000
        )

        var pointsByColor: [String: Int] = [:]

        for try await progress in stream.load() {
            // Access raw chunk data
            let chunk = progress.chunk
            let data = chunk.data
            let stride = chunk.stride
            let pointCount = chunk.pointCount

            print("   Processing chunk: \(pointCount) points, stride: \(stride) bytes/point")

            // Example: Count points by accessing raw data
            // In a real app, you might process colors, filter points, etc.
            for i in 0..<pointCount {
                let pointOffset = i * stride
                // Here you could access specific dimension data using progress.dimensions
                // For example, read RGB values and categorize points
            }

            // Show dimension info from first chunk
            if progress.chunk.totalPointsSoFar == pointCount {
                print("\n   Available dimensions:")
                for dim in progress.dimensions {
                    print("   └─ \(dim.name): \(dim.outputSize) bytes at offset \(dim.offset)")
                }
            }
        }

        print("\n   ✅ Chunk processing complete")
    }

    // MARK: - Example 3: Early Cancellation

    static func cancellationExample(path: String) async throws {
        let stream = StreamingPointCloud(
            filePath: path,
            readerName: "readers.las",
            chunkSize: 1000
        )

        let maxChunks = 5
        var chunkCount = 0

        print("   Loading only first \(maxChunks) chunks...")

        for try await progress in stream.load() {
            chunkCount += 1
            print("   Chunk \(chunkCount): \(progress.chunk.pointCount) points")

            // Stop after processing desired number of chunks
            if chunkCount >= maxChunks {
                print("   ⏸️  Stopping after \(chunkCount) chunks")
                break
            }
        }

        print("   ✅ Successfully stopped early")
    }

    // MARK: - Example 4: Memory-Efficient Processing

    static func memoryEfficientExample(path: String) async throws {
        // Demonstrate processing a large file without loading everything into memory
        let stream = StreamingPointCloud(
            filePath: path,
            readerName: "readers.las",
            chunkSize: 50000  // Larger chunks for better performance
        )

        var minPoint = simd_float3(Float.infinity, Float.infinity, Float.infinity)
        var maxPoint = simd_float3(-Float.infinity, -Float.infinity, -Float.infinity)
        var totalProcessed = 0

        for try await progress in stream.load() {
            let chunk = progress.chunk

            // Process each chunk independently
            // In a real app, you might:
            // - Filter points
            // - Apply transformations
            // - Stream to GPU
            // - Write to output file
            // All without loading the entire dataset into memory!

            totalProcessed = chunk.totalPointsSoFar

            // Update running statistics
            print("   Processed: \(totalProcessed) points (chunk: \(chunk.pointCount))")
        }

        // Get final bounds (calculated by PDAL during streaming)
        print("\n   ✅ Memory-efficient processing complete")
        print("   └─ Processed \(totalProcessed) points using streaming")
        print("   └─ Peak memory: only ~\(stream.chunkSize) points in memory at once")
        print("   └─ Final bounds: [\(stream.bounds.min.x), \(stream.bounds.min.y), \(stream.bounds.min.z)]")
    }
}

// MARK: - Bonus: Streaming with SwiftUI

#if canImport(SwiftUI)
import SwiftUI

/// Example SwiftUI view showing real-time loading progress
@available(macOS 13.0, *)
struct StreamingProgressView: View {
    @State private var progress: Double = 0.0
    @State private var totalPoints: Int = 0
    @State private var isLoading = false
    @State private var errorMessage: String?

    let filePath: String

    var body: some View {
        VStack(spacing: 20) {
            Text("Point Cloud Streaming")
                .font(.largeTitle)

            if isLoading {
                ProgressView(value: progress) {
                    Text("Loading: \(totalPoints) points")
                }
                .progressViewStyle(.linear)
            } else if let error = errorMessage {
                Text("Error: \(error)")
                    .foregroundColor(.red)
            } else {
                Text("Ready to load")
            }

            Button("Start Streaming") {
                Task {
                    await loadPointCloud()
                }
            }
            .disabled(isLoading)
        }
        .padding()
        .frame(width: 400, height: 300)
    }

    func loadPointCloud() async {
        isLoading = true
        errorMessage = nil

        let stream = StreamingPointCloud(
            filePath: filePath,
            readerName: "readers.las",
            chunkSize: 10000
        )

        do {
            for try await progressUpdate in stream.load() {
                await MainActor.run {
                    totalPoints = progressUpdate.chunk.totalPointsSoFar

                    // Update progress (estimated)
                    if progressUpdate.estimatedTotalPoints > 0 {
                        progress = progressUpdate.progress
                    }
                }
            }

            await MainActor.run {
                isLoading = false
                progress = 1.0
            }

        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}
#endif
