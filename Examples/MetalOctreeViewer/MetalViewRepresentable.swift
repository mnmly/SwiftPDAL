import SwiftUI
import MetalKit
import SwiftPDAL

struct MetalViewRepresentable: NSViewRepresentable {
    let viewModel: OctreeViewModel

    func makeNSView(context: Context) -> MTKView {
        let mtkView = InteractiveMetalView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.delegate = context.coordinator

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Update renderer settings
        context.coordinator.renderer?.showPoints = viewModel.showPoints
        context.coordinator.renderer?.showBounds = viewModel.showBounds
        context.coordinator.renderer?.enableCulling = viewModel.enableCulling
        context.coordinator.renderer?.maxLODLevel = UInt8(viewModel.maxLODLevel)
        context.coordinator.renderer?.pointSize = viewModel.pointSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var renderer: OctreeRenderer?
        let viewModel: OctreeViewModel

        init(viewModel: OctreeViewModel) {
            self.viewModel = viewModel
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer?.drawableSizeWillChange(size: size)
        }

        func draw(in view: MTKView) {
            guard let device = view.device else { return }

            // Initialize renderer on first draw
            if renderer == nil {
                do {
                    renderer = try OctreeRenderer(device: device, view: view)
                    viewModel.renderer = renderer

                    // Set camera on interactive view
                    if let interactiveView = view as? InteractiveMetalView {
                        interactiveView.camera = renderer?.camera
                    }

                    // Load point cloud
                    Task { @MainActor in
                        viewModel.isLoading = true
                        try? await loadPointCloud(device: device)
                        viewModel.isLoading = false
                    }
                } catch {
                    print("Failed to initialize renderer: \(error)")
                    return
                }
            }

            // Render
            if let renderer = renderer {
                viewModel.visibleCellCount = renderer.visibleCellCount
                renderer.draw(in: view)
            }
        }

        @MainActor
        private func loadPointCloud(device: MTLDevice) async throws {
            let currentDirectory = FileManager.default.currentDirectoryPath
            let plyPath = "\(currentDirectory)/Tests/SwiftPDALTests/Resources/Stanford_Dragon.ply"

            guard FileManager.default.fileExists(atPath: plyPath) else {
                print("Error: Stanford_Dragon.ply not found at \(plyPath)")
                return
            }

            var pointCloud = try PointCloud.read(from: plyPath, readerName: "readers.ply")
            defer { pointCloud.cleanup() }

            // Build octree
            let octree = pointCloud.buildOctree(maxPointsPerNode: 1000, maxDepth: 1, useMortonOrder: true)

            // Load into renderer
            try renderer?.loadPointCloud(pointCloud: pointCloud, octree: octree)

            // Update stats
            let stats = octree.getStatistics()
            viewModel.stats = OctreeViewModel.OctreeStats(
                pointCount: pointCloud.pointCount,
                cellCount: stats.nodeCount,
                maxDepth: stats.maxDepth,
                leafCount: stats.leafCount
            )
        }
    }
}
