import SwiftUI
import UIKit

/// The status line shown while a streaming reply is waiting: one line of text below the body with
/// a single-colour sweep. No icon, no dots, no ellipsis.
///
/// The sweep is two labels in the same place. The lower one is `textTertiary`; the upper one is
/// `textPrimary`, masked by a horizontal gradient band that travels in the reading direction
/// (mirrored for RTL). With Reduce Motion on there is no sweep and the text is a static
/// `textSecondary`.
final class UIKitStreamActivityLine: UIView {
    nonisolated static let sweepDuration: CFTimeInterval = 1.8
    /// The highlight band is about 30% of the text width.
    nonisolated static let highlightBandRatio: CGFloat = 0.3
    nonisolated static let fadeInDuration: TimeInterval = 0.2
    private static let sweepAnimationKey = "streamActivitySweep"

    private let baseLabel = UILabel()
    private let highlightLabel = UILabel()
    private let highlightMask = CAGradientLayer()
    private var foregroundObserver: NSObjectProtocol?
    /// Label width when the mask was last laid out and the sweep started. The animation is only
    /// rebuilt when the width changes; otherwise every layout pass would restart the sweep.
    private var sweepWidth: CGFloat = -1

    /// Driven by the host cell. The sweep only runs while this is true and the view is in a window.
    private(set) var isPresenting = false

    var text: String { baseLabel.text ?? "" }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayout()
        // Going to the background removes every CAAnimation; put the sweep back on return if the
        // line is still presented.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartSweepIfNeeded()
            }
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Presents the line, or swaps its text in place. Coming from hidden it fades in over 200 ms;
    /// while already presented only the text changes, with no second fade.
    func present(text: String) {
        let textChanged = baseLabel.text != text
        if textChanged {
            baseLabel.text = text
            highlightLabel.text = text
            accessibilityLabel = text
            sweepWidth = -1
            setNeedsLayout()
        }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        applyStaticAppearance(reduceMotion: reduceMotion)
        guard !isPresenting else {
            if textChanged { restartSweepIfNeeded() }
            return
        }
        isPresenting = true
        if reduceMotion {
            alpha = 1
        } else {
            alpha = 0
            UIView.animate(
                withDuration: Self.fadeInDuration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                self.alpha = 1
            }
        }
        restartSweepIfNeeded()
    }

    /// Hides immediately, with no fade-out: once body text resumes the line must not linger and
    /// hold its space.
    func dismiss() {
        guard isPresenting else { return }
        isPresenting = false
        layer.removeAllAnimations()
        alpha = 1
        stopSweep()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Off screen (the cell left the window) the sweep does not idle; it resumes when the view
        // is back in a window and still presented.
        if window == nil {
            stopSweep()
        } else {
            restartSweepIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard highlightLabel.bounds.width != sweepWidth else { return }
        restartSweepIfNeeded()
    }

    // MARK: - Sweep

    private func restartSweepIfNeeded() {
        stopSweep()
        guard isPresenting, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let width = highlightLabel.bounds.width
        let height = highlightLabel.bounds.height
        guard width > 0, height > 0 else { return }
        sweepWidth = width

        let band = max(1, width * Self.highlightBandRatio)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightMask.bounds = CGRect(x: 0, y: 0, width: band, height: height)
        highlightMask.position = CGPoint(x: -band / 2, y: height / 2)
        CATransaction.commit()

        // In the reading direction: left to right for LTR, mirrored for RTL.
        let leadingOutside = -band / 2
        let trailingOutside = width + band / 2
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = isRTL ? trailingOutside : leadingOutside
        sweep.toValue = isRTL ? leadingOutside : trailingOutside
        sweep.duration = Self.sweepDuration
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.isRemovedOnCompletion = false
        highlightMask.add(sweep, forKey: Self.sweepAnimationKey)
    }

    private func stopSweep() {
        highlightMask.removeAnimation(forKey: Self.sweepAnimationKey)
        sweepWidth = -1
    }

    private func applyStaticAppearance(reduceMotion: Bool) {
        baseLabel.textColor = UIColor(
            reduceMotion ? OriveoTheme.Palette.textSecondary : OriveoTheme.Palette.textTertiary
        )
        highlightLabel.isHidden = reduceMotion
    }

    // MARK: - Layout

    private func setupLayout() {
        let font = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .footnote), size: 0)
        for label in [baseLabel, highlightLabel] {
            label.font = font
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            // A view with an intrinsic size inside contentStack needs required vertical
            // compression resistance, or the stack may squeeze it while the cell self-sizes.
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.setContentHuggingPriority(.required, for: .vertical)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.topAnchor.constraint(equalTo: topAnchor),
                label.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        highlightLabel.textColor = UIColor(OriveoTheme.Palette.textPrimary)

        highlightMask.startPoint = CGPoint(x: 0, y: 0.5)
        highlightMask.endPoint = CGPoint(x: 1, y: 0.5)
        highlightMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        highlightMask.locations = [0, 0.5, 1]
        // Until the sweep starts the mask stays at zero size: the upper label is fully hidden
        // and only the base colour shows.
        highlightMask.bounds = .zero
        highlightLabel.layer.mask = highlightMask
        applyStaticAppearance(reduceMotion: UIAccessibility.isReduceMotionEnabled)

        // The whole line is one accessibility element whose label is the text. The sweep is
        // invisible to VoiceOver.
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    #if DEBUG
    var _testIsSweeping: Bool { highlightMask.animation(forKey: Self.sweepAnimationKey) != nil }
    var _testSweepAnimation: CABasicAnimation? {
        highlightMask.animation(forKey: Self.sweepAnimationKey) as? CABasicAnimation
    }
    var _testHighlightBandWidth: CGFloat { highlightMask.bounds.width }
    var _testHighlightLabelWidth: CGFloat { highlightLabel.bounds.width }
    var _testBaseTextColor: UIColor? { baseLabel.textColor }
    var _testHighlightHidden: Bool { highlightLabel.isHidden }
    #endif
}
