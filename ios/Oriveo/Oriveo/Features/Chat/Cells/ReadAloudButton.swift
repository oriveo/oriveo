import Combine
import SwiftUI
import UIKit

/// Read-aloud button in the assistant message footer: a ghost-style `speaker.wave.2` when idle; while this reply is
/// being read it becomes a 26pt progress ring (brand gradient stroke) with a stop square, keeping the same width.
/// Styled like the neutral footer buttons of AssistantMetadataView.
final class ReadAloudButton: UIView {
    private static let ringDiameter: CGFloat = 26
    private static let symbolPointSize: CGFloat = 15

    private let controller: ReadAloudController
    private let button = UIButton(type: .system)
    private let ringView = ReadAloudProgressRingView()
    private var messageID: UUID?
    private var text = ""
    private var isEligible = false
    private var segmentsCacheText: String?
    private var segmentsCacheIsEmpty = true
    private var stateCancellable: AnyCancellable?

    init(controller: ReadAloudController = .shared) {
        self.controller = controller
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Hidden when isEligible is false or there is nothing to read.
    func configure(messageID: UUID, text: String, isEligible: Bool) {
        self.messageID = messageID
        self.text = text
        self.isEligible = isEligible
        isHidden = !isEligible || !hasSpeakableContent(text)
        #if DEBUG
        if !isHidden { Self.debugLastEligible = (messageID, text) }
        #endif
        render(controller.state)
    }

    #if DEBUG
    /// Sample shots only: the last message whose read-aloud control was shown.
    static var debugLastEligible: (messageID: UUID, text: String)?
    #endif

    /// Resets on cell reuse: hides the button and clears the message.
    func reset() {
        messageID = nil
        text = ""
        isEligible = false
        isHidden = true
        render(controller.state)
    }

    // MARK: Building

    private func setUp() {
        applyButtonConfiguration(iconHidden: false)
        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        ringView.isUserInteractionEnabled = false
        ringView.isHidden = true
        ringView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ringView)

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            ringView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            ringView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ringView.widthAnchor.constraint(equalToConstant: Self.ringDiameter),
            ringView.heightAnchor.constraint(equalToConstant: Self.ringDiameter),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        isHidden = true
        stateCancellable = controller.$state.sink { [weak self] state in
            self?.render(state)
        }
    }

    /// Matches the neutral style of AssistantMetadataView.applyFooterButtonConfiguration; while reading, the icon is clear (keeping its width).
    private func applyButtonConfiguration(iconHidden: Bool) {
        let foreground = UIColor(OriveoTheme.Palette.textTertiary)
        let softBackground = UIColor(OriveoTheme.Palette.surfaceInset)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "speaker.wave.2",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .medium)
        )
        config.imagePadding = 0
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        config.baseForegroundColor = iconHidden ? .clear : foreground
        config.background.backgroundColor = .clear
        config.background.cornerRadius = 8
        button.configuration = config
        button.configurationUpdateHandler = { button in
            guard var updated = button.configuration else { return }
            updated.background.backgroundColor = button.isHighlighted ? softBackground : .clear
            button.configuration = updated
        }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    // MARK: State

    private func render(_ state: ReadAloudState) {
        if case .speaking(let speakingID, let index, let total) = state, speakingID == messageID, !isHidden {
            applyButtonConfiguration(iconHidden: true)
            ringView.isHidden = false
            ringView.setProgress(Double(index + 1) / Double(max(total, 1)), animated: !UIAccessibility.isReduceMotionEnabled)
            ringView.setFlowing(!UIAccessibility.isReduceMotionEnabled)
            button.accessibilityLabel = L10n.tr("Stop Reading", table: .voice)
            button.accessibilityValue = L10n.format(L10n.tr("Sentence %lld of %lld", table: .voice), index + 1, total)
        } else {
            applyButtonConfiguration(iconHidden: false)
            ringView.isHidden = true
            ringView.setFlowing(false)
            button.accessibilityLabel = L10n.tr("Read Aloud", table: .voice)
            button.accessibilityValue = nil
        }
    }

    private func hasSpeakableContent(_ text: String) -> Bool {
        guard isEligible else { return false }
        if segmentsCacheText != text {
            segmentsCacheText = text
            segmentsCacheIsEmpty = SpeakableText.segments(text: text, final: true).isEmpty
        }
        return !segmentsCacheIsEmpty
    }

    @objc private func handleTap() {
        guard let messageID else { return }
        if VoiceConversationSession.shared.isRealtime { return }
        if let conversation = VoiceConversationSession.shared.controller {
            conversation.playMessage(id: messageID.uuidString, text: text)
            return
        }
        controller.toggle(messageID: messageID, text: text)
    }
}

/// 26pt progress ring: a light track, a brand-gradient progress arc (with a slowly rotating shimmer) and a stop square.
private final class ReadAloudProgressRingView: UIView {
    private static let lineWidth: CGFloat = 2.5
    private static let stopSide: CGFloat = 8
    private static let flowAnimationKey = "readAloudFlow"

    private let trackLayer = CAShapeLayer()
    private let progressMask = CAShapeLayer()
    private let gradientLayer = CAGradientLayer()
    private let stopLayer = CAShapeLayer()
    private var progress: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.lineWidth = Self.lineWidth
        layer.addSublayer(trackLayer)

        // The gradient uses OriveoTheme.Palette.primaryGradientColors
        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        progressMask.fillColor = UIColor.clear.cgColor
        progressMask.strokeColor = UIColor.black.cgColor
        progressMask.lineWidth = Self.lineWidth
        progressMask.lineCap = .round
        progressMask.strokeEnd = 0
        gradientLayer.mask = progressMask
        layer.addSublayer(gradientLayer)

        layer.addSublayer(stopLayer)
        updateColors()
        registerForTraitChanges(OriveoDarkPaletteTrait.colorAppearanceTraits) { (view: ReadAloudProgressRingView, _) in
            view.updateColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.lineWidth / 2
        let circleRect = bounds.insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = UIBezierPath(
            arcCenter: center,
            radius: circleRect.width / 2,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        ).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.path = path
        gradientLayer.frame = bounds
        progressMask.frame = gradientLayer.bounds
        progressMask.path = path
        let side = Self.stopSide
        stopLayer.frame = bounds
        stopLayer.path = UIBezierPath(
            roundedRect: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
            cornerRadius: 2
        ).cgPath
        CATransaction.commit()
    }


    func setProgress(_ value: Double, animated: Bool) {
        let clamped = min(max(value, 0), 1)
        guard clamped != progress else { return }
        progress = clamped
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        progressMask.strokeEnd = CGFloat(clamped)
        CATransaction.commit()
    }

    /// Shimmer: the gradient layer rotates slowly. Not used with Reduce Motion.
    func setFlowing(_ flowing: Bool) {
        let running = gradientLayer.animation(forKey: Self.flowAnimationKey) != nil
        if flowing && !running {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = CGFloat.pi * 2
            rotation.duration = 2.4
            rotation.repeatCount = .infinity
            rotation.isRemovedOnCompletion = false
            gradientLayer.add(rotation, forKey: Self.flowAnimationKey)
            // Only the gradient rotates, not the progress arc: the mask counter-rotates to cancel it out
            let counter = CABasicAnimation(keyPath: "transform.rotation.z")
            counter.fromValue = 0
            counter.toValue = -CGFloat.pi * 2
            counter.duration = rotation.duration
            counter.repeatCount = .infinity
            counter.isRemovedOnCompletion = false
            progressMask.add(counter, forKey: Self.flowAnimationKey)
        } else if !flowing && running {
            gradientLayer.removeAnimation(forKey: Self.flowAnimationKey)
            progressMask.removeAnimation(forKey: Self.flowAnimationKey)
        }
    }

    private func updateColors() {
        let traits = traitCollection
        let colors = OriveoTheme.Palette.primaryGradientColors.map { UIColor($0).resolvedColor(with: traits).cgColor }
        // First and last stops match, so the rotating conic gradient has no seam
        gradientLayer.colors = colors + colors.prefix(1)
        trackLayer.strokeColor = UIColor(OriveoTheme.Palette.surfaceInset).resolvedColor(with: traits).cgColor
        stopLayer.fillColor = UIColor(OriveoTheme.Palette.primary).resolvedColor(with: traits).cgColor
    }
}
