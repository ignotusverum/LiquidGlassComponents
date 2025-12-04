import Metal
import CoreVideo
import IOSurface

/// Manages an IOSurface-backed CGContext for efficient layer capture
/// The IOSurface is shared between CPU (CGContext) and GPU (MTLTexture) with zero copies
final class IOSurfaceTexturePool {

    private let device: MTLDevice
    private var surface: IOSurfaceRef?
    private var texture: MTLTexture?
    private var context: CGContext?
    private var currentSize: CGSize = .zero

    init(device: MTLDevice) {
        self.device = device
    }

    /// Get the CGContext backed by IOSurface. Call this before rendering.
    /// - Parameters:
    ///   - size: Size in points
    ///   - scale: Screen scale factor
    /// - Returns: CGContext that renders directly to GPU-accessible memory
    func getContext(size: CGSize, scale: CGFloat) -> CGContext? {
        let pixelSize = CGSize(
            width: ceil(size.width * scale),
            height: ceil(size.height * scale)
        )

        // Recreate if size changed
        if pixelSize != currentSize || context == nil {
            createSurface(size: pixelSize)
        }

        return context
    }

    /// Get the MTLTexture backed by the same IOSurface (zero-copy!)
    func getTexture() -> MTLTexture? {
        return texture
    }

    private func createSurface(size: CGSize) {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0 && height > 0 else { return }

        // Calculate bytes per row with proper alignment (16-byte for Metal)
        let bytesPerPixel = 4
        let alignment = 16
        let bytesPerRow = ((width * bytesPerPixel + alignment - 1) / alignment) * alignment

        // IOSurface properties
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: bytesPerPixel,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA
        ]

        guard let newSurface = IOSurfaceCreate(properties as CFDictionary) else {
            print("[IOSurfaceTexturePool] Failed to create IOSurface \(width)x\(height)")
            return
        }

        // Lock for CPU access
        IOSurfaceLock(newSurface, [], nil)

        // Create CGContext backed by IOSurface memory
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // BGRA with premultiplied alpha, little endian (matches MTLPixelFormatBGRA8Unorm)
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard let newContext = CGContext(
            data: IOSurfaceGetBaseAddress(newSurface),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: IOSurfaceGetBytesPerRow(newSurface),
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            print("[IOSurfaceTexturePool] Failed to create CGContext")
            IOSurfaceUnlock(newSurface, [], nil)
            return
        }

        // Flip coordinate system for UIKit (origin at top-left)
        newContext.translateBy(x: 0, y: CGFloat(height))
        newContext.scaleBy(x: 1, y: -1)

        IOSurfaceUnlock(newSurface, [], nil)

        // Create MTLTexture from same IOSurface (zero-copy!)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared

        guard let newTexture = device.makeTexture(
            descriptor: desc,
            iosurface: newSurface,
            plane: 0
        ) else {
            print("[IOSurfaceTexturePool] Failed to create MTLTexture from IOSurface")
            return
        }

        // Store new resources
        self.surface = newSurface
        self.context = newContext
        self.texture = newTexture
        self.currentSize = size

        print("[IOSurfaceTexturePool] Created \(width)x\(height) IOSurface + texture")
    }

    /// Lock IOSurface for CPU rendering. Call before layer.render(in:)
    func lockForCPU() {
        if let surface = surface {
            IOSurfaceLock(surface, [], nil)
        }
    }

    /// Unlock IOSurface after CPU rendering. Call after layer.render(in:)
    func unlockForCPU() {
        if let surface = surface {
            IOSurfaceUnlock(surface, [], nil)
        }
    }
}
