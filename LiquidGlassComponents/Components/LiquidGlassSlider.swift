import UIKit

// MARK: - LiquidGlassSlider

final class LiquidGlassSlider: UIControl {

    // MARK: - Constants

    private enum Constants {
        static let trackHeight: CGFloat = 8
        static let thumbSize: CGFloat = 28
        static let expandedTrackHeight: CGFloat = 12
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
    private var thumb: UIView!
    private var thumbBackdropLayer: CALayer?
    private var thumbTintLayer: CALayer!

    // MARK: - Animation

    private var thumbAnimator: SpringAnimator?
    private var scaleAnimator: ScaleAnimator?
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
        setupTrack()
        setupThumb()
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

    private func setupThumb() {
        thumb = UIView()
        thumb.backgroundColor = .clear
        thumb.layer.cornerCurve = .continuous
        thumb.isUserInteractionEnabled = false
        addSubview(thumb)

        thumbTintLayer = CALayer()
        thumbTintLayer.backgroundColor = UIColor.white.withAlphaComponent(0.95).cgColor
        thumb.layer.addSublayer(thumbTintLayer)

        // Add shadow
        thumb.layer.shadowColor = UIColor.black.cgColor
        thumb.layer.shadowOffset = CGSize(width: 0, height: 2)
        thumb.layer.shadowRadius = 4
        thumb.layer.shadowOpacity = 0.2
    }

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    private func setupDisplayLink() {
        thumbAnimator = SpringAnimator(mass: 1.0, stiffness: 500, damping: 28)
        thumbAnimator?.setPosition(CGPoint(x: thumbXPosition(), y: 0), animated: false)

        scaleAnimator = ScaleAnimator()
        scaleAnimator?.stiffness = 400
        scaleAnimator?.damping = 25
        scaleAnimator?.setScale(1.0, animated: false)

        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        displayLink?.add(to: .main, forMode: .common)
    }

    private func setupBackdropLayers() {
        // Track backdrop
        trackBackdropLayer?.removeFromSuperlayer()
        trackBackdropLayer = createBackdropLayer(for: trackContainer, isTrack: true)

        // Thumb backdrop
        thumbBackdropLayer?.removeFromSuperlayer()
        thumbBackdropLayer = createBackdropLayer(for: thumb, isTrack: false)
    }

    private func createBackdropLayer(for container: UIView, isTrack: Bool) -> CALayer? {
        guard BackdropLayerWrapper.isAvailable() else {
            let fallback = CALayer()
            fallback.frame = container.bounds
            if isTrack {
                fallback.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.4).cgColor
            } else {
                fallback.backgroundColor = UIColor.white.withAlphaComponent(0.95).cgColor
            }
            fallback.cornerRadius = container.bounds.height / 2
            fallback.masksToBounds = true
            container.layer.insertSublayer(fallback, at: 0)
            return fallback
        }

        let backdrop = BackdropLayerWrapper.createBackdropLayer(
            withFrame: container.bounds,
            blurIntensity: isTrack ? configuration.blurIntensity * 0.7 : configuration.blurIntensity * 0.5,
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
        return CGSize(width: 200, height: Constants.thumbSize)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let trackY = (bounds.height - Constants.trackHeight) / 2
        let trackWidth = bounds.width - Constants.thumbSize

        trackContainer.frame = CGRect(
            x: Constants.thumbSize / 2,
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
        let fillWidth = trackContainer.bounds.width * value
        fillLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: fillWidth,
            height: trackContainer.bounds.height
        )
        fillLayer.cornerRadius = Constants.trackHeight / 2
        fillLayer.backgroundColor = minimumTrackTintColor.withAlphaComponent(0.7).cgColor
    }

    private func updateThumbFrame() {
        let scale = scaleAnimator?.current ?? 1.0
        let thumbX = thumbAnimator?.current.x ?? thumbXPosition()
        let scaledSize = Constants.thumbSize * scale

        thumb.frame = CGRect(
            x: thumbX - scaledSize / 2,
            y: (bounds.height - scaledSize) / 2,
            width: scaledSize,
            height: scaledSize
        )
        thumb.layer.cornerRadius = scaledSize / 2

        thumbTintLayer.frame = thumb.bounds
        thumbTintLayer.cornerRadius = scaledSize / 2

        // Update fill to match thumb position
        let fillWidth = thumbX - Constants.thumbSize / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: max(0, fillWidth),
            height: trackContainer.bounds.height
        )
        CATransaction.commit()
    }

    private func thumbXPosition() -> CGFloat {
        let trackWidth = bounds.width - Constants.thumbSize
        return Constants.thumbSize / 2 + trackWidth * value
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
        scaleAnimator?.step()

        let positionSettled = thumbAnimator?.isSettled ?? true
        let scaleSettled = scaleAnimator?.isSettled ?? true

        if !positionSettled || !scaleSettled {
            updateThumbFrame()
        }
    }

    // MARK: - Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        let trackWidth = bounds.width - Constants.thumbSize
        let newValue = ((location.x - Constants.thumbSize / 2) / trackWidth).clamped(to: 0...1)

        value = newValue
        thumbAnimator?.target = CGPoint(x: thumbXPosition(), y: 0)

        // Quick scale pop
        scaleAnimator?.target = 1.15
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.scaleAnimator?.target = 1.0
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        let trackWidth = bounds.width - Constants.thumbSize
        let newValue = ((location.x - Constants.thumbSize / 2) / trackWidth).clamped(to: 0...1)

        switch gesture.state {
        case .began:
            isDragging = true
            scaleAnimator?.target = 1.2
        case .changed:
            value = newValue
            thumbAnimator?.setPosition(CGPoint(x: thumbXPosition(), y: 0), animated: false)
            updateThumbFrame()
        case .ended, .cancelled:
            isDragging = false
            scaleAnimator?.target = 1.0
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
