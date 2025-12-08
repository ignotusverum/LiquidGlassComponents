import UIKit

// MARK: - LiquidGlassSwitcher

final class LiquidGlassSwitcher: UIControl {

    // MARK: - Constants

    private enum Constants {
        static let trackHeight: CGFloat = 34
        static let trackWidth: CGFloat = 56
        static let thumbSize: CGFloat = 28
        static let thumbPadding: CGFloat = 3
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
    private var thumb: UIView!
    private var thumbBackdropLayer: CALayer?
    private var thumbTintLayer: CALayer!

    // MARK: - Animation

    private var thumbAnimator: SpringAnimator?
    private var displayLink: CADisplayLink?

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

        trackTintLayer = CALayer()
        trackTintLayer.backgroundColor = configuration.tintColor.withAlphaComponent(configuration.tintOpacity).cgColor
        trackContainer.layer.addSublayer(trackTintLayer)
    }

    private func setupThumb() {
        thumb = UIView()
        thumb.backgroundColor = .clear
        thumb.layer.cornerCurve = .continuous
        thumb.isUserInteractionEnabled = false
        addSubview(thumb)

        thumbTintLayer = CALayer()
        thumbTintLayer.backgroundColor = UIColor.white.withAlphaComponent(0.9).cgColor
        thumb.layer.addSublayer(thumbTintLayer)

        // Add shadow to thumb
        thumb.layer.shadowColor = UIColor.black.cgColor
        thumb.layer.shadowOffset = CGSize(width: 0, height: 2)
        thumb.layer.shadowRadius = 4
        thumb.layer.shadowOpacity = 0.15
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    private func setupDisplayLink() {
        thumbAnimator = SpringAnimator(mass: 1.0, stiffness: 400, damping: 25)
        thumbAnimator?.setPosition(CGPoint(x: thumbXPosition(for: isOn), y: 0), animated: false)

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
                fallback.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.5).cgColor
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
            blurIntensity: isTrack ? configuration.blurIntensity : configuration.blurIntensity * 0.5,
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

        // Position thumb
        updateThumbFrame()

        setupBackdropLayers()
    }

    private func updateThumbFrame() {
        let thumbX = thumbAnimator?.current.x ?? thumbXPosition(for: isOn)
        let trackFrame = trackContainer.frame

        thumb.frame = CGRect(
            x: trackFrame.minX + thumbX,
            y: trackFrame.minY + Constants.thumbPadding,
            width: Constants.thumbSize,
            height: Constants.thumbSize
        )
        thumb.layer.cornerRadius = Constants.thumbSize / 2

        thumbTintLayer.frame = thumb.bounds
        thumbTintLayer.cornerRadius = Constants.thumbSize / 2
    }

    private func thumbXPosition(for state: Bool) -> CGFloat {
        if state {
            return Constants.trackWidth - Constants.thumbSize - Constants.thumbPadding
        } else {
            return Constants.thumbPadding
        }
    }

    // MARK: - Display Link

    @objc private func displayLinkFired() {
        thumbAnimator?.step()

        if let animator = thumbAnimator, !animator.isSettled {
            updateThumbFrame()
        }
    }

    // MARK: - Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        toggle()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: trackContainer)
        let progress = (location.x / Constants.trackWidth).clamped(to: 0...1)

        switch gesture.state {
        case .changed:
            let targetX = Constants.thumbPadding + progress * (Constants.trackWidth - Constants.thumbSize - Constants.thumbPadding * 2)
            thumbAnimator?.target = CGPoint(x: targetX, y: 0)
        case .ended, .cancelled:
            let shouldBeOn = progress > 0.5
            setOn(shouldBeOn, animated: true)
        default:
            break
        }
    }

    // MARK: - Public API

    func setOn(_ on: Bool, animated: Bool) {
        isOn = on
        let targetX = thumbXPosition(for: on)

        thumbAnimator?.setPosition(CGPoint(x: targetX, y: 0), animated: animated)
        if !animated {
            updateThumbFrame()
        }

        updateTrackTint(animated: animated)
    }

    func toggle() {
        setOn(!isOn, animated: true)
    }

    // MARK: - Visual Updates

    private func updateTrackTint(animated: Bool) {
        let color: UIColor
        if isOn {
            color = UIColor.systemGreen.withAlphaComponent(0.6)
        } else {
            color = configuration.tintColor.withAlphaComponent(configuration.tintOpacity)
        }

        if animated {
            UIView.animate(withDuration: 0.25) {
                self.trackTintLayer.backgroundColor = color.cgColor
            }
        } else {
            trackTintLayer.backgroundColor = color.cgColor
        }
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
