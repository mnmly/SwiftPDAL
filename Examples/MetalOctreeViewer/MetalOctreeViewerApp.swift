import SwiftUI
import SwiftPDAL

@main
struct MetalOctreeViewerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = OctreeViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Metal View
            MetalViewRepresentable(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Controls
            ControlPanel(viewModel: viewModel)
        }
    }
}

struct ControlPanel: View {
    @ObservedObject var viewModel: OctreeViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Octree Visualization")
                    .font(.headline)
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            if let stats = viewModel.stats {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Points: \(stats.pointCount)")
                        Text("Cells: \(stats.cellCount)")
                    }
                    .font(.caption)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Depth: \(stats.maxDepth)")
                        Text("Leaf Nodes: \(stats.leafCount)")
                    }
                    .font(.caption)
                }
            }

            Divider()

            HStack {
                Toggle("Show Points", isOn: $viewModel.showPoints)
                    .toggleStyle(.checkbox)
                Toggle("Show Bounds", isOn: $viewModel.showBounds)
                    .toggleStyle(.checkbox)
                Toggle("Frustum Culling", isOn: $viewModel.enableCulling)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Text("Max LOD Level:")
                    .font(.caption)
                Slider(value: Binding(
                    get: { Double(viewModel.maxLODLevel) },
                    set: { viewModel.maxLODLevel = Int($0) }
                ), in: 0...8, step: 1)
                Text("\(viewModel.maxLODLevel)")
                    .font(.caption)
                    .frame(width: 20)
            }

            HStack {
                Text("Point Size:")
                    .font(.caption)
                Slider(value: $viewModel.pointSize, in: 1...10, step: 0.5)
                Text(String(format: "%.1f", viewModel.pointSize))
                    .font(.caption)
                    .frame(width: 30)
            }

            HStack {
                Button("Reset Camera") {
                    viewModel.resetCamera()
                }
                .buttonStyle(.bordered)

                Spacer()

                Text("Visible Cells: \(viewModel.visibleCellCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}

class OctreeViewModel: ObservableObject {
    @Published var showPoints = true
    @Published var showBounds = true
    @Published var enableCulling = true
    @Published var maxLODLevel = 8
    @Published var pointSize: Float = 2.0
    @Published var isLoading = false
    @Published var visibleCellCount = 0

    @Published var stats: OctreeStats?

    var renderer: OctreeRenderer?

    struct OctreeStats {
        let pointCount: Int
        let cellCount: Int
        let maxDepth: Int
        let leafCount: Int
    }

    func resetCamera() {
        renderer?.resetCamera()
    }
}
