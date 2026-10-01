import SwiftUI
import UIKit

final class UIKitTypingIndicator: UIView {
    private let dotViews: [UIView] = (0 ..< 3).map { _ in UIView() }
    private let label = UILabel()
    private let hStack = UIStackView()

    private let dotSize: CGFloat = 6
    private let verticalPadding: CGFloat = OriveoTheme.Spacing.xs // 4pt

    private var isAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        guard !reduceMotion else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, dotView) in dotViews.enumerated() {
            let delay = Double(i) * 0.15

            let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
            scaleAnim.fromValue = 0.72
            scaleAnim.toValue = 1.0
            scaleAnim.duration = 0.35
            scaleAnim.beginTime = CACurrentMediaTime() + delay
            scaleAnim.autoreverses = true
            scaleAnim.repeatCount = .infinity
            scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            dotView.layer.add(scaleAnim, forKey: "scale")
        }
        CATransaction.commit()
    }

    /// Overrides the label: while an activity is observed and the indicator is visible it shows
    /// the activity label; `nil` restores the default `Generating`. Only the text changes, the
    /// dots and the layout stay as they are.
    func setCaption(_ caption: String?) {
        let next = caption ?? L10n.tr("Generating")
        guard label.text != next else { return }
        label.text = next
    }

    var caption: String { label.text ?? "" }

    func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        for dotView in dotViews {
            dotView.layer.removeAllAnimations()
        }
    }

    private func setupLayout() {
        let primaryColor = UIColor(OriveoTheme.Palette.primary)
        let dotColor = primaryColor.withAlphaComponent(0.75)

        let dotStack = UIStackView()
        dotStack.axis = .horizontal
        dotStack.spacing = 8
        dotStack.alignment = .center

        for dotView in dotViews {
            dotView.backgroundColor = dotColor
            dotView.layer.cornerRadius = dotSize / 2
            dotView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dotView.widthAnchor.constraint(equalToConstant: dotSize),
                dotView.heightAnchor.constraint(equalToConstant: dotSize),
            ])
            dotStack.addArrangedSubview(dotView)
        }

        label.text = L10n.tr("Generating")
        label.font = .systemFont(ofSize: 12)
        label.textColor = UIColor(OriveoTheme.Palette.textSecondary)

        hStack.axis = .horizontal
        hStack.spacing = 8
        hStack.alignment = .center
        hStack.translatesAutoresizingMaskIntoConstraints = false
        hStack.addArrangedSubview(dotStack)
        hStack.addArrangedSubview(label)
        addSubview(hStack)

        NSLayoutConstraint.activate([
            hStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            hStack.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
            hStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
        ])
    }
}
