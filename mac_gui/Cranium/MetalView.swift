import SwiftUI
import MetalKit

/// SwiftUI wrapper around MTKView that delegates rendering to the Zig Metal backend.
struct MetalSurfaceView: NSViewRepresentable {
    var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60

        // Initialize the Zig Metal renderer, passing the MTKView pointer.
        let viewPtr = Unmanaged.passUnretained(view).toOpaque()
        context.coordinator.renderer = surface_init(viewPtr)

        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.text = text
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var renderer: UnsafeMutableRawPointer?
        var text: String = ""

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer = renderer else { return }
            let size = view.drawableSize
            text.withCString { cstr in
                render_frame(
                    renderer,
                    cstr,
                    Int32(text.utf8.count),
                    Float(size.width),
                    Float(size.height)
                )
            }
        }

        deinit {
            if let renderer = renderer {
                surface_deinit(renderer)
            }
        }
    }
}
