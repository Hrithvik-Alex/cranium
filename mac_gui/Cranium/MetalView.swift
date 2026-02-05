import SwiftUI
import MetalKit

/// SwiftUI wrapper around MTKView that delegates rendering to the Zig Metal backend.
struct MetalSurfaceView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60

        // Initialize the Zig Metal renderer, passing the MTKView pointer.
        // surface_init creates the MTLDevice, command queue, and pipeline,
        // and configures the view.
        let viewPtr = Unmanaged.passUnretained(view).toOpaque()
        context.coordinator.renderer = surface_init(viewPtr)

        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    class Coordinator: NSObject, MTKViewDelegate {
        var renderer: UnsafeMutableRawPointer?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer = renderer else { return }
            render_frame(renderer)
        }

        deinit {
            if let renderer = renderer {
                surface_deinit(renderer)
            }
        }
    }
}
