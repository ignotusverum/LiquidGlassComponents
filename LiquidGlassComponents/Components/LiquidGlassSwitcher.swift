import UIKit
import MetalKit

// MARK: - LiquidGlassSwitcher

final class LiquidGlassSwitcher: UIControl {

    // MARK: - Constants

    private enum Constants {
        static let trackWidth: CGFloat = 64
        static let trackHeight: CGFloat = 28
        static let thumbWidth: CGFloat = 39
        static let thumbHeight: CGFloat = 24
        static let thumbPadding: CGFloat = 2
      static let expandedScaleX: CGFloat = 1.5  // 100% wider - extends beyond track
        static let expandedScaleY: CGFloat = 1.4  // 80% taller - extends beyond track
        static let expandedThreshold: CGFloat = 1.3
    }

    // MARK: - Configuration

    var configuration: LiquidGlassConfiguration = .default {
        didSet { applyConfiguration() }
    }

    // MARK: - State

    private(set) var isOn: Bool = false {
        didSet {
            if oldValue != isOn {
                sendActions(for: .valueChanged)
            }
        }
    }

    // MARK: - Views

    private var trackContainer: UIView!
    private var trackBackdropLayer: CALayer?
    private var trackTintLayer: CALayer!
    private var trackEdgeLayer: CAGradientLayer!

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
    private var pendingCollapseWork: DispatchWorkItem?

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
        trackContainer.clipsToBounds = false  // Allow blob to overflow
        trackContainer.isUserInteractionEnabled = false
        addSubview(trackContainer)

        trackTintLayer = CALayer()
        trackTintLayer.backgroundColor = configuration.tintColor.withAlphaComponent(configuration.tintOpacity).cgColor
        trackContainer.layer.addSublayer(trackTintLayer)

        // Edge highlight for glass effect
        trackEdgeLayer = CAGradientLayer()
        trackEdgeLayer.colors = [
            UIColor.white.withAlphaComponent(0.4).cgColor,
            UIColor.white.withAlphaComponent(0.1).cgColor,
            UIColor.clear.cgColor
        ]
        trackEdgeLayer.locations = [0, 0.3, 1]
        trackEdgeLayer.startPoint = CGPoint(x: 0, y: 0)
        trackEdgeLayer.endPoint = CGPoint(x: 1, y: 1)
        trackContainer.layer.addSublayer(trackEdgeLayer)
    }

    private func setupThumbBackground() {
        // Gray blob background (visible when collapsed)
        thumbBackground = UIView()
        thumbBackground.backgroundColor = UIColor.gray.withAlphaComponent(0.3)
        thumbBackground.layer.cornerCurve = .continuous
        thumbBackground.isUserInteractionEnabled = false
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
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    private func setupDisplayLink() {
        // Lower damping (18) for bouncier spring animation
        thumbAnimator = SpringAnimator(mass: 1.0, stiffness: 400, damping: 18)
        thumbAnimator?.setPosition(CGPoint(x: thumbXPosition(for: isOn), y: 0), animated: false)

        // Configure scale animator with lower damping for bounce
        thumbScaleAnimator.stiffness = 400
        thumbScaleAnimator.damping = 18
        thumbScaleAnimator.setScale(1.0, animated: false)

        // Configure squash/stretch with subtle limits for switcher
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
            fallback.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.5).cgColor
            fallback.cornerRadius = container.bounds.height / 2
            fallback.masksToBounds = true
            container.layer.insertSublayer(fallback, at: 0)
            return fallback
        }

        let backdrop = BackdropLayerWrapper.createBackdropLayer(
            withFrame: container.bounds,
            blurIntensity: configuration.blurIntensity,
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
        return CGSize(width: Constants.trackWidth, height: Constants.trackHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let trackFrame = CGRect(
            x: (bounds.width - Constants.trackWidth) / 2,
            y: (bounds.height - Constants.trackHeight) / 2,
            width: Constants.trackWidth,
            height: Constants.trackHeight
        )
        trackContainer.frame = trackFrame
        trackContainer.layer.cornerRadius = Constants.trackHeight / 2

        trackTintLayer.frame = trackContainer.bounds
        trackTintLayer.cornerRadius = Constants.trackHeight / 2

        // Edge layer with border mask
        trackEdgeLayer.frame = trackContainer.bounds
        trackEdgeLayer.cornerRadius = Constants.trackHeight / 2
        trackEdgeLayer.masksToBounds = true

        // Create border mask for edge highlight
        let borderMask = CAShapeLayer()
        borderMask.lineWidth = 1.5
        borderMask.fillColor = nil
        borderMask.strokeColor = UIColor.white.cgColor
        borderMask.path = UIBezierPath(
            roundedRect: trackContainer.bounds.insetBy(dx: 0.75, dy: 0.75),
            cornerRadius: Constants.trackHeight / 2 - 0.75
        ).cgPath
        trackEdgeLayer.mask = borderMask

        // Position thumb
        updateThumbFrame()

        setupBackdropLayers()
    }

    private func updateThumbFrame() {
        let thumbX = thumbAnimator?.current.x ?? thumbXPosition(for: isOn)
        let trackFrame = trackContainer.frame
        let animatorScale = thumbScaleAnimator.current

        // Asymmetric scaling: X is primary (larger), Y interpolates
        let progress = (animatorScale - 1.0) / (Constants.expandedScaleX - 1.0)
        let scaleX = animatorScale
        let scaleY = 1.0 + progress * (Constants.expandedScaleY - 1.0)

        // Squash/stretch deformation from velocity
        let deform = CGFloat(squashStretchAnimator.normalizedVelocity.x)
        let widthMultiplier = 1.0 + deform * 0.35
        let heightMultiplier = 1.0 - deform * 0.35 * 0.75

        // Apply asymmetric scale and deformation
        let scaledWidth = Constants.thumbWidth * scaleX * widthMultiplier
        let scaledHeight = Constants.thumbHeight * scaleY * heightMultiplier

        // Center vertically in track
        let thumbY = trackFrame.minY + (trackFrame.height - scaledHeight) / 2

        let thumbFrame = CGRect(
            x: trackFrame.minX + thumbX - (scaledWidth - Constants.thumbWidth) / 2,
            y: thumbY,
            width: scaledWidth,
            height: scaledHeight
        )

        // Single threshold for visibility
        let isExpanded = animatorScale > Constants.expandedThreshold
        let showGray = !isExpanded
        let showMetal = isExpanded && hasValidBackdrop

        // Update gray background
        thumbBackground.frame = thumbFrame
        thumbBackground.layer.cornerRadius = scaledHeight / 2
        thumbBackground.isHidden = !showGray
        thumbBackground.alpha = showGray ? 1.0 : 0.0

        // Animate track background color based on knob X position
        let minX = Constants.thumbPadding
        let maxX = Constants.trackWidth - Constants.thumbWidth - Constants.thumbPadding
        let colorProgress = max(0, min(1, (thumbX - minX) / (maxX - minX)))
        let grayColor = UIColor.white.withAlphaComponent(0.1)
        let greenColor = UIColor.systemGreen.withAlphaComponent(0.6)
        // Blend colors based on progress
        let blendedColor = UIColor(
            red: (1 - colorProgress) * 1.0 + colorProgress * 0.2,
            green: (1 - colorProgress) * 1.0 + colorProgress * 0.8,
            blue: (1 - colorProgress) * 1.0 + colorProgress * 0.2,
            alpha: (1 - colorProgress) * 0.1 + colorProgress * 0.6
        )
        trackTintLayer.backgroundColor = blendedColor.cgColor

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
    }

    /// Capture area for backdrop (switcher + padding for scaled blob overflow)
    private var captureRect: CGRect {
        let maxScaledSize = max(Constants.thumbWidth * Constants.expandedScaleX, Constants.thumbHeight * Constants.expandedScaleY)
        // Uniform 50% (1.5x) stretch factor for both dimensions
        let padding = (maxScaledSize * 1.5 - Constants.thumbHeight) / 2 + 10
        return bounds.insetBy(dx: -padding, dy: -padding)
    }

    private func thumbXPosition(for state: Bool) -> CGFloat {
        if state {
            return Constants.trackWidth - Constants.thumbWidth - Constants.thumbPadding
        } else {
            return Constants.thumbPadding
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
        // Cancel any pending collapse
        pendingCollapseWork?.cancel()

        // Expand blob
        thumbScaleAnimator.target = Constants.expandedScaleX

        // Toggle state and move to new position
        isOn = !isOn
        let targetX = thumbXPosition(for: isOn)
        thumbAnimator?.target = CGPoint(x: targetX, y: 0)

        // Schedule collapse
        scheduleCollapse(delay: 0.2)

        // Track color updates continuously via updateThumbFrame
    }

    private func scheduleCollapse(delay: TimeInterval) {
        pendingCollapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.thumbScaleAnimator.target = 1.0
        }
        pendingCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: trackContainer)
        let progress = (location.x / Constants.trackWidth).clamped(to: 0...1)

        // Update squash/stretch animator
        squashStretchAnimator.handlePan(gesture, in: self)

        switch gesture.state {
        case .began:
            // Expand on drag start
            pendingCollapseWork?.cancel()
            thumbScaleAnimator.target = Constants.expandedScaleX
        case .changed:
            let targetX = Constants.thumbPadding + progress * (Constants.trackWidth - Constants.thumbWidth - Constants.thumbPadding * 2)
            thumbAnimator?.target = CGPoint(x: targetX, y: 0)
        case .ended, .cancelled:
            let shouldBeOn = progress > 0.5
            isOn = shouldBeOn
            let targetX = thumbXPosition(for: shouldBeOn)
            thumbAnimator?.target = CGPoint(x: targetX, y: 0)
            // Track color updates continuously via updateThumbFrame
            // Collapse after drag ends
            scheduleCollapse(delay: 0.2)
        default:
            break
        }
    }

    // MARK: - Public API

    func setOn(_ on: Bool, animated: Bool) {
        isOn = on
        let targetX = thumbXPosition(for: on)

        if animated {
            // Cancel pending collapse and do expand/collapse animation
            pendingCollapseWork?.cancel()
            thumbScaleAnimator.target = Constants.expandedScaleX
            thumbAnimator?.target = CGPoint(x: targetX, y: 0)
            scheduleCollapse(delay: 0.2)
        } else {
            thumbAnimator?.setPosition(CGPoint(x: targetX, y: 0), animated: false)
            thumbScaleAnimator.setScale(1.0, animated: false)
            updateThumbFrame()
        }
        // Track color updates continuously via updateThumbFrame
    }

    func toggle() {
        setOn(!isOn, animated: true)
    }

    // MARK: - Visual Updates
    // Track tint color is now updated continuously in updateThumbFrame() based on knob position

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
        let pillRadius = thumbFrame.height / 2

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

        // Restore visibility using single threshold
        let thumbScale = thumbScaleAnimator.current
        let isExpanded = thumbScale > Constants.expandedThreshold
        metalContainerView?.isHidden = !(isExpanded && hasValidBackdrop)
        thumbBackground?.isHidden = isExpanded

        pool.unlockForCPU()

        renderer?.backdropTexture = pool.getTexture()
        hasValidBackdrop = true
    }

    // MARK: - Configuration

    private func applyConfiguration() {
        let tintColor = configuration.tintColor.withAlphaComponent(configuration.tintOpacity).cgColor
        if !isOn {
            trackTintLayer?.backgroundColor = tintColor
        }

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
