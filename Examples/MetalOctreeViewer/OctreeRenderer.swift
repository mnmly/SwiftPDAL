import Metal
import MetalKit
import SwiftPDAL
import simd

class OctreeRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let depthState: MTLDepthStencilState

    var pointPipelineState: MTLRenderPipelineState!
    var bboxPipelineState: MTLRenderPipelineState!
    
    // Point cloud data
    var pointVertexBuffer: MTLBuffer?
    var pointCount: Int = 0

    // Bounding box data
    var bboxVertexBuffer: MTLBuffer?
    var bboxIndexBuffer: MTLBuffer?
    var bboxIndexCount: Int = 0

    // Octree
    var octree: Octree?
    var pointCloudBounds: Bounds?

    // Camera
    var camera: Camera

    // Settings
    var showPoints = true
    var showBounds = true
    var enableCulling = true
    var maxLODLevel: UInt8 = 8
    var pointSize: Float = 2.0

    // Stats
    var visibleCellCount: Int = 0

    struct Uniforms {
        var modelViewProjectionMatrix: simd_float4x4
        var pointSize: Float
        var padding: SIMD3<Float> = .zero
    }

    @MainActor
    init(device: MTLDevice, view: MTKView) throws {
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw RendererError.failedToCreateCommandQueue
        }
        self.commandQueue = queue

        // Create depth state
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw RendererError.failedToCreateDepthState
        }
        self.depthState = depthState

        // Initialize camera
        self.camera = Camera()

        // Create pipeline states
        try createPipelineStates(view: view)
    }

    @MainActor
    private func createPipelineStates(view: MTKView) throws {
        // Load shader library from bundle resource
        guard let shaderURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
              let shaderSource = try? String(contentsOf: shaderURL),
              let library = try? device.makeLibrary(source: shaderSource, options: nil) else {
            throw RendererError.failedToCreateLibrary
        }

        // Point pipeline
        let pointVertexFunc = library.makeFunction(name: "point_vertex")
        let pointFragmentFunc = library.makeFunction(name: "point_fragment")

        let pointDescriptor = MTLRenderPipelineDescriptor()
        pointDescriptor.vertexFunction = pointVertexFunc
        pointDescriptor.fragmentFunction = pointFragmentFunc
        pointDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pointDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        // Vertex descriptor for points (position + color)
        let pointVertexDescriptor = MTLVertexDescriptor()
        // Position
        pointVertexDescriptor.attributes[0].format = .float3
        pointVertexDescriptor.attributes[0].offset = 0
        pointVertexDescriptor.attributes[0].bufferIndex = 0
        // Color
        pointVertexDescriptor.attributes[1].format = .float3
        pointVertexDescriptor.attributes[1].offset = 12
        pointVertexDescriptor.attributes[1].bufferIndex = 0
        // Stride
        pointVertexDescriptor.layouts[0].stride = 24 // 3 floats position + 3 floats color
        pointDescriptor.vertexDescriptor = pointVertexDescriptor

        pointPipelineState = try device.makeRenderPipelineState(descriptor: pointDescriptor)

        // Bounding box pipeline
        let bboxVertexFunc = library.makeFunction(name: "bbox_vertex")
        let bboxFragmentFunc = library.makeFunction(name: "bbox_fragment")

        let bboxDescriptor = MTLRenderPipelineDescriptor()
        bboxDescriptor.vertexFunction = bboxVertexFunc
        bboxDescriptor.fragmentFunction = bboxFragmentFunc
        bboxDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        bboxDescriptor.colorAttachments[0].isBlendingEnabled = true
        bboxDescriptor.colorAttachments[0].rgbBlendOperation = .add
        bboxDescriptor.colorAttachments[0].alphaBlendOperation = .add
        bboxDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        bboxDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        bboxDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        bboxDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        bboxDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        // Vertex descriptor for bounding boxes (position only)
        let bboxVertexDescriptor = MTLVertexDescriptor()
        bboxVertexDescriptor.attributes[0].format = .float3
        bboxVertexDescriptor.attributes[0].offset = 0
        bboxVertexDescriptor.attributes[0].bufferIndex = 0
        bboxVertexDescriptor.layouts[0].stride = 12 // 3 floats
        bboxDescriptor.vertexDescriptor = bboxVertexDescriptor

        bboxPipelineState = try device.makeRenderPipelineState(descriptor: bboxDescriptor)
    }

    func loadPointCloud(pointCloud: PointCloud, octree: Octree) throws {
        self.octree = octree
        self.pointCloudBounds = pointCloud.bounds

        // Extract point positions and colors
        guard let xDim = pointCloud.dimensions.first(where: { String($0.name) == "X" }),
              let yDim = pointCloud.dimensions.first(where: { String($0.name) == "Y" }),
              let zDim = pointCloud.dimensions.first(where: { String($0.name) == "Z" }) else {
            throw RendererError.missingDimensions
        }

        // Find color dimensions (optional)
        let redDim = pointCloud.dimensions.first(where: { String($0.name) == "Red" })
        let greenDim = pointCloud.dimensions.first(where: { String($0.name) == "Green" })
        let blueDim = pointCloud.dimensions.first(where: { String($0.name) == "Blue" })

        let hasColor = redDim != nil && greenDim != nil && blueDim != nil

        // Create vertex buffer (position + color)
        struct Vertex {
            var position: SIMD3<Float>
            var color: SIMD3<Float>
        }

        var vertices: [Vertex] = []
        vertices.reserveCapacity(pointCloud.pointCount)

        let data = pointCloud.data.assumingMemoryBound(to: UInt8.self)

        for i in 0..<pointCloud.pointCount {
            let offset = i * pointCloud.stride

            let x = data.advanced(by: offset + Int(xDim.offset))
                .withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
            let y = data.advanced(by: offset + Int(yDim.offset))
                .withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
            let z = data.advanced(by: offset + Int(zDim.offset))
                .withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }

            var color = SIMD3<Float>(0.8, 0.8, 0.8) // Default gray

            if hasColor, let r = redDim, let g = greenDim, let b = blueDim {
                let red = data.advanced(by: offset + Int(r.offset))
                    .withMemoryRebound(to: UInt8.self, capacity: 1) { Float($0.pointee) / 255.0 }
                let green = data.advanced(by: offset + Int(g.offset))
                    .withMemoryRebound(to: UInt8.self, capacity: 1) { Float($0.pointee) / 255.0 }
                let blue = data.advanced(by: offset + Int(b.offset))
                    .withMemoryRebound(to: UInt8.self, capacity: 1) { Float($0.pointee) / 255.0 }
                color = SIMD3<Float>(red, green, blue)
            }

            vertices.append(Vertex(position: SIMD3<Float>(x, y, z), color: color))
        }

        let bufferSize = vertices.count * MemoryLayout<Vertex>.stride
        guard let buffer = device.makeBuffer(bytes: vertices, length: bufferSize, options: .storageModeShared) else {
            throw RendererError.failedToCreateBuffer
        }

        pointVertexBuffer = buffer
        pointCount = vertices.count

        // Initialize camera to view the point cloud
        camera.centerOn(bounds: pointCloud.bounds)

        // Create bounding box buffers
        updateBoundingBoxBuffers()
    }


    func updateBoundingBoxBuffers() {
        guard let octree = octree else { return }

        // Get all leaf cells
        let cells = octree.getAllLeafCells()

        // --- V ADD LOGGER HERE V ---
        print("[Renderer] Received \(cells.count) leaf cells to draw.")
        if let firstCell = cells.first, !cells.isEmpty {
            print("  - First cell bounds: min=\(firstCell.bounds.min), max=\(firstCell.bounds.max)")
        }
        // --- ^ ADD LOGGER HERE ^ ---

        // Create batched bounding box buffers
        if let buffers = cells.createBatchedBoundingBoxBuffers(device: device) {
            bboxVertexBuffer = buffers.vertexBuffer
            bboxIndexBuffer = buffers.indexBuffer
            bboxIndexCount = cells.totalBoundingBoxEdges * 2 // 2 vertices per edge

            // --- V ADD DEBUG CODE HERE V ---
        
        // Run this check only once
        // if !Self.didDebugBuffers {
            // Self.didDebugBuffers = true
            
            print("--- [BUFFER DEBUG] ---")
            
            // --- 1. DEBUG VERTEX BUFFER (bboxVertexBuffer) ---
            let vertexCount = bboxVertexBuffer!.length / MemoryLayout<simd_float3>.stride
            let vertexPtr = bboxVertexBuffer!.contents().bindMemory(to: simd_float3.self, capacity: vertexCount)
            let vertices = UnsafeBufferPointer(start: vertexPtr, count: vertexCount)
            
            print("Vertex Buffer: \(vertices.count) vertices total.")
            
            // Each cell has 8 vertices
            if vertices.count >= 8 {
                let firstCellVertices = Array(vertices.prefix(8))
                print("  First Cell Vertices (Cell 0):")
                
                // The 8 vertices for the first cell
                //
                let v0_min = firstCellVertices[0] // expected min
                let v6_max = firstCellVertices[6] // expected max
                
                print("    - Vert 0 (min): \(v0_min)")
                print("    - Vert 6 (max): \(v6_max)")
                
                // Compare with the source data
                let expectedMin = cells[0].bounds.min
                let expectedMax = cells[0].bounds.max
                print("    - Expected min: \(expectedMin)")
                print("    - Expected max: \(expectedMax)")
                
                if v0_min == expectedMin && v6_max == expectedMax {
                    print("    - VERDICT: Vertex data looks correct.")
                } else {
                    print("    - VERDICT: !!! VERTEX DATA MISMATCH !!!")
                }
            }
            
            // --- 2. DEBUG INDEX BUFFER (bboxIndexBuffer) ---
            let indexCount = bboxIndexBuffer!.length / MemoryLayout<UInt16>.stride
            let indexPtr = bboxIndexBuffer!.contents().bindMemory(to: UInt16.self, capacity: indexCount)
            let indices = UnsafeBufferPointer(start: indexPtr, count: indexCount)
            
            print("Index Buffer: \(indices.count) indices total.")
            
            // Each cell has 24 indices (12 edges * 2)
            if indices.count >= 24 {
                let firstCellIndices = Array(indices.prefix(24))
                print("  First Cell Indices (Cell 0):")
                print("    - \(firstCellIndices.prefix(6))...") // e.g., [0, 1, 1, 2, 2, 3]...
                
                if firstCellIndices.max() == 7 {
                    print("    - VERDICT: Cell 0 indices look correct (range 0-7).")
                } else {
                    print("    - VERDICT: !!! CELL 0 INDEX RANGE ERROR !!!")
                }
            }
            print("ALL INDICES:")
            print(Array(indices))
            
            // Check offset for the second cell (if it exists)
            if indices.count >= 48 && cells.count >= 2 {
                let secondCellIndices = Array(indices[24..<48])
                print("  Second Cell Indices (Cell 1):")
                print("    - \(secondCellIndices.prefix(6))...") // e.g., [8, 9, 9, 10, 10, 11]...
                
                if secondCellIndices.min() == 8 && secondCellIndices.max() == 15 {
                    print("    - VERDICT: Cell 1 indices look correct (range 8-15).")
                } else {
                    print("    - VERDICT: !!! CELL 1 INDEX OFFSET ERROR !!!")
                }
            }
            
            print("--- [BUFFER DEBUG END] ---")
        // }
        // --- ^ DEBUG CODE END ^ ---

        }
    }

    func drawableSizeWillChange(size: CGSize) {
        camera.aspectRatio = Float(size.width / size.height)
    }

    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setDepthStencilState(depthState)

        // Update uniforms
        var uniforms = Uniforms(
            modelViewProjectionMatrix: camera.viewProjectionMatrix,
            pointSize: pointSize
        )

        // Draw points
        if showPoints, let pointBuffer = pointVertexBuffer, pointCount > 0 {
            encoder.setRenderPipelineState(pointPipelineState)
            encoder.setVertexBuffer(pointBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
        }

        // Draw bounding boxes
        if showBounds, let bboxVertexBuffer = bboxVertexBuffer,
           let bboxIndexBuffer = bboxIndexBuffer, bboxIndexCount > 0 {
            encoder.setRenderPipelineState(bboxPipelineState)
            encoder.setVertexBuffer(bboxVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(
                type: .lineStrip,
                indexCount: bboxIndexCount,
                indexType: .uint16,
                indexBuffer: bboxIndexBuffer,
                indexBufferOffset: 0
            )
        }

        encoder.endEncoding()

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }

        commandBuffer.commit()
    }

    func resetCamera() {
        if let bounds = pointCloudBounds {
            camera.centerOn(bounds: bounds)
        }
    }

    enum RendererError: Error {
        case failedToCreateCommandQueue
        case failedToCreateDepthState
        case failedToCreateLibrary
        case failedToCreateBuffer
        case missingDimensions
    }
}
