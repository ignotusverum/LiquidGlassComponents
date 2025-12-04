import MetalKit

/// Metal renderer for liquid glass refraction overlay
final class LiquidGlassRenderer: NSObject, MTKViewDelegate {

    // MARK: - Metal Objects

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?

    // MARK: - Uniform Buffers

    private var glassUniformsBuffer: MTLBuffer?
    private var blob1UniformsBuffer: MTLBuffer?
    private var blob2UniformsBuffer: MTLBuffer?

    // MARK: - Textures

    /// Backdrop texture (captured from CABackdropLayer or fallback)
    var backdropTexture: MTLTexture?

    // MARK: - State

    var glassUniforms = GlassUniforms()
    var blob1Uniforms = BlobUniforms()
    var blob2Uniforms = BlobUniforms()

    /// Called before each frame to update uniforms
    var onUpdate: (() -> Void)?

    // MARK: - Initialization

    init?(device: MTLDevice? = nil) {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            return nil
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = commandQueue

        super.init()

        setupPipeline()
        setupBuffers()
        setupSampler()
    }

    // MARK: - Setup

    private func setupPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            print("LiquidGlassRenderer: Failed to create default library")
            return
        }

        guard let vertexFunction = library.makeFunction(name: "liquidGlassVertex"),
              let fragmentFunction = library.makeFunction(name: "liquidGlassTabBarFragment") else {
            print("LiquidGlassRenderer: Failed to find shader functions")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Enable blending for alpha compositing over backdrop
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("LiquidGlassRenderer: Failed to create pipeline state: \(error)")
        }
    }

    private func setupBuffers() {
        let options: MTLResourceOptions = .storageModeShared

        glassUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<GlassUniforms>.size,
            options: options
        )

        blob1UniformsBuffer = device.makeBuffer(
            length: MemoryLayout<BlobUniforms>.size,
            options: options
        )

        blob2UniformsBuffer = device.makeBuffer(
            length: MemoryLayout<BlobUniforms>.size,
            options: options
        )
    }

    private func setupSampler() {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge

        samplerState = device.makeSamplerState(descriptor: descriptor)
    }

    // MARK: - Texture Creation

    /// Create a solid color texture as fallback when backdrop capture isn't available
    func createSolidColorTexture(color: UIColor, size: CGSize) -> MTLTexture? {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        // Fill with color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            pixels[i] = UInt8(b * 255)     // B
            pixels[i + 1] = UInt8(g * 255) // G
            pixels[i + 2] = UInt8(r * 255) // R
            pixels[i + 3] = UInt8(a * 255) // A
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: bytesPerRow
        )

        return texture
    }

    /// Create texture from CGImage (for backdrop capture)
    func createTexture(from cgImage: CGImage) -> MTLTexture? {
        let loader = MTKTextureLoader(device: device)
        return try? loader.newTexture(cgImage: cgImage, options: [
            .SRGB: false,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue as NSNumber
        ])
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        glassUniforms.viewSize = SIMD2<Float>(Float(size.width), Float(size.height))
    }

    private var drawCounter = 0

    func draw(in view: MTKView) {
        // Update uniforms before drawing
        onUpdate?()

        // Skip rendering if no texture available
        guard let backdropTexture = backdropTexture else {
            drawCounter += 1
            if drawCounter % 60 == 0 {
                print("[MetalRenderer] No backdrop texture - skipping render")
            }
            return
        }

        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let pipelineState = pipelineState,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            drawCounter += 1
            if drawCounter % 60 == 0 {
                print("[MetalRenderer] Missing drawable/pass/pipeline - skipping render")
            }
            return
        }

        // Clear to transparent (not black) so we composite properly over backdrop
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        drawCounter += 1
        if drawCounter % 60 == 0 {
            print("[MetalRenderer] Drawing frame \(drawCounter), texture size: \(backdropTexture.width)x\(backdropTexture.height)")
        }

        // Update uniform buffers
        updateBuffers()

        renderEncoder.setRenderPipelineState(pipelineState)

        // Set textures
        renderEncoder.setFragmentTexture(backdropTexture, index: 0)

        if let samplerState = samplerState {
            renderEncoder.setFragmentSamplerState(samplerState, index: 0)
        }

        // Set uniform buffers
        renderEncoder.setFragmentBuffer(glassUniformsBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentBuffer(blob1UniformsBuffer, offset: 0, index: 1)
        renderEncoder.setFragmentBuffer(blob2UniformsBuffer, offset: 0, index: 2)

        // Draw fullscreen quad (triangle strip, 4 vertices)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateBuffers() {
        if let buffer = glassUniformsBuffer {
            memcpy(buffer.contents(), &glassUniforms, MemoryLayout<GlassUniforms>.size)
        }

        if let buffer = blob1UniformsBuffer {
            memcpy(buffer.contents(), &blob1Uniforms, MemoryLayout<BlobUniforms>.size)
        }

        if let buffer = blob2UniformsBuffer {
            memcpy(buffer.contents(), &blob2Uniforms, MemoryLayout<BlobUniforms>.size)
        }
    }
}
