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
    private var metalView: MTKView!
    private var edgeLayer: CAGradientLayer!
    private var contentView: UIView!

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

    // MARK: - Tab Buttons

    private var tabButtons: [UIButton] = []

    // MARK: - Drag State

    private var isDragging: Bool = false
    private var hoveredIndex: Int = -1

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
        clipsToBounds = true
        layer.cornerRadius = configuration.cornerRadius
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

        metalView = MTKView(frame: bounds, device: device)
        metalView.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.framebufferOnly = false
        metalView.preferredFramesPerSecond = configuration.preferredFPS
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false

        renderer = LiquidGlassRenderer(device: device)
        metalView.delegate = renderer

        // Create IOSurface texture pool for GPU-accelerated capture
        texturePool = IOSurfaceTexturePool(device: device)

        // Update uniforms callback
        renderer?.onUpdate = { [weak self] in
            self?.updateUniforms()
        }

        addSubview(metalView)
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
        addSubview(contentView)
    }

    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(animationTick))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120)
        displayLink?.add(to: .main, forMode: .common)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        backdropLayer?.frame = bounds
        tintLayer?.frame = bounds
        metalView?.frame = bounds
        edgeLayer?.frame = bounds
        contentView?.frame = bounds

        // Update edge mask path
        if let mask = edgeLayer?.mask as? CAShapeLayer {
            let path = UIBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                cornerRadius: configuration.cornerRadius - 1
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
        guard !tabButtons.isEmpty else { return }

        let buttonWidth = bounds.width / CGFloat(tabButtons.count)
        let buttonHeight = bounds.height

        for (index, button) in tabButtons.enumerated() {
            button.frame = CGRect(
                x: CGFloat(index) * buttonWidth,
                y: 0,
                width: buttonWidth,
                height: buttonHeight
            )
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
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()

        // Create new buttons
        for (index, item) in items.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.tintColor = index == selectedIndex ? .label : .secondaryLabel

            // Stack icon and title
            var config = UIButton.Configuration.plain()
            config.image = item.icon.withRenderingMode(.alwaysTemplate)
            config.title = item.title
            config.imagePlacement = .top
            config.imagePadding = 4
            config.baseForegroundColor = index == selectedIndex ? .label : .secondaryLabel
            button.configuration = config

            button.addTarget(self, action: #selector(tabButtonTapped(_:)), for: .touchUpInside)

            contentView.addSubview(button)
            tabButtons.append(button)
        }

        // Initialize blob position
        if !items.isEmpty {
            let center = centerForTab(at: selectedIndex)
            blob1Animator.setPosition(center, animated: false)
            blob1RadiusAnimator.setValue(configuration.blobRadius, animated: false)
        }

        setNeedsLayout()
    }

    @objc private func tabButtonTapped(_ sender: UIButton) {
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

        // Update button states
        for (i, button) in tabButtons.enumerated() {
            button.tintColor = i == index ? .label : .secondaryLabel
            if var config = button.configuration {
                config.baseForegroundColor = i == index ? .label : .secondaryLabel
                button.configuration = config
            }
        }

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
        // Spawn blob2 at new position
        let newCenter = centerForTab(at: newIndex)
        blob2Animator.setPosition(newCenter, animated: false)
        blob2RadiusAnimator.setValue(0, animated: false)

        // Animate blob2 radius up
        blob2RadiusAnimator.target = configuration.blobRadius

        // Animate blob1 toward new position
        blob1Animator.target = newCenter

        // After blob1 reaches target, fade it out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.blob1RadiusAnimator.target = 0
        }

        // Swap blobs when animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }

            // Swap: blob1 becomes blob2's position/radius
            self.blob1Animator.setPosition(newCenter, animated: false)
            self.blob1RadiusAnimator.setValue(self.configuration.blobRadius, animated: false)

            // Reset blob2
            self.blob2RadiusAnimator.setValue(0, animated: false)
        }
    }

    // MARK: - Animation

    @objc private func animationTick() {
        blob1Animator.step()
        blob2Animator.step()
        blob1RadiusAnimator.step()
        blob2RadiusAnimator.step()

        // Capture backdrop every frame using IOSurface-backed context
        captureBackdropSnapshot()
    }

    // MARK: - Pan Gesture (Draggable Blob)

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            isDragging = true
            // Move blob to finger position immediately
            blob1Animator.setPosition(location, animated: false)
            updateHoveredTab(at: location)

        case .changed:
            // Move blob to follow finger
            blob1Animator.setPosition(location, animated: false)
            updateHoveredTab(at: location)

        case .ended, .cancelled:
            isDragging = false

            // Snap to nearest tab
            let nearestIndex = indexOfNearestTab(to: location)
            selectTab(at: nearestIndex, animated: true)

            // Clear hover state
            clearHoverState()

        default:
            break
        }
    }

    private func updateHoveredTab(at location: CGPoint) {
        let newHoveredIndex = indexOfTabContaining(location)

        if newHoveredIndex != hoveredIndex {
            // Clear old hover state
            if hoveredIndex >= 0 && hoveredIndex < tabButtons.count {
                updateButtonAppearance(at: hoveredIndex, isHovered: false)
            }

            hoveredIndex = newHoveredIndex

            // Apply new hover state
            if hoveredIndex >= 0 && hoveredIndex < tabButtons.count {
                updateButtonAppearance(at: hoveredIndex, isHovered: true)
            }
        }
    }

    private func clearHoverState() {
        if hoveredIndex >= 0 && hoveredIndex < tabButtons.count {
            updateButtonAppearance(at: hoveredIndex, isHovered: false)
        }
        hoveredIndex = -1
    }

    private func updateButtonAppearance(at index: Int, isHovered: Bool) {
        guard index >= 0 && index < tabButtons.count else { return }
        let button = tabButtons[index]

        let isSelected = index == selectedIndex

        // When hovered, show as "active" (filled icon, bold color)
        // When not hovered, show based on selection state
        if var config = button.configuration {
            if isHovered {
                config.baseForegroundColor = .label
                // Use filled version of icon when hovered
                if let item = items[safe: index] {
                    config.image = item.icon.withRenderingMode(.alwaysTemplate)
                }
            } else {
                config.baseForegroundColor = isSelected ? .label : .secondaryLabel
            }
            button.configuration = config
        }
        button.tintColor = isHovered ? .label : (isSelected ? .label : .secondaryLabel)
    }

    private func indexOfTabContaining(_ point: CGPoint) -> Int {
        for (index, button) in tabButtons.enumerated() {
            if button.frame.contains(point) {
                return index
            }
        }
        return -1
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

    private var debugLogCounter = 0

    private func updateUniforms() {
        guard let renderer = renderer else { return }

        // Get scale factor for Metal coordinates (drawable uses pixels, not points)
        let scale = metalView?.contentScaleFactor ?? 1.0

        // Update blob1 - convert points to pixels
        let blob1Pos = CGPoint(
            x: blob1Animator.current.x * scale,
            y: blob1Animator.current.y * scale
        )
        renderer.blob1Uniforms = BlobUniforms(
            position: blob1Pos,
            radius: blob1RadiusAnimator.current * scale,
            intensity: configuration.blobIntensity
        )

        // Update blob2 - convert points to pixels
        let blob2Pos = CGPoint(
            x: blob2Animator.current.x * scale,
            y: blob2Animator.current.y * scale
        )
        renderer.blob2Uniforms = BlobUniforms(
            position: blob2Pos,
            radius: blob2RadiusAnimator.current * scale,
            intensity: configuration.blobIntensity
        )

        // Debug logging (every 60 frames to avoid spam)
        debugLogCounter += 1
        if debugLogCounter % 60 == 0 {
            print("[LiquidGlass] Scale: \(scale), Blob1: pos=\(blob1Pos), radius=\(blob1RadiusAnimator.current * scale)")
            print("[LiquidGlass] ViewSize (pixels): \(bounds.size.width * scale) x \(bounds.size.height * scale)")
        }
    }

    private func updateUniformsGeometry() {
        guard let renderer = renderer else { return }

        // Get scale factor - drawable uses pixels, not points
        let scale = metalView?.contentScaleFactor ?? 1.0

        renderer.glassUniforms.viewSize = SIMD2<Float>(Float(bounds.width * scale), Float(bounds.height * scale))
        renderer.glassUniforms.glassOrigin = SIMD2<Float>(0, 0)
        renderer.glassUniforms.glassSize = SIMD2<Float>(Float(bounds.width * scale), Float(bounds.height * scale))
        renderer.glassUniforms.cornerRadius = Float(configuration.cornerRadius * scale)
        renderer.glassUniforms.refractionStrength = Float(configuration.refractionStrength)
        renderer.glassUniforms.specularIntensity = Float(configuration.specularIntensity)
    }

    // MARK: - Helpers

    private func centerForTab(at index: Int) -> CGPoint {
        guard index >= 0 && index < tabButtons.count else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        let button = tabButtons[index]
        return button.center
    }

    private func applyConfiguration() {
        layer.cornerRadius = configuration.cornerRadius

        // Update backdrop
        if let backdrop = backdropLayer {
            backdrop.cornerRadius = configuration.cornerRadius
            BackdropLayerWrapper.updateBlurIntensity(configuration.blurIntensity, on: backdrop)
            BackdropLayerWrapper.updateSaturation(configuration.saturationBoost, on: backdrop)
        }

        // Update tint
        tintLayer?.backgroundColor = configuration.tintColor.withAlphaComponent(configuration.tintOpacity).cgColor
        tintLayer?.cornerRadius = configuration.cornerRadius

        // Update edge
        edgeLayer?.cornerRadius = configuration.cornerRadius

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

        // Get IOSurface-backed context (reuses existing if size matches)
        guard let context = pool.getContext(size: bounds.size, scale: scale) else { return }

        // Lock IOSurface for CPU access
        pool.lockForCPU()

        // Get the rect of this view in superview's coordinate space
        let rectInSuperview = convert(bounds, to: superview)

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

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
