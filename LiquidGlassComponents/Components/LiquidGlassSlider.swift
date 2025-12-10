import UIKit
import MetalKit

// MARK: - LiquidGlassSlider

final class LiquidGlassSlider: UIControl {

    // MARK: - Constants

    private enum Constants {
        static let trackHeight: CGFloat = 8
        static let thumbWidth: CGFloat = 38       // Pill shape - horizontal
        static let thumbHeight: CGFloat = 24      // Pill shape - shorter
        static let expandedScale: CGFloat = 1.5   // Scale when dragging (50% bigger)
        static let expandedThreshold: CGFloat = 1.01   // Scale > this = expanded
        static let metalThreshold: CGFloat = 1.03      // Metal shows at this scale
        static let grayThreshold: CGFloat = 1.08       // Gray hides at this scale
    }

    // MARK: - Configuration

    var configuration: LiquidGlassConfiguration = .default {
        didSet { applyConfiguration() }
    }

    // MARK: - State

    var value: CGFloat = 0.5 {
        didSet {
            value = value.clamped(to: 0...1)
            if oldValue != value {
                sendActions(for: .valueChanged)
                updateThumbPosition(animated: false)
            }
        }
    }

    var minimumTrackTintColor: UIColor = .systemBlue {
        didSet { updateTrackFill() }
    }

    // MARK: - Views

    private var trackContainer: UIView!
    private var trackBackdropLayer: CALayer?
    private var trackTintLayer: CALayer!
    private var fillLayer: CALayer!

    // Gray blob (visible when collapsed)
    private var thumbBackground: UIView!

    // Metal glass effect (visible when expanded)
    private var metalContainerView: UIView!
    private var metalView: MTKView!
    private var renderer: LiquidGlassRenderer?
    private var texturePool: IOSurfaceTexturePool?
    private var hasValidBackdrop: Bool = false

    // MARK: - Animation

    private var thumbAnimator: SpringAnimator?
    private var thumbScaleAnimator = ScaleAnimator()
    private let squashStretchAnimator = SquashStretchAnimator()
    private var displayLink: CADisplayLink?
    private var isDragging = false

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Setup

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = false  // Allow blob to overflow bounds
        setupTrack()
        setupThumbBackground()
        setupMetalView()
        setupGestures()
        setupDisplayLink()
    }

    private func setupTrack() {
        trackContainer = UIView()
        trackContainer.backgroundColor = .clear
        trackContainer.layer.cornerCurve = .continuous
        trackContainer.isUserInteractionEnabled = false
        addSubview(trackContainer)

        // Background tint
        trackTintLayer = CALayer()
        trackTintLayer.backgroundColor = configuration.tintColor.withAlphaComponent(configuration.tintOpacity).cgColor
        trackContainer.layer.addSublayer(trackTintLayer)

        // Fill layer (progress)
        fillLayer = CALayer()
        fillLayer.backgroundColor = minimumTrackTintColor.withAlphaComponent(0.7).cgColor
        trackContainer.layer.addSublayer(fillLayer)
    }

    private func setupThumbBackground() {
        // White blob background (visible when collapsed)
        thumbBackground = UIView()
        thumbBackground.backgroundColor = UIColor.white
        thumbBackground.layer.cornerCurve = .continuous
        thumbBackground.isUserInteractionEnabled = false

        // Drop shadow
        thumbBackground.layer.shadowColor = UIColor.black.cgColor
        thumbBackground.layer.shadowOffset = CGSize(width: 0, height: 2)
        thumbBackground.layer.shadowRadius = 4
        thumbBackground.layer.shadowOpacity = 0.15

        addSubview(thumbBackground)
    }

    private func setupMetalView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Metal not available")
            return
        }

        // Container for Metal view
        metalContainerView = UIView()
        metalContainerView.clipsToBounds = false
        metalContainerView.backgroundColor = .clear
        metalContainerView.isUserInteractionEnabled = false
        metalContainerView.isHidden = true  // Hidden until expanded
        addSubview(metalContainerView)

        // Metal view
        metalView = MTKView(frame: .zero, device: device)
        metalView.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.framebufferOnly = false
        metalView.preferredFramesPerSecond = configuration.preferredFPS
        metalView.isPaused = true  // Paused until expanded
        metalView.enableSetNeedsDisplay = false
        metalView.clipsToBounds = false
        metalView.isUserInteractionEnabled = false

        renderer = LiquidGlassRenderer(device: device)
        metalView.delegate = renderer

        // Create IOSurface texture pool for GPU-accelerated capture
        texturePool = IOSurfaceTexturePool(device: device)

        // Update uniforms callback
        renderer?.onUpdate = { [weak self] in
            self?.updateUniforms()
        }

        metalContainerView.addSubview(metalView)
    }

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    private func setupDisplayLink() {
        // Lower damping (18) for bouncier spring animation
        thumbAnimator = SpringAnimator(mass: 1.0, stiffness: 400, damping: 18)
        thumbAnimator?.setPosition(CGPoint(x: thumbXPosition(), y: 0), animated: false)

        // Configure scale animator with lower damping for bounce
        thumbScaleAnimator.stiffness = 400
        thumbScaleAnimator.damping = 18
        thumbScaleAnimator.setScale(1.0, animated: false)

        // Configure squash/stretch with subtle limits for slider
        squashStretchAnimator.limits = .subtle

        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        displayLink?.add(to: .main, forMode: .common)
    }

    private func setupBackdropLayers() {
        // Track backdrop only (thumb uses Metal rendering)
        trackBackdropLayer?.removeFromSuperlayer()
        trackBackdropLayer = createBackdropLayer(for: trackContainer)
    }

    private func createBackdropLayer(for container: UIView) -> CALayer? {
        guard BackdropLayerWrapper.isAvailable() else {
            let fallback = CALayer()
            fallback.frame = container.bounds
            fallback.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.4).cgColor
            fallback.cornerRadius = container.bounds.height / 2
            fallback.masksToBounds = true
            container.layer.insertSublayer(fallback, at: 0)
            return fallback
        }

        let backdrop = BackdropLayerWrapper.createBackdropLayer(
            withFrame: container.bounds,
            blurIntensity: configuration.blurIntensity * 0.7,
            saturation: configuration.saturationBoost,
            scale: configuration.blurScale
        )
        backdrop?.cornerRadius = container.bounds.height / 2
        backdrop?.masksToBounds = true
        if let backdrop = backdrop {
            container.layer.insertSublayer(backdrop, at: 0)
        }
        return backdrop
    }

    // MARK: - Layout

    override var intrinsicContentSize: CGSize {
        return CGSize(width: 200, height: Constants.thumbHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let trackY = (bounds.height - Constants.trackHeight) / 2
        let trackWidth = bounds.width - Constants.thumbWidth

        trackContainer.frame = CGRect(
            x: Constants.thumbWidth / 2,
            y: trackY,
            width: trackWidth,
            height: Constants.trackHeight
        )
        trackContainer.layer.cornerRadius = Constants.trackHeight / 2

        trackTintLayer.frame = trackContainer.bounds
        trackTintLayer.cornerRadius = Constants.trackHeight / 2

        updateTrackFill()
        updateThumbFrame()
        setupBackdropLayers()
    }

    private func updateTrackFill() {
        // Fill extends from track start to thumb CENTER (50% of blob)
        let thumbX = thumbAnimator?.current.x ?? thumbXPosition()
        let trackStartX = Constants.thumbWidth / 2
        let fillWidth = thumbX - trackStartX

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: max(0, fillWidth),
            height: trackContainer.bounds.height
        )
        fillLayer.cornerRadius = Constants.trackHeight / 2
        fillLayer.backgroundColor = minimumTrackTintColor.withAlphaComponent(0.7).cgColor
        CATransaction.commit()
    }

    private func updateThumbFrame() {
        let thumbX = thumbAnimator?.current.x ?? thumbXPosition()
        let scale = thumbScaleAnimator.current

        // Squash/stretch deformation from velocity
        let deform = CGFloat(squashStretchAnimator.normalizedVelocity.x)
        let widthMultiplier = 1.0 + deform * 0.35   // Stretch width when moving
        let heightMultiplier = 1.0 - deform * 0.35 * 0.75  // Squash height (volume preservation)

        // Apply scale and deformation to pill dimensions
        let scaledWidth = Constants.thumbWidth * scale * widthMultiplier
        let scaledHeight = Constants.thumbHeight * scale * heightMultiplier

        // Center vertically
        let thumbY = (bounds.height - scaledHeight) / 2

        let thumbFrame = CGRect(
            x: thumbX - scaledWidth / 2,
            y: thumbY,
            width: scaledWidth,
            height: scaledHeight
        )

        // Staggered visibility: gray leads, Metal follows
        let showGray = scale < Constants.grayThreshold
        let showMetal = scale > Constants.metalThreshold && hasValidBackdrop

        // Update gray background
        thumbBackground.frame = thumbFrame
        thumbBackground.layer.cornerRadius = min(scaledWidth, scaledHeight) / 2
        thumbBackground.isHidden = !showGray
        thumbBackground.alpha = showGray ? 1.0 : 0.0

        // Update Metal view
        metalContainerView?.isHidden = !showMetal
        metalView?.isPaused = !showMetal

        if showMetal {
            // Metal container covers capture area
            let captureArea = captureRect
            metalContainerView?.frame = captureArea
            metalView?.frame = metalContainerView?.bounds ?? captureArea
            updateUniformsGeometry(thumbFrame: thumbFrame)
        }

        // Update fill to match thumb center position
        updateTrackFill()
    }

    /// Capture area for backdrop (slider + padding for scaled blob overflow)
    private var captureRect: CGRect {
        let maxScaledSize = max(Constants.thumbWidth, Constants.thumbHeight) * Constants.expandedScale
        // Uniform 1.5x stretch factor for both dimensions
        let padding = (maxScaledSize * 1.5 - Constants.thumbHeight) / 2 + 10
        return bounds.insetBy(dx: -padding, dy: -padding)
    }

    private func thumbXPosition() -> CGFloat {
        let trackWidth = bounds.width - Constants.thumbWidth
        return Constants.thumbWidth / 2 + trackWidth * value
    }

    private func updateThumbPosition(animated: Bool) {
        let targetX = thumbXPosition()

        thumbAnimator?.setPosition(CGPoint(x: targetX, y: 0), animated: animated)
        if !animated {
            updateThumbFrame()
        }
    }

    // MARK: - Display Link

    @objc private func displayLinkFired() {
        thumbAnimator?.step()
        thumbScaleAnimator.step()
        squashStretchAnimator.update(deltaTime: 1.0 / 120.0)

        let positionSettled = thumbAnimator?.isSettled ?? true
        let scaleSettled = thumbScaleAnimator.isSettled
        let squashSettled = !squashStretchAnimator.isActive

        // Capture backdrop when expanding (before Metal shows)
        let willBeExpanded = thumbScaleAnimator.current > Constants.expandedThreshold
        if willBeExpanded {
            captureBackdropSnapshot()
        }

        if !positionSettled || !scaleSettled || !squashSettled {
            updateThumbFrame()
        }
    }

    // MARK: - Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        let trackWidth = bounds.width - Constants.thumbWidth
        let newValue = ((location.x - Constants.thumbWidth / 2) / trackWidth).clamped(to: 0...1)

        value = newValue
        thumbAnimator?.target = CGPoint(x: thumbXPosition(), y: 0)

        // Quick scale pop for feedback
        thumbScaleAnimator.target = Constants.expandedScale
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.thumbScaleAnimator.target = 1.0
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        let trackWidth = bounds.width - Constants.thumbWidth
        let newValue = ((location.x - Constants.thumbWidth / 2) / trackWidth).clamped(to: 0...1)

        // Update squash/stretch animator
        squashStretchAnimator.handlePan(gesture, in: self)

        switch gesture.state {
        case .began:
            isDragging = true
            // Expand blob on drag start
            thumbScaleAnimator.target = Constants.expandedScale
        case .changed:
            value = newValue
            thumbAnimator?.setPosition(CGPoint(x: thumbXPosition(), y: 0), animated: false)
            updateThumbFrame()
        case .ended, .cancelled:
            isDragging = false
            // Collapse blob on drag end
            thumbScaleAnimator.target = 1.0
        default:
            break
        }
    }

    // MARK: - Public API

    func setValue(_ newValue: CGFloat, animated: Bool) {
        let clampedValue = newValue.clamped(to: 0...1)
        if value != clampedValue {
            value = clampedValue
            if animated {
                thumbAnimator?.target = CGPoint(x: thumbXPosition(), y: 0)
            }
        }
    }

    // MARK: - Metal Uniforms

    private func updateUniforms() {
        guard let renderer = renderer else { return }
        // Zero out SDF uniforms (blob is UIKit, not shader)
        renderer.sdf1Uniforms = SdfUniforms()
        renderer.sdf2Uniforms = SdfUniforms()
    }

    private func updateUniformsGeometry(thumbFrame: CGRect) {
        guard let renderer = renderer else { return }

        let captureArea = captureRect
        guard captureArea.width > 0 && captureArea.height > 0 else { return }
        guard thumbFrame.width > 0 && thumbFrame.height > 0 else { return }

        let scale = metalView?.contentScaleFactor ?? 1.0
        let pillRadius = min(thumbFrame.width, thumbFrame.height) / 2

        // View size matches capture area
        renderer.glassUniforms.viewSize = SIMD2<Float>(
            Float(captureArea.width * scale),
            Float(captureArea.height * scale)
        )

        // Glass origin = thumb position within capture area
        let thumbOriginInCapture = CGPoint(
            x: thumbFrame.origin.x - captureArea.origin.x,
            y: thumbFrame.origin.y - captureArea.origin.y
        )
        renderer.glassUniforms.glassOrigin = SIMD2<Float>(
            Float(thumbOriginInCapture.x * scale),
            Float(thumbOriginInCapture.y * scale)
        )

        // Glass size is the thumb size
        renderer.glassUniforms.glassSize = SIMD2<Float>(
            Float(thumbFrame.width * scale),
            Float(thumbFrame.height * scale)
        )

        renderer.glassUniforms.cornerRadius = Float(pillRadius * scale)
        renderer.glassUniforms.refractionStrength = Float(configuration.refractionStrength)
        renderer.glassUniforms.specularIntensity = Float(configuration.specularIntensity)
        renderer.glassUniforms.scrollVelocity = squashStretchAnimator.normalizedVelocity
        renderer.glassUniforms.time = Float(CACurrentMediaTime())
        renderer.glassUniforms.edgeIntensity = 1.0  // Full edge effects on slider blob
    }

    // MARK: - Backdrop Capture

    private func captureBackdropSnapshot() {
        guard let superview = superview,
              let pool = texturePool,
              bounds.width > 0 && bounds.height > 0 else { return }

        let scale = metalView?.contentScaleFactor ?? 2.0
        let captureArea = captureRect

        guard let context = pool.getContext(size: captureArea.size, scale: scale) else { return }

        pool.lockForCPU()

        let captureRectInSuperview = convert(captureArea, to: superview)

        // Hide Metal and thumb background during capture
        metalContainerView?.isHidden = true
        thumbBackground?.isHidden = true

        context.saveGState()
        context.translateBy(x: -captureRectInSuperview.origin.x * scale, y: -captureRectInSuperview.origin.y * scale)
        context.scaleBy(x: scale, y: scale)
        superview.layer.render(in: context)
        context.restoreGState()

        // Restore visibility using staggered thresholds
        let thumbScale = thumbScaleAnimator.current
        let shouldShowMetal = thumbScale > Constants.metalThreshold && hasValidBackdrop
        metalContainerView?.isHidden = !shouldShowMetal
        let showGray = thumbScale < Constants.grayThreshold
        thumbBackground?.isHidden = !showGray

        pool.unlockForCPU()

        renderer?.backdropTexture = pool.getTexture()
        hasValidBackdrop = true
    }

    // MARK: - Configuration

    private func applyConfiguration() {
        let tintColor = configuration.tintColor.withAlphaComponent(configuration.tintOpacity).cgColor
        trackTintLayer?.backgroundColor = tintColor

        if let backdrop = trackBackdropLayer {
            BackdropLayerWrapper.updateBlurIntensity(configuration.blurIntensity, on: backdrop)
            BackdropLayerWrapper.updateSaturation(configuration.saturationBoost, on: backdrop)
        }
    }
}

// MARK: - Comparable Extension

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
