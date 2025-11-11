import MetalKit
import AppKit

class InteractiveMetalView: MTKView {
    var camera: Camera?

    private var lastMouseLocation: NSPoint?
    private var isRotating = false
    private var isPanning = false

    override func mouseDown(with event: NSEvent) {
        lastMouseLocation = convert(event.locationInWindow, from: nil)

        if event.modifierFlags.contains(.command) {
            isPanning = true
        } else {
            isRotating = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastMouseLocation else { return }

        let current = convert(event.locationInWindow, from: nil)
        let delta = NSPoint(x: current.x - last.x, y: current.y - last.y)

        if isRotating {
            // Rotate camera
            let sensitivity: Float = 0.005
            camera?.rotate(
                deltaAzimuth: Float(delta.x) * sensitivity,
                deltaElevation: Float(delta.y) * sensitivity
            )
        } else if isPanning {
            // Pan camera
            let sensitivity: Float = 1.0
            camera?.pan(
                deltaX: -Float(delta.x) * sensitivity,
                deltaY: Float(delta.y) * sensitivity
            )
        }

        lastMouseLocation = current
    }

    override func mouseUp(with event: NSEvent) {
        lastMouseLocation = nil
        isRotating = false
        isPanning = false
    }

    override func scrollWheel(with event: NSEvent) {
        let sensitivity: Float = 0.001
        camera?.zoom(delta: Float(event.deltaY) * sensitivity)
    }

    override func rightMouseDown(with event: NSEvent) {
        lastMouseLocation = convert(event.locationInWindow, from: nil)
        isPanning = true
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        mouseUp(with: event)
    }
}
