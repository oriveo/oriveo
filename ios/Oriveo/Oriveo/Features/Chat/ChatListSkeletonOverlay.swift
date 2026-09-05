import SwiftUI
import UIKit

final class ChatListSkeletonOverlay: UIView {

    private struct BubbleSpec {
        let leading: Bool
        let widthFactor: CGFloat
        let tinted: Bool
    }

    private static let bubbleSpecs: [BubbleSpec] = [
        BubbleSpec(leading: true, widthFactor: 0.44, tinted: false),
        BubbleSpec(leading: false, widthFactor: 0.58, tinted: true),
        BubbleSpec(leading: true, widthFactor: 0.36, tinted: false),
        BubbleSpec(leading: false, widthFactor: 0.52, tinted: true),
    ]
    private static let bubbleMaxWidthBase: CGFloat = 560
    private static let lineWidthFactors: [CGFloat] = [0.68, 0.92, 0.54]

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
        setupBubbles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupBubbles() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OriveoTheme.Spacing.xl),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OriveoTheme.Spacing.xl),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -OriveoTheme.Spacing.xl),
        ])

        for spec in Self.bubbleSpecs {
            stack.addArrangedSubview(makeBubbleRow(spec))
        }
    }

    private func makeBubbleRow(_ spec: BubbleSpec) -> UIView {
        let row = UIView()
        let bubble = makeBubble(tinted: spec.tinted)
        row.addSubview(bubble)

        let widthConstraint = bubble.widthAnchor.constraint(
            equalToConstant: Self.bubbleMaxWidthBase * spec.widthFactor)
        widthConstraint.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            widthConstraint,
            bubble.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor),
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            spec.leading
                ? bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor)
                : bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        return row
    }

    private func makeBubble(tinted: Bool) -> UIView {
        let bubble = UIView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 22
        bubble.layer.cornerCurve = .continuous
        bubble.layer.borderWidth = 1
        bubble.layer.borderColor = UIColor(OriveoTheme.Palette.hairline).cgColor
        bubble.backgroundColor = tinted
            ? UIColor(OriveoTheme.Palette.primary).withAlphaComponent(0.08)
            : UIColor(OriveoTheme.Palette.surfaceElevated)

        let lines = UIStackView()
        lines.axis = .vertical
        lines.alignment = .leading
        lines.spacing = 10
        lines.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(lines)
        NSLayoutConstraint.activate([
            lines.topAnchor.constraint(equalTo: bubble.topAnchor, constant: OriveoTheme.Spacing.md),
            lines.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: OriveoTheme.Spacing.lg),
            lines.trailingAnchor.constraint(
                lessThanOrEqualTo: bubble.trailingAnchor, constant: -OriveoTheme.Spacing.lg),
            lines.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -OriveoTheme.Spacing.md),
        ])

        for factor in Self.lineWidthFactors {
            let line = UIView()
            line.translatesAutoresizingMaskIntoConstraints = false
            line.backgroundColor = UIColor(OriveoTheme.Palette.textTertiary).withAlphaComponent(0.12)
            line.layer.cornerRadius = 5
            lines.addArrangedSubview(line)
            NSLayoutConstraint.activate([
                line.heightAnchor.constraint(equalToConstant: 10),
                line.widthAnchor.constraint(
                    equalTo: bubble.widthAnchor, multiplier: factor,
                    constant: -OriveoTheme.Spacing.lg * 2 * factor),
            ])
        }
        return bubble
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        refreshBorderColors(in: self)
    }

    private func refreshBorderColors(in view: UIView) {
        for sub in view.subviews {
            if sub.layer.borderWidth > 0 {
                sub.layer.borderColor = UIColor(OriveoTheme.Palette.hairline).cgColor
            }
            refreshBorderColors(in: sub)
        }
    }
}
