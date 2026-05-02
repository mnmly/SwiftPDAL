import Testing
import Foundation
import CxxPDAL
@testable import SwiftPDAL

@Test func readLAZFile() async throws {

    setenv("SWIFTPDAL_TESTING", "1", 1)
    // Get test file from bundle
    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    // Verify we got points
    #expect(pointCloud.pointCount > 0)

    // Print basic info
    print("Point count: \(pointCloud.pointCount)")
    print("Bounds: [\(pointCloud.bounds.min.x), \(pointCloud.bounds.min.y), \(pointCloud.bounds.min.z)] to [\(pointCloud.bounds.max.x), \(pointCloud.bounds.max.y), \(pointCloud.bounds.max.z)]")
    print("Data size: \(pointCloud.size) bytes")
    print("Stride: \(pointCloud.stride) bytes per point")

    // Print dimensions
    print("Dimensions:")
    for dim in pointCloud.dimensions {
        print("  - \(dim.name): size=\(dim.outputSize), offset=\(dim.offset)")
    }

    // Clean up

}

@Test func readE57File() async throws {

    setenv("SWIFTPDAL_TESTING", "1", 1)
    // Get test file from bundle
    guard let testFilePath = Bundle.module.path(forResource: "bunnyFloat", ofType: "e57") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let pointCloud = try PointCloud.read(from: testFilePath)

    // Verify we got points
    #expect(pointCloud.pointCount > 0)

    // Print basic info
    print("Point count: \(pointCloud.pointCount)")
    print("Bounds: [\(pointCloud.bounds.min.x), \(pointCloud.bounds.min.y), \(pointCloud.bounds.min.z)] to [\(pointCloud.bounds.max.x), \(pointCloud.bounds.max.y), \(pointCloud.bounds.max.z)]")
    print("Data size: \(pointCloud.size) bytes")
    print("Stride: \(pointCloud.stride) bytes per point")

    // Print dimensions
    print("Dimensions:")
    for dim in pointCloud.dimensions {
        print("  - \(dim.name): size=\(dim.outputSize), offset=\(dim.offset)")
    }

    // Clean up

}

// MARK: - Streaming Tests

@Test func streamingReadBasic() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    var chunkCount = 0
    var totalPointsReceived = 0
    var lastChunk: PointCloudChunk?
    var dimensions: [DimensionInfo]?

    // Use the new AsyncStream API
    let stream = StreamingPointCloud(
        filePath: testFilePath,
        readerName: "readers.las",
        chunkSize: 1000
    )

    for try await progress in stream.load() {
        chunkCount += 1
        totalPointsReceived += progress.chunk.pointCount
        lastChunk = progress.chunk

        // Save dimensions from first chunk
        if dimensions == nil {
            dimensions = progress.dimensions
        }

        print("Chunk \(chunkCount): \(progress.chunk.pointCount) points (total: \(progress.chunk.totalPointsSoFar))")
    }

    // Verify we received chunks
    #expect(chunkCount > 0)
    #expect(totalPointsReceived > 0)

    // Verify last chunk was marked complete
    #expect(lastChunk?.isComplete == true)

    // Verify dimensions were received
    #expect(dimensions != nil)
    #expect(dimensions!.count > 0)

    // Verify bounds are valid after completion
    let bounds = stream.bounds
    #expect(bounds.min.x < bounds.max.x)
    #expect(bounds.min.y < bounds.max.y)
    #expect(bounds.min.z < bounds.max.z)

    print("\nStreaming Summary:")
    print("  Total chunks: \(chunkCount)")
    print("  Total points: \(totalPointsReceived)")
    print("  Dimensions: \(dimensions?.count ?? 0)")
    print("  Bounds: [\(bounds.min.x), \(bounds.min.y), \(bounds.min.z)] to [\(bounds.max.x), \(bounds.max.y), \(bounds.max.z)]")
}

@Test func streamingReadWithCancellation() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    let maxChunks = 3
    var chunkCount = 0

    let stream = StreamingPointCloud(
        filePath: testFilePath,
        readerName: "readers.las",
        chunkSize: 1000
    )

    // Simply break after maxChunks
    for try await progress in stream.load() {
        chunkCount += 1
        print("Chunk \(chunkCount): \(progress.chunk.pointCount) points")

        // Cancel after 3 chunks
        if chunkCount >= maxChunks {
            break
        }
    }

    // Verify we stopped at the right number of chunks
    #expect(chunkCount == maxChunks)

    print("Successfully stopped after \(chunkCount) chunks")
}

@Test func streamingReadChunkDataAccess() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    var firstChunkData: Data?
    var firstChunkDimensions: [DimensionInfo]?

    let stream = StreamingPointCloud(
        filePath: testFilePath,
        readerName: "readers.las",
        chunkSize: 100
    )

    for try await progress in stream.load() {
        // On first chunk, copy the data for inspection
        if firstChunkData == nil {
            let dataSize = progress.chunk.pointCount * progress.chunk.stride
            firstChunkData = Data(bytes: progress.chunk.data, count: dataSize)
            firstChunkDimensions = progress.dimensions

            print("First chunk captured:")
            print("  Points: \(progress.chunk.pointCount)")
            print("  Stride: \(progress.chunk.stride)")
            print("  Data size: \(dataSize) bytes")
            print("  Dimensions:")
            for dim in progress.dimensions {
                print("    - \(dim.name): offset=\(dim.offset), size=\(dim.outputSize)")
            }

            // Verify we can access the raw data
            #expect(firstChunkData!.count > 0)
            #expect(firstChunkData!.count == dataSize)

            // Stop after first chunk
            break
        }
    }

    // Verify we captured the data
    #expect(firstChunkData != nil)
    #expect(firstChunkDimensions != nil)
    #expect(firstChunkDimensions!.count > 0)
}

@Test func streamingReadProgressTracking() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    var progressUpdates: [(chunk: Int, points: Int, complete: Bool)] = []

    let stream = StreamingPointCloud(
        filePath: testFilePath,
        readerName: "readers.las",
        chunkSize: 500
    )

    for try await progress in stream.load() {
        progressUpdates.append((
            chunk: progressUpdates.count + 1,
            points: progress.chunk.totalPointsSoFar,
            complete: progress.chunk.isComplete
        ))
    }

    // Verify progress tracking
    #expect(progressUpdates.count > 0)

    // Verify totalPointsSoFar increases monotonically
    for i in 1..<progressUpdates.count {
        #expect(progressUpdates[i].points > progressUpdates[i-1].points)
    }

    // Only last chunk should be marked complete
    for i in 0..<progressUpdates.count-1 {
        #expect(progressUpdates[i].complete == false)
    }
    #expect(progressUpdates.last?.complete == true)

    print("Progress tracking:")
    for update in progressUpdates {
        let status = update.complete ? "COMPLETE" : "ongoing"
        print("  Chunk \(update.chunk): \(update.points) points total [\(status)]")
    }
}

@Test func streamingVsNormalReadComparison() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)

    guard let testFilePath = Bundle.module.path(forResource: "test", ofType: "laz") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    // Normal read
    let normalCloud = try PointCloud.read(from: testFilePath, readerName: "readers.las")

    // Streaming read
    var streamingTotalPoints = 0
    var streamingStride = 0
    var streamingDimensions: [DimensionInfo]?

    let stream = StreamingPointCloud(
        filePath: testFilePath,
        readerName: "readers.las",
        chunkSize: 1000
    )

    for try await progress in stream.load() {
        streamingTotalPoints = progress.chunk.totalPointsSoFar
        streamingStride = progress.chunk.stride
        if streamingDimensions == nil {
            streamingDimensions = progress.dimensions
        }
    }

    let streamingBounds = stream.bounds

    // Compare results
    #expect(streamingTotalPoints == normalCloud.pointCount)
    #expect(streamingStride == normalCloud.stride)
    #expect(streamingDimensions?.count == normalCloud.dimensions.count)

    // Bounds should be approximately the same
    let epsilon: Float = 0.001
    #expect(abs(streamingBounds.min.x - normalCloud.bounds.min.x) < epsilon)
    #expect(abs(streamingBounds.min.y - normalCloud.bounds.min.y) < epsilon)
    #expect(abs(streamingBounds.min.z - normalCloud.bounds.min.z) < epsilon)
    #expect(abs(streamingBounds.max.x - normalCloud.bounds.max.x) < epsilon)
    #expect(abs(streamingBounds.max.y - normalCloud.bounds.max.y) < epsilon)
    #expect(abs(streamingBounds.max.z - normalCloud.bounds.max.z) < epsilon)

    print("\nComparison:")
    print("  Point count - Normal: \(normalCloud.pointCount), Streaming: \(streamingTotalPoints)")
    print("  Stride - Normal: \(normalCloud.stride), Streaming: \(streamingStride)")
    print("  Dimensions - Normal: \(normalCloud.dimensions.count), Streaming: \(streamingDimensions?.count ?? 0)")


}

@Test func streamingReadE57File() async throws {
    setenv("SWIFTPDAL_TESTING", "1", 1)

    guard let testFilePath = Bundle.module.path(forResource: "bunnyFloat", ofType: "e57") else {
        throw PointCloudError.readFailed("Test file not found in bundle")
    }

    var chunkCount = 0
    var totalPoints = 0

    let stream = StreamingPointCloud(filePath: testFilePath, chunkSize: 2000)

    for try await progress in stream.load() {
        chunkCount += 1
        totalPoints = progress.chunk.totalPointsSoFar
    }

    let bounds = stream.bounds

    #expect(chunkCount > 0)
    #expect(totalPoints > 0)
    #expect(bounds.min.x < bounds.max.x)

    print("E57 Streaming: \(chunkCount) chunks, \(totalPoints) points")
}
