import MetalKit
import SwiftUI

/// Displays the newest frame from a `FrameBuffer` with nearest-neighbor scaling.
struct ScreenView: UIViewRepresentable {
    let frameBuffer: FrameBuffer

    func makeCoordinator() -> ScreenRenderer {
        ScreenRenderer(frameBuffer: frameBuffer)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isOpaque = true
        view.backgroundColor = .black
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

final class ScreenRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let frameBuffer: FrameBuffer
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState?
    /// Rotated per draw so the CPU never writes a texture the GPU may still read.
    private var textures: [MTLTexture] = []
    private var textureIndex = 0

    init(frameBuffer: FrameBuffer) {
        self.frameBuffer = frameBuffer
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()

        let library = Self.makeLibrary(device: device)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library?.makeFunction(name: "screen_vertex")
        descriptor.fragmentFunction = library?.makeFunction(name: "screen_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device?.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device?.makeSamplerState(descriptor: samplerDescriptor)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: FrameBuffer.width,
            height: FrameBuffer.height,
            mipmapped: false
        )
        textureDescriptor.usage = .shaderRead
        for _ in 0..<3 {
            if let texture = device?.makeTexture(descriptor: textureDescriptor) {
                textures.append(texture)
            }
        }
        super.init()
    }

    /// Shaders.metal ships as a resource and is compiled at runtime, so the
    /// project builds without the optional Metal Toolchain component.
    private static func makeLibrary(device: MTLDevice?) -> MTLLibrary? {
        guard let device,
              let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            print("ScreenRenderer: shader compilation failed: \(error)")
            return nil
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline, let sampler, !textures.isEmpty,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        textureIndex = (textureIndex + 1) % textures.count
        let texture = textures[textureIndex]
        texture.replace(
            region: MTLRegionMake2D(0, 0, FrameBuffer.width, FrameBuffer.height),
            mipmapLevel: 0,
            withBytes: frameBuffer.acquireLatest().pixels,
            bytesPerRow: FrameBuffer.bytesPerRow
        )

        encoder.setViewport(Self.viewport(for: view.drawableSize))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Largest 10:9 rectangle centered in the drawable, snapped to an integer
    /// scale unless that would waste more than 20% of the available size.
    static func viewport(for size: CGSize) -> MTLViewport {
        let width = Double(FrameBuffer.width)
        let height = Double(FrameBuffer.height)
        let fit = min(size.width / width, size.height / height)
        let integer = fit.rounded(.down)
        let scale = integer >= 1 && integer >= fit * 0.8 ? integer : fit
        let w = width * scale
        let h = height * scale
        return MTLViewport(
            originX: ((size.width - w) / 2).rounded(.down),
            originY: ((size.height - h) / 2).rounded(.down),
            width: w,
            height: h,
            znear: 0,
            zfar: 1
        )
    }
}
