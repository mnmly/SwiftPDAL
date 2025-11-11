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

        var totalPoints = 0
        var chunkCount = 0

        for try await progress in stream.load() {
            chunkCount += 1
            totalPoints = progress.chunk.totalPointsSoFar

            // Show progress
            print("   Chunk \(chunkCount): \(progress.chunk.pointCount) points loaded")
            print("   Total so far: \(totalPoints) points")

            if progress.chunk.isComplete {
                print("   ✅ Loading complete!")
            }
        }

        // Access final bounds
        if let bounds = stream.loadedBounds {
            print("\n   Final Results:")
            print("   └─ Total points: \(totalPoints)")
            print("   └─ Total chunks: \(chunkCount)")
            print("   └─ Bounds: [\(bounds.min.x), \(bounds.min.y), \(bounds.min.z)]")
            print("               to [\(bounds.max.x), \(bounds.max.y), \(bounds.max.z)]")
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
        if let bounds = stream.loadedBounds {
            print("\n   ✅ Memory-efficient processing complete")
            print("   └─ Processed \(totalProcessed) points using streaming")
            print("   └─ Peak memory: only ~\(stream.chunkSize) points in memory at once")
            print("   └─ Final bounds: [\(bounds.min.x), \(bounds.min.y), \(bounds.min.z)]")
        }
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
