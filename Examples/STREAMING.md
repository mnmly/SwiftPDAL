# Streaming Point Cloud Example

This example demonstrates how to use **StreamingPointCloud** with AsyncStream to progressively load and process large point cloud files.

## Quick Start

Run the streaming example:

```bash
swift run StreamingExample
```

## Overview

The `StreamingPointCloud` class provides a modern, memory-efficient way to work with large point cloud files by loading them in chunks rather than all at once.

### Basic Usage

```swift
let stream = StreamingPointCloud(
    filePath: "path/to/file.laz",
    readerName: "readers.las",
    chunkSize: 10000
)

for try await progress in stream.load() {
    print("Loaded \(progress.chunk.totalPointsSoFar) points")

    // Access chunk data
    let data = progress.chunk.data
    let stride = progress.chunk.stride
    let pointCount = progress.chunk.pointCount

    // Process the chunk...
}

// Get final bounds
if let bounds = stream.loadedBounds {
    print("Bounds: \(bounds.min) to \(bounds.max)")
}
```

## Examples Included

### 1. **Basic Streaming**
Shows how to load a file progressively with real-time progress updates.

### 2. **Custom Chunk Processing**
Demonstrates accessing raw point data and dimension information for custom processing.

### 3. **Early Cancellation**
Shows how to stop loading early by breaking out of the async loop.

### 4. **Memory-Efficient Processing**
Processes large files while keeping only one chunk in memory at a time.

### 5. **SwiftUI Integration** (Bonus)
A complete SwiftUI view with real-time progress visualization.

## Key Features

### 🎯 AsyncStream-Based
Uses Swift's native concurrency for clean, modern code:

```swift
for try await progress in stream.load() {
    // Process each chunk as it arrives
}
```

### 📊 Progress Tracking
Get real-time updates on loading progress:

```swift
print("Progress: \(progress.progress * 100)%")
print("Points loaded: \(progress.chunk.totalPointsSoFar)")
```

### 🧩 Chunk-by-Chunk Processing
Access raw data for each chunk:

```swift
let chunk = progress.chunk
let rawData = chunk.data
let stride = chunk.stride

for i in 0..<chunk.pointCount {
    let pointOffset = i * stride
    // Access point data...
}
```

### 💾 Memory Efficient
Only load what you need:

```swift
// Process 100M point file using only ~50k points in memory
let stream = StreamingPointCloud(
    filePath: "huge.laz",
    chunkSize: 50000  // Only 50k points loaded at once
)
```

### 🛑 Cancellable
Stop loading at any time:

```swift
for try await progress in stream.load() {
    if progress.chunk.totalPointsSoFar >= desiredCount {
        break  // Stop loading
    }
}
```

## Use Cases

### Real-Time Rendering
Stream points to GPU as they load:

```swift
for try await progress in stream.load() {
    let chunk = progress.chunk
    let metalBuffer = createMetalBuffer(from: chunk.data, count: chunk.pointCount)
    renderChunk(metalBuffer)
}
```

### Data Filtering
Filter points on-the-fly without loading entire file:

```swift
var filteredPoints: [SIMD3<Float>] = []

for try await progress in stream.load() {
    for dim in progress.dimensions {
        if dim.name == "X" {
            // Extract and filter X coordinates
        }
    }
}
```

### Format Conversion
Convert large files chunk-by-chunk:

```swift
let outputFile = FileHandle(forWritingAtPath: "output.xyz")

for try await progress in stream.load() {
    let chunk = progress.chunk
    // Convert and write chunk to output format
    outputFile.write(convertChunk(chunk))
}
```

### Statistics Computation
Calculate stats without loading entire dataset:

```swift
var min = SIMD3<Float>(repeating: .infinity)
var max = SIMD3<Float>(repeating: -.infinity)

for try await progress in stream.load() {
    // Update running statistics from chunk
    updateStats(from: progress.chunk)
}
```

## Performance Tips

### Chunk Size
- **Small chunks (1k-10k)**: Better responsiveness, more overhead
- **Medium chunks (10k-50k)**: Good balance for most use cases
- **Large chunks (50k-100k+)**: Better throughput, less frequent updates

```swift
// Responsive UI updates
StreamingPointCloud(filePath: path, chunkSize: 5000)

// High-throughput processing
StreamingPointCloud(filePath: path, chunkSize: 100000)
```

### Task Priority
For background loading:

```swift
Task(priority: .background) {
    for try await progress in stream.load() {
        await processInBackground(progress.chunk)
    }
}
```

### Parallel Processing
Process chunks in parallel (careful with memory):

```swift
await withTaskGroup(of: Void.self) { group in
    for try await progress in stream.load() {
        group.addTask {
            await processChunk(progress.chunk)
        }
    }
}
```

## Dimension Information

Access point cloud dimensions:

```swift
for try await progress in stream.load() {
    for dim in progress.dimensions {
        print("\(dim.name):")
        print("  Offset: \(dim.offset)")
        print("  Size: \(dim.outputSize) bytes")
    }
    break  // Just print from first chunk
}
```

Common dimensions:
- `X`, `Y`, `Z` - Coordinates
- `Red`, `Green`, `Blue` - Colors
- `Intensity` - Laser intensity
- `Classification` - Point classification
- `ReturnNumber` - LiDAR return number

## Error Handling

```swift
do {
    for try await progress in stream.load() {
        // Process...
    }
} catch PointCloudError.streamingFailed(let message) {
    print("Streaming failed: \(message)")
} catch {
    print("Unexpected error: \(error)")
}
```

## Comparison with Regular Loading

| Feature | Regular `PointCloud.read()` | `StreamingPointCloud` |
|---------|---------------------------|---------------------|
| Memory Usage | Full file in memory | One chunk at a time |
| Initial Latency | High (load all) | Low (first chunk fast) |
| Progress Updates | No | Yes, real-time |
| Cancellable | No | Yes |
| Early Termination | No | Yes |
| Best For | Small-medium files | Large files, UI progress |

## See Also

- [OctreeRenderingExample.swift](./OctreeRenderingExample.swift) - Standard loading with octree
- [MetalOctreeViewer](./MetalOctreeViewer/) - Interactive Metal rendering

## Requirements

- macOS 13.0+ (for async/await support)
- Swift 5.9+
- PDAL-enabled point cloud files (.laz, .las, .ply, .e57, etc.)
