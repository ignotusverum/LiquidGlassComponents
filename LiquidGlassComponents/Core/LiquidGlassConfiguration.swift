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
    var _padding: Float = 0            // 4 bytes (offset 36)
    var scrollVelocity: SIMD2<Float>   // 8 bytes (offset 40) - for slime deformation
    var time: Float                    // 4 bytes (offset 48) - for wobble animation
    var _padding2: Float = 0           // 4 bytes (offset 52) - align to 8-byte boundary
    // Total: 56 bytes

    init() {
        viewSize = .zero
        glassOrigin = .zero
        glassSize = .zero
        cornerRadius = 0
        refractionStrength = 1.0
        specularIntensity = 0.6
        _padding = 0
        scrollVelocity = .zero
        time = 0
        _padding2 = 0
    }
}

/// Matches SdfUniforms in Shaders.metal
struct SdfUniforms {
    var position: SIMD2<Float>
    var size: SIMD2<Float>     // half-width, half-height (for pill shape)
    var intensity: Float
    var _padding: Float = 0    // alignment

    init() {
        position = .zero
        size = .zero
        intensity = 0
    }

    init(position: CGPoint, size: CGSize, intensity: CGFloat) {
        self.position = SIMD2<Float>(Float(position.x), Float(position.y))
        self.size = SIMD2<Float>(Float(size.width / 2), Float(size.height / 2))  // half-size
        self.intensity = Float(intensity)
    }
}

/// Matches TabUniforms in Shaders.metal - for unselected tab fills
struct TabUniforms {
    var positions: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>,
                    SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)  // 8 tab positions
    var count: Int32
    var selectedIndex: Int32
    var fillRadius: Float
    var fillOpacity: Float

    init() {
        positions = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
        count = 0
        selectedIndex = 0
        fillRadius = 40
        fillOpacity = 0.15
    }

    mutating func setPosition(_ index: Int, _ position: CGPoint) {
        let pos = SIMD2<Float>(Float(position.x), Float(position.y))
        switch index {
        case 0: positions.0 = pos
        case 1: positions.1 = pos
        case 2: positions.2 = pos
        case 3: positions.3 = pos
        case 4: positions.4 = pos
        case 5: positions.5 = pos
        case 6: positions.6 = pos
        case 7: positions.7 = pos
        default: break
        }
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

    /// Specular highlight intensity on SDF shapes
    var specularIntensity: CGFloat = 0.6

    // MARK: - SDF (Signed Distance Field)

    /// Default SDF radius in points
    var sdfRadius: CGFloat = 40

    /// Enable smin SDF merging during transitions
    var enableSdfMerging: Bool = true

    /// SDF intensity (affects specular brightness)
    var sdfIntensity: CGFloat = 1.0

    // MARK: - Squircle Shape

    /// Superellipse exponent for squircle shape (4.0 = iOS-style)
    var squircleExponent: CGFloat = 4.0

    // MARK: - Bold Visibility

    /// SDF fill opacity for visibility enhancement
    var sdfFillOpacity: CGFloat = 0.25

    /// SDF edge highlight intensity
    var sdfEdgeIntensity: CGFloat = 0.5

    // MARK: - Unselected Tab Fill

    /// Fill color for unselected tabs (gray tint)
    var unselectedFillColor: UIColor = .systemGray5

    /// Opacity of unselected tab fill
    var unselectedFillOpacity: CGFloat = 0.15

    /// Whether to show fills for unselected tabs
    var showUnselectedFills: Bool = true

    // MARK: - Scale Effects (Hover/Press)

    /// Scale factor when SDF is pressed
    var sdfPressedScale: CGFloat = 1.15

    /// Scale factor when SDF is being dragged
    var sdfDragScale: CGFloat = 1.4

    // MARK: - Shape

    /// Corner radius for glass container
    var cornerRadius: CGFloat = 20

    // MARK: - Spring Animation

    /// Spring mass (affects momentum)
    var springMass: CGFloat = 1.0

    /// Spring stiffness (higher = snappier)
    var springStiffness: CGFloat = 500.0

    /// Spring damping (higher = less oscillation)
    var springDamping: CGFloat = 28.0

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
        config.sdfRadius = 30
        return config
    }

    static var intense: LiquidGlassConfiguration {
        var config = LiquidGlassConfiguration()
        config.blurIntensity = 1.0
        config.refractionStrength = 2.0  // Stronger edge refraction
        config.specularIntensity = 0.8
        config.sdfRadius = 50
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
