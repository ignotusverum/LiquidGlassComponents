import UIKit
import MetalKit

// MARK: - Delegate Protocol

protocol LiquidGlassTabBarDelegate: AnyObject {
    func tabBar(_ tabBar: LiquidGlassTabBar, didSelectItemAt index: Int)
    func tabBar(_ tabBar: LiquidGlassTabBar, didDoubleTapItemAt index: Int)
}

// MARK: - LiquidGlassTabBar

final class LiquidGlassTabBar: UIView, UIGestureRecognizerDelegate {

    // MARK: - Constants

    private enum Constants {
        static let blobVerticalPadding: CGFloat = 4
        static let blobWidthMultiplier: CGFloat = 0.95      // Base width as % of tab width
        static let expandedThreshold: CGFloat = 1.01        // Scale > this = expanded
    }

    // MARK: - Public Properties

    var items: [LiquidGlassTabItem] = [] {
        didSet { rebuildTabButtons() }
    }

    private(set) var selectedIndex: Int = 0

    weak var delegate: LiquidGlassTabBarDelegate?

    var configuration: LiquidGlassConfiguration = .default {
        didSet { applyConfiguration() }
    }

    // MARK: - Private Layers

    private var backdropLayer: CALayer?
    private var tintLayer: CALayer!
    private var metalContainerView: UIView!
    private var metalView: MTKView!
    private var edgeLayer: CAGradientLayer!
    private var contentView: UIView!              // Unselected tabs (bottom)
    private var maskedContentView: UIView!        // Selected tabs (masked by blob)

    // MARK: - UIKit Blob (Selection Highlight Mask)

    private var blobBackgroundView: UIView!       // Visible gray background
    private var blobView: UIView!                 // Mask shape for maskedContentView
    private let blobAnimator = SpringAnimator()
    private let blobScaleAnimator = ScaleAnimator()
    private var maskedTabButtons: [UIButton] = []

    // MARK: - IOSurface Texture Pool (GPU-accelerated capture)

    private var texturePool: IOSurfaceTexturePool?

    // MARK: - Metal

    private var renderer: LiquidGlassRenderer?

    // MARK: - Animation

    private var displayLink: CADisplayLink?

    // MARK: - Tab Buttons

    private var tabButtons: [UIButton] = []

    // MARK: - Touch/Drag State

    private var isTouching: Bool = false
    private var isDragging: Bool = false

    // MARK: - Squash & Stretch

    private let squashStretchAnimator = SquashStretchAnimator()

    // MARK: - Double Tap Detection

    private var lastTapTime: TimeInterval = 0
    private var lastTappedIndex: Int = -1

    // MARK: - Selection Colors

    private let selectedColor: UIColor = .label
    private let unselectedColor: UIColor = .secondaryLabel

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
        clipsToBounds = false
        layer.cornerCurve = .continuous

        setupBackdropLayer()
        setupTintLayer()
        setupMetalView()
        setupEdgeLayer()
        setupContentView()
        setupMaskedContentView()  // Selected tabs masked by blob
        setupDisplayLink()
        setupGestures()

        // Bring Metal to front so refracted content shows on top of UIKit icons
        if let metal = metalContainerView {
            bringSubviewToFront(metal)
        }

        // Configure animators
        blobAnimator.configure(with: configuration)

        applyConfiguration()
    }

    private func setupBackdropLayer() {
        guard BackdropLayerWrapper.isAvailable() else {
            print("CABackdropLayer not available, using fallback")
            return
        }

        backdropLayer = BackdropLayerWrapper.createBackdropLayer(
            withFrame: bounds,
            blurIntensity: configuration.blurIntensity,
            saturation: configuration.saturationBoost,
            scale: configuration.blurScale
        )

        if let backdrop = backdropLayer {
            backdrop.cornerRadius = configuration.cornerRadius
            backdrop.masksToBounds = true
            layer.insertSublayer(backdrop, at: 0)
        }
    }

    private func setupTintLayer() {
        tintLayer = CALayer()
        tintLayer.backgroundColor = configuration.tintColor.withAlphaComponent(configuration.tintOpacity).cgColor
        tintLayer.cornerRadius = configuration.cornerRadius
        tintLayer.masksToBounds = true
        layer.addSublayer(tintLayer)
    }

    private func setupMaskedContentView() {
        // Visible blob background (gray pill)
        blobBackgroundView = UIView()
        blobBackgroundView.backgroundColor = UIColor.gray.withAlphaComponent(0.3)
        blobBackgroundView.layer.cornerCurve = .continuous
        blobBackgroundView.isUserInteractionEnabled = false
        addSubview(blobBackgroundView)

        // Blob view acts as mask shape (invisible)
        blobView = UIView()
        blobView.backgroundColor = .white  // Solid color for mask
        blobView.layer.cornerCurve = .continuous

        // Masked container - selected tabs visible through blob mask
        maskedContentView = UIView()
        maskedContentView.backgroundColor = .clear
        maskedContentView.isUserInteractionEnabled = false
        maskedContentView.mask = blobView  // Blob clips this view
        addSubview(maskedContentView)
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
        addSubview(metalContainerView)

        // Metal view
        metalView = MTKView(frame: .zero, device: device)
        metalView.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.framebufferOnly = false
        metalView.preferredFramesPerSecond = configuration.preferredFPS
        metalView.isPaused = false
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

    private func setupEdgeLayer() {
        edgeLayer = CAGradientLayer()
        edgeLayer.colors = [
            UIColor.white.withAlphaComponent(0.4).cgColor,
            UIColor.white.withAlphaComponent(0.1).cgColor,
            UIColor.clear.cgColor
        ]
        edgeLayer.locations = [0, 0.3, 1]
        edgeLayer.startPoint = CGPoint(x: 0, y: 0)
        edgeLayer.endPoint = CGPoint(x: 1, y: 1)
        edgeLayer.cornerRadius = configuration.cornerRadius
        edgeLayer.masksToBounds = true

        // Create border mask
        let borderMask = CAShapeLayer()
        borderMask.lineWidth = 2
        borderMask.fillColor = nil
        borderMask.strokeColor = UIColor.white.cgColor
        edgeLayer.mask = borderMask

        layer.addSublayer(edgeLayer)
    }

    private func setupContentView() {
        contentView = UIView()
        contentView.backgroundColor = .clear
        contentView.isUserInteractionEnabled = false
        addSubview(contentView)
    }

    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(animationTick))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120)
        displayLink?.add(to: .main, forMode: .common)
    }

    private func setupGestures() {
        // Long press with 0 duration to detect touch down immediately
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0
        longPress.delegate = self
        addGestureRecognizer(longPress)

        // Pan for dragging
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)

        // Tap for instant selection
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    // MARK: - UIGestureRecognizerDelegate

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow long press + pan to work together
        return true
    }

    // MARK: - Long Press (Touch Down Detection)

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            // Scale up with animation for seamless expand/collapse
            isTouching = true
            blobScaleAnimator.setScale(configuration.sdfDragScale, animated: true)
            // animationTick handles frame updates

        case .ended, .cancelled:
            isTouching = false
            // Selection is handled by handleTap - don't duplicate here
            // animationTick will shrink when blob settles

        default:
            break
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        // Pill shape: corner radius = half height
        let pillRadius = bounds.height / 2

        // Update main layer corner radius
        layer.cornerRadius = pillRadius

        backdropLayer?.frame = bounds
        backdropLayer?.cornerRadius = pillRadius

        tintLayer?.frame = bounds
        tintLayer?.cornerRadius = pillRadius

        // Metal container follows blob (updated in updateBlobFrame)

        edgeLayer?.frame = bounds
        edgeLayer?.cornerRadius = pillRadius

        contentView?.frame = bounds
        maskedContentView?.frame = bounds

        // Update edge mask path with pill radius
        if let mask = edgeLayer?.mask as? CAShapeLayer {
            let path = UIBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                cornerRadius: pillRadius - 1
            )
            mask.path = path.cgPath
        }

        layoutTabButtons()
        layoutBlobView()
        updateUniformsGeometry()

        // Capture initial texture if we don't have one yet
        if bounds.width > 0 && bounds.height > 0 {
            DispatchQueue.main.async { [weak self] in
                if self?.renderer?.backdropTexture == nil {
                    self?.captureBackdropSnapshot()
                }
            }
        }
    }

    private func layoutTabButtons() {
        guard !tabButtons.isEmpty else { return }

        let tabWidth = bounds.width / CGFloat(tabButtons.count)
        let tabHeight = bounds.height

        for (index, button) in tabButtons.enumerated() {
            let frame = CGRect(
                x: CGFloat(index) * tabWidth,
                y: 0,
                width: tabWidth,
                height: tabHeight
            )
            button.frame = frame

            // Layout corresponding masked button at same position
            if index < maskedTabButtons.count {
                maskedTabButtons[index].frame = frame
            }
        }

        // Initialize blob position only on first layout (when position is unset)
        if blobAnimator.current == .zero && !items.isEmpty {
            let center = centerForTab(at: selectedIndex)
            blobAnimator.setPosition(center, animated: false)
        }

        // Reset animator timing to prevent stale delta time after layout changes
        blobAnimator.resetTiming()
        blobScaleAnimator.resetTiming()
    }

    private func layoutBlobView() {
        updateBlobFrame()
    }

    private func updateBlobFrame() {
        guard !tabButtons.isEmpty else { return }

        let tabWidth = tabButtons[0].frame.width
        let blobScale = blobScaleAnimator.current
        let baseHeight = bounds.height - Constants.blobVerticalPadding
        let baseWidth = tabWidth * Constants.blobWidthMultiplier

        // Blob size - uniform scale for both width and height
        let isExpanded = blobScale > Constants.expandedThreshold
        let width = baseWidth * blobScale
        let height = baseHeight * blobScale

        // Blob position (X from animator, Y locked to center)
        let center = CGPoint(x: blobAnimator.current.x, y: bounds.midY)
        let frame = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )

        // Toggle between glass effect (expanded) and flat gray (collapsed)
        blobBackgroundView.isHidden = isExpanded
        metalContainerView?.isHidden = !isExpanded
        metalView?.isPaused = !isExpanded
        maskedContentView?.isHidden = false  // Always visible - mask handles clipping

        // Update both blob views
        blobBackgroundView.frame = frame
        blobBackgroundView.layer.cornerRadius = height / 2

        blobView.frame = frame
        blobView.layer.cornerRadius = height / 2

        // Update Metal view to cover capture area (tab bar + padding for blob overflow)
        if isExpanded {
            let captureArea = captureRect
            metalContainerView?.frame = captureArea
            metalView?.frame = metalContainerView?.bounds ?? captureArea

            // Update uniforms with blob position within capture area
            updateUniformsGeometry(blobFrame: frame)
        }
    }

    // MARK: - Tab Buttons

    private func rebuildTabButtons() {
        // Remove existing
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        maskedTabButtons.forEach { $0.removeFromSuperview() }
        maskedTabButtons.removeAll()

        // Create unselected buttons (bottom layer)
        for (index, item) in items.enumerated() {
            let button = createTabButton(item: item, index: index, forMaskedLayer: false)
            contentView.addSubview(button)
            tabButtons.append(button)
        }

        // Create selected buttons (masked layer - visible through blob)
        for (index, item) in items.enumerated() {
            let button = createTabButton(item: item, index: index, forMaskedLayer: true)
            maskedContentView.addSubview(button)
            maskedTabButtons.append(button)
        }

        // Initialize blob position
        if !items.isEmpty {
            let center = centerForTab(at: selectedIndex)
            blobAnimator.setPosition(center, animated: false)
            blobScaleAnimator.setScale(1.0, animated: false)
        }

        setNeedsLayout()
    }

    private func createTabButton(item: LiquidGlassTabItem, index: Int, forMaskedLayer: Bool = false) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = item.icon.withRenderingMode(.alwaysTemplate)
        config.title = item.title
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = forMaskedLayer ? selectedColor : unselectedColor

        let button = UIButton(configuration: config)
        button.tag = index
        button.isUserInteractionEnabled = false  // Gestures handle interaction
        button.configurationUpdateHandler = nil

        return button
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Ignore taps during drag
        guard !isDragging else { return }

        let location = gesture.location(in: self)
        let index = indexOfNearestTab(to: location)
        let now = CACurrentMediaTime()

        // Double-tap detection
        if index == selectedIndex &&
           index == lastTappedIndex &&
           (now - lastTapTime) < 0.3 {
            delegate?.tabBar(self, didDoubleTapItemAt: index)
            lastTapTime = 0
            lastTappedIndex = -1
            return
        }

        lastTapTime = now
        lastTappedIndex = index
        selectTab(at: index, animated: true)
    }

    // MARK: - Pan Gesture (Drag to Switch Tabs)

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        // Lock Y to vertical center, clamp X to valid tab range
        let clampedPosition = CGPoint(x: clampedX(location.x), y: bounds.midY)

        // Update squash/stretch animator
        squashStretchAnimator.handlePan(gesture, in: self)

        switch gesture.state {
        case .began:
            isDragging = true
            // Animate to finger position (spring follow)
            blobAnimator.target = clampedPosition
            blobScaleAnimator.setScale(configuration.sdfDragScale, animated: true)
            // animationTick handles frame updates

        case .changed:
            // Spring follow finger position
            blobAnimator.target = clampedPosition
            // animationTick handles frame updates

        case .ended, .cancelled:
            isDragging = false
            // Snap to nearest tab (stays expanded during animation, shrinks when settled)
            let nearestIndex = indexOfNearestTab(to: location)
            selectTab(at: nearestIndex, animated: true)

        default:
            break
        }
    }

    private func indexOfNearestTab(to point: CGPoint) -> Int {
        guard !tabButtons.isEmpty else { return 0 }

        var nearestIndex = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude

        for (index, button) in tabButtons.enumerated() {
            let distance = abs(button.center.x - point.x)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = index
            }
        }

        return nearestIndex
    }

    // MARK: - Selection

    func selectTab(at index: Int, animated: Bool) {
        guard index >= 0 && index < items.count else { return }

        selectedIndex = index

        // Scale up during animation
        if animated {
            blobScaleAnimator.setScale(configuration.sdfDragScale, animated: true)
        }

        // Animate blob to selected tab
        let center = centerForTab(at: index)
        blobAnimator.target = center
        if !animated {
            blobAnimator.setPosition(center, animated: false)
        }

        delegate?.tabBar(self, didSelectItemAt: index)
    }

    // MARK: - Animation

    @objc private func animationTick() {
        // Update squash/stretch animator (spring physics)
        squashStretchAnimator.update(deltaTime: 1.0 / 120.0)

        let needsUpdate = !blobAnimator.isSettled || !blobScaleAnimator.isSettled || isDragging || squashStretchAnimator.isActive

        // Only step and update when animation is active
        if needsUpdate {
            blobAnimator.step()
            blobScaleAnimator.step()
            updateBlobFrame()
        }

        // Shrink when blob stops moving AND not touching/dragging
        if !isDragging && !isTouching && blobAnimator.isSettled && blobScaleAnimator.current > Constants.expandedThreshold {
            blobScaleAnimator.setScale(1.0, animated: true)
        }

        // Only capture backdrop when expanded (glass effect active)
        let isExpanded = blobScaleAnimator.current > Constants.expandedThreshold
        if isExpanded {
            captureBackdropSnapshot()
        }
    }

    // MARK: - Helpers

    private func centerForTab(at index: Int) -> CGPoint {
        guard index >= 0 && index < tabButtons.count else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        return tabButtons[index].center
    }

    // MARK: - Metal Uniforms

    private func updateUniforms() {
        guard let renderer = renderer else { return }

        // Zero out SDF uniforms (blob is UIKit, not shader)
        renderer.sdf1Uniforms = SdfUniforms()
        renderer.sdf2Uniforms = SdfUniforms()
        renderer.tabUniforms = TabUniforms()
    }

    private func updateUniformsGeometry(blobFrame: CGRect? = nil) {
        guard let renderer = renderer else { return }

        let captureArea = captureRect
        guard captureArea.width > 0 && captureArea.height > 0 else { return }

        let blob = blobFrame ?? blobBackgroundView?.frame ?? .zero
        guard blob.width > 0 && blob.height > 0 else { return }

        // Get scale factor - drawable uses pixels, not points
        let scale = metalView?.contentScaleFactor ?? 1.0

        // Use blob's pill radius (height/2) for shader corner radius
        let pillRadius = blob.height / 2

        // View size matches capture area (texture size)
        renderer.glassUniforms.viewSize = SIMD2<Float>(
            Float(captureArea.width * scale),
            Float(captureArea.height * scale)
        )

        // Glass origin = blob position within capture area
        let blobOriginInCapture = CGPoint(
            x: blob.origin.x - captureArea.origin.x,
            y: blob.origin.y - captureArea.origin.y
        )
        renderer.glassUniforms.glassOrigin = SIMD2<Float>(
            Float(blobOriginInCapture.x * scale),
            Float(blobOriginInCapture.y * scale)
        )

        // Glass size is the blob size
        renderer.glassUniforms.glassSize = SIMD2<Float>(
            Float(blob.width * scale),
            Float(blob.height * scale)
        )

        renderer.glassUniforms.cornerRadius = Float(pillRadius * scale)
        renderer.glassUniforms.refractionStrength = Float(configuration.refractionStrength)
        renderer.glassUniforms.specularIntensity = Float(configuration.specularIntensity)

        // Squash/stretch effect - use animator's normalized velocity
        renderer.glassUniforms.scrollVelocity = squashStretchAnimator.normalizedVelocity
        renderer.glassUniforms.time = Float(CACurrentMediaTime())
    }

    // MARK: - Configuration

    private func applyConfiguration() {
        // Update backdrop blur settings
        if let backdrop = backdropLayer {
            BackdropLayerWrapper.updateBlurIntensity(configuration.blurIntensity, on: backdrop)
            BackdropLayerWrapper.updateSaturation(configuration.saturationBoost, on: backdrop)
        }

        // Update tint color
        tintLayer?.backgroundColor = configuration.tintColor.withAlphaComponent(configuration.tintOpacity).cgColor

        // Update Metal view FPS
        metalView?.preferredFramesPerSecond = configuration.preferredFPS

        // Update animators
        blobAnimator.configure(with: configuration)

        // Update renderer
        updateUniformsGeometry()

        setNeedsLayout()
    }

    // MARK: - Backdrop Snapshot for Refraction

    func updateBackdropSnapshot() {
        captureBackdropSnapshot()
    }

    /// Cached capture rect for backdrop (tab bar + padding for scaled blob overflow)
    private var captureRect: CGRect {
        let baseHeight = bounds.height - Constants.blobVerticalPadding
        let maxScaledHeight = baseHeight * configuration.sdfDragScale

        // Account for squash/stretch deformation in both dimensions
        // Height can expand up to 1.35x, width up to 1.5x
        let verticalPadding = (maxScaledHeight * 1.35 - baseHeight) / 2
        let horizontalPadding = (maxScaledHeight * 1.5 - baseHeight) / 2

        return bounds.insetBy(dx: -horizontalPadding, dy: -verticalPadding)
    }

    /// Clamp X position to valid tab range (first to last tab center)
    private func clampedX(_ x: CGFloat) -> CGFloat {
        guard !tabButtons.isEmpty else { return x }
        let minX = tabButtons.first!.center.x
        let maxX = tabButtons.last!.center.x
        return min(max(x, minX), maxX)
    }

    private func captureBackdropSnapshot() {
        guard let superview = superview,
              let pool = texturePool,
              bounds.width > 0 && bounds.height > 0 else { return }

        let scale = metalView?.contentScaleFactor ?? 2.0
        let captureArea = captureRect

        // Get IOSurface-backed context sized for tab bar + padding
        guard let context = pool.getContext(size: captureArea.size, scale: scale) else { return }

        // Lock IOSurface for CPU access
        pool.lockForCPU()

        // Get capture rect in superview's coordinate space
        let captureRectInSuperview = convert(captureArea, to: superview)

        // Hide Metal and blob background (keep masked icons visible for refraction)
        metalContainerView?.isHidden = true
        blobBackgroundView?.isHidden = true
        // Keep maskedContentView visible so selected icons get refracted through glass

        // Save state, apply transforms, render at capture area position
        context.saveGState()
        context.translateBy(x: -captureRectInSuperview.origin.x * scale, y: -captureRectInSuperview.origin.y * scale)
        context.scaleBy(x: scale, y: scale)
        superview.layer.render(in: context)
        context.restoreGState()

        // Restore visibility based on expanded state
        let isExpanded = blobScaleAnimator.current > Constants.expandedThreshold
        metalContainerView?.isHidden = !isExpanded
        blobBackgroundView?.isHidden = isExpanded
        maskedContentView?.isHidden = false

        // Unlock IOSurface
        pool.unlockForCPU()

        // Texture is already backed by the same IOSurface - zero copy!
        renderer?.backdropTexture = pool.getTexture()
    }
}
