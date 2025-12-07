import UIKit
import MetalKit

// MARK: - Delegate Protocol

protocol LiquidGlassTabBarDelegate: AnyObject {
    func tabBar(_ tabBar: LiquidGlassTabBar, didSelectItemAt index: Int)
    func tabBar(_ tabBar: LiquidGlassTabBar, didDoubleTapItemAt index: Int)
}

// MARK: - LiquidGlassTabBar

final class LiquidGlassTabBar: UIView {

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
    private var metalContainerView: UIView!  // Larger than bounds to allow blob overflow
    private var metalView: MTKView!
    private var edgeLayer: CAGradientLayer!
    private var contentView: UIView!

    // MARK: - Overflow Configuration

    /// How much the blob can overflow outside the tab bar bounds (in points)
    private let overflowPadding: CGFloat = 30

    /// Vertical padding so blob fits within bounds at normal scale (4pt top + 4pt bottom)
    private let blobVerticalPadding: CGFloat = 8

    // MARK: - IOSurface Texture Pool (GPU-accelerated capture)

    private var texturePool: IOSurfaceTexturePool?

    // MARK: - Metal

    private var renderer: LiquidGlassRenderer?

    // MARK: - Animation

    private var displayLink: CADisplayLink?
    private let blob1Animator = SpringAnimator()
    private let blob2Animator = SpringAnimator()
    private let blob1RadiusAnimator = RadiusAnimator()
    private let blob2RadiusAnimator = RadiusAnimator()
    private let blobScaleAnimator = ScaleAnimator()

    // MARK: - Tab Buttons (Dual Layer for Mask Effect)

    private var normalTabButtons: [UIButton] = []
    private var highlightTabButtons: [UIButton] = []
    private var normalContentView: UIView!
    private var highlightContentView: UIView!
    private var highlightMaskLayer: CAShapeLayer!

    // MARK: - Drag State

    private var isDragging: Bool = false
    private var isTransitioning: Bool = false

    // MARK: - Double Tap Detection

    private var lastTapTime: TimeInterval = 0
    private var lastTappedIndex: Int = -1

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
        clipsToBounds = false  // Allow blob to overflow outside tab bar
        layer.cornerCurve = .continuous

        setupBackdropLayer()
        setupTintLayer()
        setupMetalView()
        setupEdgeLayer()
        setupContentView()
        setupDisplayLink()
        setupGestures()

        applyConfiguration()
    }

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    private func setupBackdropLayer() {
        guard BackdropLayerWrapper.isAvailable() else {
            // Fallback: use UIVisualEffectView or solid color
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

    private func setupMetalView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Metal not available")
            return
        }

        // Container allows blob to overflow outside tab bar bounds
        metalContainerView = UIView()
        metalContainerView.clipsToBounds = false
        metalContainerView.backgroundColor = .clear
        metalContainerView.isUserInteractionEnabled = false
        addSubview(metalContainerView)

        // Metal view fills the container (larger than tab bar)
        metalView = MTKView(frame: .zero, device: device)
        metalView.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.framebufferOnly = false
        metalView.preferredFramesPerSecond = configuration.preferredFPS
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.clipsToBounds = false  // Allow blob to render outside

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
        // Normal content layer (muted colors, always visible behind)
        normalContentView = UIView()
        normalContentView.backgroundColor = .clear
        addSubview(normalContentView)

        // Highlighted content layer (bright colors, masked by blob shape)
        highlightContentView = UIView()
        highlightContentView.backgroundColor = .clear
        addSubview(highlightContentView)

        // Blob-shaped mask for highlight layer
        highlightMaskLayer = CAShapeLayer()
        highlightMaskLayer.fillColor = UIColor.white.cgColor
        highlightContentView.layer.mask = highlightMaskLayer
    }

    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(animationTick))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120)
        displayLink?.add(to: .main, forMode: .common)
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

        // Metal container is larger to allow blob overflow
        let containerFrame = bounds.insetBy(dx: -overflowPadding, dy: -overflowPadding)
        metalContainerView?.frame = containerFrame
        metalView?.frame = metalContainerView?.bounds ?? bounds

        edgeLayer?.frame = bounds
        edgeLayer?.cornerRadius = pillRadius

        normalContentView?.frame = bounds
        highlightContentView?.frame = bounds
        highlightContentView?.clipsToBounds = false  // Allow blob to overflow

        // Update edge mask path with pill radius
        if let mask = edgeLayer?.mask as? CAShapeLayer {
            let path = UIBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                cornerRadius: pillRadius - 1
            )
            mask.path = path.cgPath
        }

        layoutTabButtons()
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
        guard !normalTabButtons.isEmpty else { return }

        let buttonWidth = bounds.width / CGFloat(normalTabButtons.count)
        let buttonHeight = bounds.height

        // Layout both normal and highlight buttons identically
        for (index, button) in normalTabButtons.enumerated() {
            let frame = CGRect(
                x: CGFloat(index) * buttonWidth,
                y: 0,
                width: buttonWidth,
                height: buttonHeight
            )
            button.frame = frame
            highlightTabButtons[index].frame = frame
        }

        // Get correct center now that buttons are laid out
        let center = centerForTab(at: selectedIndex)

        // Always ensure target is correct
        blob1Animator.target = center

        // Position blob at selected tab if not animating
        if blob1Animator.isSettled {
            blob1Animator.setPosition(center, animated: false)
        }

        // Ensure blob radius is initialized on first layout
        if blob1RadiusAnimator.current == 0 && !items.isEmpty {
            blob1RadiusAnimator.setValue(configuration.blobRadius, animated: false)
        }
    }

    // MARK: - Tab Buttons

    private func rebuildTabButtons() {
        // Remove existing
        normalTabButtons.forEach { $0.removeFromSuperview() }
        highlightTabButtons.forEach { $0.removeFromSuperview() }
        normalTabButtons.removeAll()
        highlightTabButtons.removeAll()

        // Create buttons in BOTH content views
        for (index, item) in items.enumerated() {
            // Normal button (muted colors, handles taps)
            let normalButton = createTabButton(item: item, index: index, isHighlighted: false)
            normalButton.addTarget(self, action: #selector(tabButtonTapped(_:)), for: .touchUpInside)
            normalContentView.addSubview(normalButton)
            normalTabButtons.append(normalButton)

            // Highlighted button (bright colors, no interaction - just visual)
            let highlightButton = createTabButton(item: item, index: index, isHighlighted: true)
            highlightButton.isUserInteractionEnabled = false
            highlightContentView.addSubview(highlightButton)
            highlightTabButtons.append(highlightButton)
        }

        // Initialize blob position
        if !items.isEmpty {
            let center = centerForTab(at: selectedIndex)
            blob1Animator.setPosition(center, animated: false)
            blob1RadiusAnimator.setValue(configuration.blobRadius, animated: false)
        }

        setNeedsLayout()
    }

    private func createTabButton(item: LiquidGlassTabItem, index: Int, isHighlighted: Bool) -> UIButton {
        let button = UIButton(type: .system)
        button.tag = index

        // Highlighted buttons are always bright, normal buttons are always muted
        let foregroundColor: UIColor = isHighlighted ? .label : .secondaryLabel

        button.tintColor = foregroundColor

        var config = UIButton.Configuration.plain()
        config.image = item.icon.withRenderingMode(.alwaysTemplate)
        config.title = item.title
        config.imagePlacement = .top
        config.imagePadding = 4
        config.baseForegroundColor = foregroundColor
        button.configuration = config

        return button
    }

    @objc private func tabButtonTapped(_ sender: UIButton) {
        // Ignore button taps during drag - selection happens via pan gesture end
        guard !isDragging else { return }

        let index = sender.tag
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

        if index != selectedIndex {
            selectTab(at: index, animated: true)
        }
    }

    // MARK: - Selection

    func selectTab(at index: Int, animated: Bool) {
        guard index >= 0 && index < items.count else { return }

        let oldIndex = selectedIndex
        selectedIndex = index

        // Note: Button appearance is handled by the blob mask layer
        // Normal buttons are always muted, highlighted buttons are always bright
        // The mask reveals the highlighted version based on blob position

        // Animate blob
        if animated && configuration.enableBlobMerging {
            animateBlobTransition(from: oldIndex, to: index)
        } else {
            let center = centerForTab(at: index)
            blob1Animator.setPosition(center, animated: animated)
        }

        delegate?.tabBar(self, didSelectItemAt: index)
    }

    private func animateBlobTransition(from oldIndex: Int, to newIndex: Int) {
        let newCenter = centerForTab(at: newIndex)

        // Animate blob1 position toward new target (spring animation)
        // Blob1 radius stays constant - no shrinking needed
        blob1Animator.target = newCenter

        // Spawn blob2 at destination for the merge effect
        blob2Animator.setPosition(newCenter, animated: false)
        blob2RadiusAnimator.setValue(0, animated: false)
        blob2RadiusAnimator.target = configuration.blobRadius

        // Mark as transitioning - blob2 will fade out when blob1 arrives
        isTransitioning = true
    }

    // MARK: - Animation

    @objc private func animationTick() {
        blob1Animator.step()
        blob2Animator.step()
        blob1RadiusAnimator.step()
        blob2RadiusAnimator.step()
        blobScaleAnimator.step()

        // Handle transition completion: fade out blob2 when blob1 arrives
        if isTransitioning {
            if blob1Animator.isSettled {
                // Blob1 has arrived, start fading out blob2
                blob2RadiusAnimator.target = 0
            }
            if blob1Animator.isSettled && blob2RadiusAnimator.isSettled {
                // Both settled, transition complete
                isTransitioning = false
            }
        }

        // Update blob mask for highlight layer (every frame)
        updateBlobMask()

        // Capture backdrop every frame
        captureBackdropSnapshot()
    }

    /// Updates the mask layer to match current blob position using pill shape matching container
    private func updateBlobMask() {
        let blobPath = UIBezierPath()
        let blobScale = blobScaleAnimator.current

        // Get button width for blob width
        let buttonWidth: CGFloat = normalTabButtons.isEmpty ? bounds.width / 4 : normalTabButtons[0].frame.width
        // Base blob height fits within bounds with padding (scale 1.0 = within bounds)
        let baseHeight = bounds.height - blobVerticalPadding

        // Helper to create pill-shaped path matching container style
        func addPillPath(center: CGPoint, scale: CGFloat) {
            // Width stays same, height scales (grows outside container when scale > 1.0)
            let width = buttonWidth * 0.9  // Slightly smaller than button
            let height = baseHeight * scale
            let rect = CGRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            )
            // Pill shape: cornerRadius = height/2
            let pill = UIBezierPath(roundedRect: rect, cornerRadius: height / 2)
            blobPath.append(pill)
        }

        // Add blob1 pill with scale applied (grows outside when pressed/dragged)
        if blob1RadiusAnimator.current > 0 {
            addPillPath(center: blob1Animator.current, scale: blobScale)
        }

        // Add blob2 pill (during transitions, no scale applied)
        if blob2RadiusAnimator.current > 0 {
            addPillPath(center: blob2Animator.current, scale: 1.0)
        }

        // Update mask without implicit animation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightMaskLayer.path = blobPath.cgPath
        CATransaction.commit()
    }

    // MARK: - Pan Gesture (Draggable Blob)

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            isDragging = true
            // Move blob to finger position immediately
            blob1Animator.setPosition(location, animated: false)
            // Scale up when dragging starts
            blobScaleAnimator.setScale(configuration.blobDragScale, animated: true)

        case .changed:
            // Move blob to follow finger
            blob1Animator.setPosition(location, animated: false)

        case .ended, .cancelled:
            isDragging = false
            // Scale back down to normal (fits within bounds)
            blobScaleAnimator.setScale(1.0, animated: true)

            // Snap to nearest tab
            let nearestIndex = indexOfNearestTab(to: location)
            selectTab(at: nearestIndex, animated: true)

        default:
            break
        }
    }

    private func indexOfNearestTab(to point: CGPoint) -> Int {
        guard !normalTabButtons.isEmpty else { return 0 }

        var nearestIndex = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude

        for (index, button) in normalTabButtons.enumerated() {
            let distance = abs(button.center.x - point.x)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = index
            }
        }

        return nearestIndex
    }

    private var debugLogCounter = 0

    private func updateUniforms() {
        guard let renderer = renderer else { return }

        // Get scale factor for Metal coordinates (drawable uses pixels, not points)
        let scale = metalView?.contentScaleFactor ?? 1.0
        let blobScale = blobScaleAnimator.current

        // Offset for container (blob positions need to be offset by padding)
        let paddingOffset = overflowPadding * scale

        // Calculate blob size: width based on button, height with padding (fits within at scale 1.0)
        let buttonWidth: CGFloat = normalTabButtons.isEmpty ? bounds.width / 4 : normalTabButtons[0].frame.width
        let blobWidth = buttonWidth * 0.9  // Slightly smaller than button
        let baseHeight = bounds.height - blobVerticalPadding  // Fits within bounds at scale 1.0
        let blobHeight = baseHeight * blobScale  // Overflows when scale > 1.0

        // Update blob1 - convert points to pixels, offset by container padding
        let blob1Pos = CGPoint(
            x: blob1Animator.current.x * scale + paddingOffset,
            y: blob1Animator.current.y * scale + paddingOffset
        )
        let blob1Size = CGSize(width: blobWidth * scale, height: blobHeight * scale)
        renderer.blob1Uniforms = BlobUniforms(
            position: blob1Pos,
            size: blob1Size,
            intensity: configuration.blobIntensity
        )

        // Update blob2 - convert points to pixels, offset by container padding
        let blob2Pos = CGPoint(
            x: blob2Animator.current.x * scale + paddingOffset,
            y: blob2Animator.current.y * scale + paddingOffset
        )
        let blob2Size = CGSize(width: blobWidth * scale, height: baseHeight * scale)  // Uses same padded height
        renderer.blob2Uniforms = BlobUniforms(
            position: blob2Pos,
            size: blob2Size,
            intensity: configuration.blobIntensity
        )

        // Update tab uniforms for unselected fills (also offset by padding)
        renderer.tabUniforms.count = Int32(min(normalTabButtons.count, 8))
        renderer.tabUniforms.selectedIndex = Int32(selectedIndex)
        renderer.tabUniforms.fillRadius = Float(blobWidth * scale * 0.4)  // Smaller fill for unselected
        renderer.tabUniforms.fillOpacity = Float(configuration.unselectedFillOpacity)

        for (index, button) in normalTabButtons.enumerated() where index < 8 {
            let pos = CGPoint(
                x: button.center.x * scale + paddingOffset,
                y: button.center.y * scale + paddingOffset
            )
            renderer.tabUniforms.setPosition(index, pos)
        }

        // Debug logging (every 60 frames to avoid spam)
        debugLogCounter += 1
        if debugLogCounter % 60 == 0 {
            print("[LiquidGlass] Scale: \(scale), BlobScale: \(blobScale), Blob1: pos=\(blob1Pos), size=\(blob1Size)")
            print("[LiquidGlass] ContainerSize (pixels): \((bounds.width + overflowPadding * 2) * scale) x \((bounds.height + overflowPadding * 2) * scale)")
        }
    }

    private func updateUniformsGeometry() {
        guard let renderer = renderer else { return }

        // Get scale factor - drawable uses pixels, not points
        let scale = metalView?.contentScaleFactor ?? 1.0

        // Use pill radius (height/2) for shader corner radius
        let pillRadius = bounds.height / 2

        // Container is larger than tab bar by overflowPadding on each side
        let containerWidth = bounds.width + overflowPadding * 2
        let containerHeight = bounds.height + overflowPadding * 2

        // View size is the full container size (allows blob to render outside)
        renderer.glassUniforms.viewSize = SIMD2<Float>(
            Float(containerWidth * scale),
            Float(containerHeight * scale)
        )

        // Glass origin is offset by padding (glass rect is inside the container)
        renderer.glassUniforms.glassOrigin = SIMD2<Float>(
            Float(overflowPadding * scale),
            Float(overflowPadding * scale)
        )

        // Glass size is the original tab bar size
        renderer.glassUniforms.glassSize = SIMD2<Float>(
            Float(bounds.width * scale),
            Float(bounds.height * scale)
        )

        renderer.glassUniforms.cornerRadius = Float(pillRadius * scale)
        renderer.glassUniforms.refractionStrength = Float(configuration.refractionStrength)
        renderer.glassUniforms.specularIntensity = Float(configuration.specularIntensity)
    }

    // MARK: - Helpers

    private func centerForTab(at index: Int) -> CGPoint {
        guard index >= 0 && index < normalTabButtons.count else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        let button = normalTabButtons[index]
        return button.center
    }

    private func applyConfiguration() {
        // Corner radius is set in layoutSubviews() as pill shape (height/2)

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
        blob1Animator.configure(with: configuration)
        blob2Animator.configure(with: configuration)

        // Update renderer
        updateUniformsGeometry()

        setNeedsLayout()
    }

    // MARK: - Backdrop Snapshot for Refraction (IOSurface-backed, GPU-accelerated)

    /// Public method called by scroll view delegate (no-op now since we capture every frame)
    func updateBackdropSnapshot() {
        // Capture is done every frame in animationTick, so this is a no-op
        // Keep the method for API compatibility
    }

    /// Capture backdrop using IOSurface-backed CGContext (zero-copy to GPU)
    private func captureBackdropSnapshot() {
        guard let superview = superview,
              let pool = texturePool,
              bounds.width > 0 && bounds.height > 0 else { return }

        let scale = metalView?.contentScaleFactor ?? 2.0

        // Container size includes overflow padding
        let containerSize = CGSize(
            width: bounds.width + overflowPadding * 2,
            height: bounds.height + overflowPadding * 2
        )

        // Get IOSurface-backed context (reuses existing if size matches)
        guard let context = pool.getContext(size: containerSize, scale: scale) else { return }

        // Lock IOSurface for CPU access
        pool.lockForCPU()

        // Get the rect of container in superview's coordinate space (includes overflow)
        let containerRect = CGRect(
            x: -overflowPadding,
            y: -overflowPadding,
            width: containerSize.width,
            height: containerSize.height
        )
        let rectInSuperview = convert(containerRect, to: superview)

        // Hide self temporarily so we capture what's behind
        layer.isHidden = true

        // Save state, apply transforms, render
        context.saveGState()
        context.translateBy(x: -rectInSuperview.origin.x * scale, y: -rectInSuperview.origin.y * scale)
        context.scaleBy(x: scale, y: scale)
        superview.layer.render(in: context)
        context.restoreGState()

        layer.isHidden = false

        // Unlock IOSurface
        pool.unlockForCPU()

        // Texture is already backed by the same IOSurface - zero copy!
        renderer?.backdropTexture = pool.getTexture()
    }
}
