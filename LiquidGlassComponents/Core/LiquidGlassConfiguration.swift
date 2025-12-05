import UIKit
import simd

// MARK: - Metal Uniform Structs

/// Matches GlassUniforms in Shaders.metal
/// Metal aligns structs to 8-byte boundaries, so we need explicit padding
struct GlassUniforms {
    var viewSize: SIMD2<Float>         // 8 bytes (offset 0)
    var glassOrigin: SIMD2<Float>      // 8 bytes (offset 8)
    var glassSize: SIMD2<Float>        // 8 bytes (offset 16)
    var cornerRadius: Float            // 4 bytes (offset 24)
    var refractionStrength: Float      // 4 bytes (offset 28)
    var specularIntensity: Float       // 4 bytes (offset 32)
    var _padding: Float = 0            // 4 bytes (offset 36) - align to 8-byte boundary
    // Total: 40 bytes

    init() {
        viewSize = .zero
        glassOrigin = .zero
        glassSize = .zero
        cornerRadius = 0
        refractionStrength = 1.0
        specularIntensity = 0.6
        _padding = 0
    }
}

/// Matches BlobUniforms in Shaders.metal
struct BlobUniforms {
    var position: SIMD2<Float>
    var radius: Float
    var intensity: Float

    init() {
        position = .zero
        radius = 0
        intensity = 0
    }

    init(position: CGPoint, radius: CGFloat, intensity: CGFloat) {
        self.position = SIMD2<Float>(Float(position.x), Float(position.y))
        self.radius = Float(radius)
        self.intensity = Float(intensity)
    }
}

// MARK: - Configuration

/// Configuration for liquid glass components
struct LiquidGlassConfiguration {

    // MARK: - Blur (CABackdropLayer)

    /// Blur intensity from 0 to 1 (multiplied by 30 for actual radius)
    var blurIntensity: CGFloat = 1.0

    /// Color saturation boost (1.0 = normal, 1.4 = Apple's default boost)
    var saturationBoost: CGFloat = 1.4

    /// Tint color overlay
    var tintColor: UIColor = .white

    /// Tint overlay opacity
    var tintOpacity: CGFloat = 0.1

    // MARK: - Refraction (Metal)

    /// Refraction distortion strength (controls edge pixel pulling)
    var refractionStrength: CGFloat = 5.0

    /// Specular highlight intensity on blobs
    var specularIntensity: CGFloat = 0.6

    // MARK: - Blob

    /// Default blob radius in points
    var blobRadius: CGFloat = 40

    /// Enable smin blob merging during transitions
    var enableBlobMerging: Bool = true

    /// Blob intensity (affects specular brightness)
    var blobIntensity: CGFloat = 1.0

    // MARK: - Shape

    /// Corner radius for glass container
    var cornerRadius: CGFloat = 20

    // MARK: - Spring Animation

    /// Spring mass (affects momentum)
    var springMass: CGFloat = 1.0

    /// Spring stiffness (higher = snappier)
    var springStiffness: CGFloat = 300.0

    /// Spring damping (higher = less oscillation)
    var springDamping: CGFloat = 20.0

    // MARK: - Performance

    /// Blur render scale (0.5 = half resolution for performance)
    var blurScale: CGFloat = 0.5

    /// Target frame rate for Metal rendering
    var preferredFPS: Int = 120

    // MARK: - Accessibility

    /// Disable animations when Reduce Motion is enabled
    var respectsReduceMotion: Bool = true

    // MARK: - Presets

    static let `default` = LiquidGlassConfiguration()

    static var subtle: LiquidGlassConfiguration {
        var config = LiquidGlassConfiguration()
        config.blurIntensity = 0.6
        config.refractionStrength = 0.5
        config.specularIntensity = 0.3
        config.blobRadius = 30
        return config
    }

    static var intense: LiquidGlassConfiguration {
        var config = LiquidGlassConfiguration()
        config.blurIntensity = 1.0
        config.refractionStrength = 2.0  // Stronger edge refraction
        config.specularIntensity = 0.8
        config.blobRadius = 50
        return config
    }
}

// MARK: - Tab Bar Item

/// Represents a single item in the liquid glass tab bar
struct LiquidGlassTabItem {
    var icon: UIImage
    var title: String
    var badgeValue: String?

    init(icon: UIImage, title: String, badgeValue: String? = nil) {
        self.icon = icon
        self.title = title
        self.badgeValue = badgeValue
    }
}
