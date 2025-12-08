import UIKit

// MARK: - LiquidGlassInputBar

final class LiquidGlassInputBar: UIView {

    // MARK: - Constants

    private enum Constants {
        static let buttonSize: CGFloat = 44
        static let spacing: CGFloat = 8
        static let iconSize: CGFloat = 22
        static let smallIconSize: CGFloat = 18
    }

    // MARK: - Configuration

    var configuration: LiquidGlassConfiguration = .default {
        didSet { applyConfiguration() }
    }

    // MARK: - Container Views

    private var leftButtonContainer: UIView!
    private var centerPillContainer: UIView!
    private var rightButtonContainer: UIView!

    // MARK: - Backdrop Layers

    private var leftBackdropLayer: CALayer?
    private var leftTintLayer: CALayer!
    private var centerBackdropLayer: CALayer?
    private var centerTintLayer: CALayer!
    private var rightBackdropLayer: CALayer?
    private var rightTintLayer: CALayer!

    // MARK: - UI Elements

    private var attachmentButton: UIButton!
    private var messageLabel: UILabel!
    private var giftButton: UIButton!
    private var timerButton: UIButton!
    private var microphoneButton: UIButton!

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Setup

    private func setup() {
        backgroundColor = .clear
        setupLeftButton()
        setupCenterPill()
        setupRightButton()
    }

    private func setupLeftButton() {
        // Container
        leftButtonContainer = UIView()
        leftButtonContainer.backgroundColor = .clear
        leftButtonContainer.layer.cornerCurve = .continuous
        addSubview(leftButtonContainer)

        // Tint layer
        leftTintLayer = CALayer()
        leftTintLayer.backgroundColor = configuration.tintColor.withAlphaComponent(configuration.tintOpacity).cgColor
        leftButtonContainer.layer.addSublayer(leftTintLayer)

        // Button
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "paperclip")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: Constants.iconSize, weight: .medium)
        )
        config.baseForegroundColor = .secondaryLabel
        attachmentButton = UIButton(configuration: config)
        leftButtonContainer.addSubview(attachmentButton)
    }

    private func setupCenterPill() {
        // Container
        centerPillContainer = UIView()
        centerPillContainer.backgroundColor = .clear
        centerPillContainer.layer.cornerCurve = .continuous
        addSubview(centerPillContainer)

        // Tint layer
        centerTintLayer = CALayer()
        centerTintLayer.backgroundColor = configuration.tintColor.withAlphaComponent(configuration.tintOpacity).cgColor
        centerPillContainer.layer.addSublayer(centerTintLayer)

        // Message label
        messageLabel = UILabel()
        messageLabel.text = "Message"
        messageLabel.textColor = .placeholderText
        messageLabel.font = .systemFont(ofSize: 17)
        centerPillContainer.addSubview(messageLabel)

        // Gift button
        var giftConfig = UIButton.Configuration.plain()
        giftConfig.image = UIImage(systemName: "gift")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: Constants.smallIconSize, weight: .medium)
        )
        giftConfig.baseForegroundColor = .secondaryLabel
        giftButton = UIButton(configuration: giftConfig)
        centerPillContainer.addSubview(giftButton)

        // Timer button
        var timerConfig = UIButton.Configuration.plain()
        timerConfig.image = UIImage(systemName: "clock")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: Constants.smallIconSize, weight: .medium)
        )
        timerConfig.baseForegroundColor = .secondaryLabel
        timerButton = UIButton(configuration: timerConfig)
        centerPillContainer.addSubview(timerButton)
    }

    private func setupRightButton() {
        // Container
        rightButtonContainer = UIView()
        rightButtonContainer.backgroundColor = .clear
        rightButtonContainer.layer.cornerCurve = .continuous
        addSubview(rightButtonContainer)

        // Tint layer
        rightTintLayer = CALayer()
        rightTintLayer.backgroundColor = configuration.tintColor.withAlphaComponent(configuration.tintOpacity).cgColor
        rightButtonContainer.layer.addSublayer(rightTintLayer)

        // Button
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "mic")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: Constants.iconSize, weight: .medium)
        )
        config.baseForegroundColor = .secondaryLabel
        microphoneButton = UIButton(configuration: config)
        rightButtonContainer.addSubview(microphoneButton)
    }

    // MARK: - Backdrop Layers

    private func setupBackdropLayers() {
        // Left button backdrop
        leftBackdropLayer?.removeFromSuperlayer()
        leftBackdropLayer = createBackdropLayer(for: leftButtonContainer)

        // Center pill backdrop
        centerBackdropLayer?.removeFromSuperlayer()
        centerBackdropLayer = createBackdropLayer(for: centerPillContainer)

        // Right button backdrop
        rightBackdropLayer?.removeFromSuperlayer()
        rightBackdropLayer = createBackdropLayer(for: rightButtonContainer)
    }

    private func createBackdropLayer(for container: UIView) -> CALayer? {
        guard BackdropLayerWrapper.isAvailable() else {
            // Fallback: use a semi-transparent background
            let fallback = CALayer()
            fallback.frame = container.bounds
            fallback.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.7).cgColor
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

    override func layoutSubviews() {
        super.layoutSubviews()

        let height = bounds.height
        let buttonSize = min(Constants.buttonSize, height)

        // Left button - circular
        leftButtonContainer.frame = CGRect(
            x: 0,
            y: (height - buttonSize) / 2,
            width: buttonSize,
            height: buttonSize
        )
        leftButtonContainer.layer.cornerRadius = buttonSize / 2

        // Right button - circular
        rightButtonContainer.frame = CGRect(
            x: bounds.width - buttonSize,
            y: (height - buttonSize) / 2,
            width: buttonSize,
            height: buttonSize
        )
        rightButtonContainer.layer.cornerRadius = buttonSize / 2

        // Center pill - fills remaining space
        let pillX = buttonSize + Constants.spacing
        let pillWidth = bounds.width - (buttonSize * 2) - (Constants.spacing * 2)
        centerPillContainer.frame = CGRect(
            x: pillX,
            y: 0,
            width: pillWidth,
            height: height
        )
        centerPillContainer.layer.cornerRadius = height / 2

        // Layout internal elements
        layoutLeftButton()
        layoutCenterPill()
        layoutRightButton()

        // Update tint layers
        updateTintLayers()

        // Setup backdrop layers (needs to happen after layout for correct frames)
        setupBackdropLayers()
    }

    private func layoutLeftButton() {
        attachmentButton.frame = leftButtonContainer.bounds
    }

    private func layoutCenterPill() {
        let height = centerPillContainer.bounds.height
        let padding: CGFloat = 16
        let iconButtonSize: CGFloat = 32

        // Timer button (rightmost)
        timerButton.frame = CGRect(
            x: centerPillContainer.bounds.width - padding - iconButtonSize,
            y: (height - iconButtonSize) / 2,
            width: iconButtonSize,
            height: iconButtonSize
        )

        // Gift button (left of timer)
        giftButton.frame = CGRect(
            x: timerButton.frame.minX - iconButtonSize,
            y: (height - iconButtonSize) / 2,
            width: iconButtonSize,
            height: iconButtonSize
        )

        // Message label (left side)
        messageLabel.sizeToFit()
        messageLabel.frame = CGRect(
            x: padding,
            y: (height - messageLabel.bounds.height) / 2,
            width: giftButton.frame.minX - padding - 8,
            height: messageLabel.bounds.height
        )
    }

    private func layoutRightButton() {
        microphoneButton.frame = rightButtonContainer.bounds
    }

    private func updateTintLayers() {
        leftTintLayer.frame = leftButtonContainer.bounds
        leftTintLayer.cornerRadius = leftButtonContainer.bounds.height / 2

        centerTintLayer.frame = centerPillContainer.bounds
        centerTintLayer.cornerRadius = centerPillContainer.bounds.height / 2

        rightTintLayer.frame = rightButtonContainer.bounds
        rightTintLayer.cornerRadius = rightButtonContainer.bounds.height / 2
    }

    // MARK: - Configuration

    private func applyConfiguration() {
        // Update tint colors
        let tintColor = configuration.tintColor.withAlphaComponent(configuration.tintOpacity).cgColor
        leftTintLayer?.backgroundColor = tintColor
        centerTintLayer?.backgroundColor = tintColor
        rightTintLayer?.backgroundColor = tintColor

        // Update backdrop blur settings
        if let backdrop = leftBackdropLayer {
            BackdropLayerWrapper.updateBlurIntensity(configuration.blurIntensity, on: backdrop)
            BackdropLayerWrapper.updateSaturation(configuration.saturationBoost, on: backdrop)
        }
        if let backdrop = centerBackdropLayer {
            BackdropLayerWrapper.updateBlurIntensity(configuration.blurIntensity, on: backdrop)
            BackdropLayerWrapper.updateSaturation(configuration.saturationBoost, on: backdrop)
        }
        if let backdrop = rightBackdropLayer {
            BackdropLayerWrapper.updateBlurIntensity(configuration.blurIntensity, on: backdrop)
            BackdropLayerWrapper.updateSaturation(configuration.saturationBoost, on: backdrop)
        }
    }
}
