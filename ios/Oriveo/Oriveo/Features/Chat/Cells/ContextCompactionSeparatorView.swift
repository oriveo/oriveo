import SwiftUI
import UIKit

/// Transcript separator for the latestValid checkpoint (P3·U4 contract item 1), drawn at the top of the
/// first message after `coversTo`. Hairlines on both sides, two centered secondary lines (tabular digits),
/// a trailing chevron on line 2; the whole row is one button that opens the checkpoint detail.
final class ContextCompactionSeparatorView: UIControl {
    /// Vertical padding around the two lines; `ChatListViewController.compactionSeparatorHeight` mirrors it.
    nonisolated static let topInset: CGFloat = 8
    nonisolated static let bottomInset: CGFloat = 12

    var onTap: (() -> Void)?

    private let leadingLine = UIView()
    private let trailingLine = UIView()
    private let textStack = UIStackView()
    private let secondRow = UIStackView()
    private let firstLabel = UILabel()
    private let secondLabel = UILabel()
    private let chevron = UIImageView()
    private(set) var separator: ContextCompactionSeparator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Applies the separator (nil hides the row). Returns whether the visible content changed.
    @discardableResult
    func apply(_ next: ContextCompactionSeparator?) -> Bool {
        guard next != separator || isHidden != (next == nil) else { return false }
        separator = next
        isHidden = next == nil
        guard let next else {
            firstLabel.text = nil
            secondLabel.text = nil
            accessibilityLabel = nil
            return true
        }
        let lines = Self.lines(for: next)
        firstLabel.text = lines.first
        secondLabel.text = lines.second
        accessibilityLabel = lines.first + "\n" + lines.second
        return true
    }

    /// Localized two-line text; counts use the compact notation of the token usage menu.
    static func lines(for separator: ContextCompactionSeparator) -> (first: String, second: String) {
        switch separator.kind {
        case .summary:
            return (
                L10n.format(
                    L10n.tr("context_compaction_summary_line1", table: .chat),
                    separator.count,
                    ContextCompactionSeparator.compactCount(separator.before ?? 0),
                    ContextCompactionSeparator.compactCount(separator.after ?? 0)
                ),
                L10n.format(L10n.tr("context_compaction_summary_line2", table: .chat), separator.model)
            )
        case .fallback:
            return (
                L10n.format(L10n.tr("context_compaction_fallback_line1", table: .chat), separator.count),
                L10n.format(L10n.tr("context_compaction_fallback_line2", table: .chat), separator.kept)
            )
        }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }

    @objc private func tapped() {
        onTap?()
    }

    private func setup() {
        isHidden = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "chat_context_compaction_separator"
        addTarget(self, action: #selector(tapped), for: .touchUpInside)

        let color = UIColor(OriveoTheme.Palette.textSecondary)
        let font = UIFontMetrics(forTextStyle: .caption1)
            .scaledFont(for: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular))
        for label in [firstLabel, secondLabel] {
            label.font = font
            label.adjustsFontForContentSizeCategory = true
            label.textColor = color
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        chevron.image = UIImage(
            systemName: "chevron.forward",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        )
        chevron.tintColor = color
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        secondRow.axis = .horizontal
        secondRow.alignment = .center
        secondRow.spacing = 3
        secondRow.addArrangedSubview(secondLabel)
        secondRow.addArrangedSubview(chevron)

        textStack.axis = .vertical
        textStack.alignment = .center
        textStack.spacing = 2
        textStack.addArrangedSubview(firstLabel)
        textStack.addArrangedSubview(secondRow)

        let lineColor = UIColor(OriveoTheme.Palette.borderStrong)
        for line in [leadingLine, trailingLine] {
            line.backgroundColor = lineColor
        }
        for view in [textStack, leadingLine, trailingLine] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }

        let hairline = 1 / max(1, UIScreen.main.scale)
        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: Self.topInset),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomInset),
            textStack.centerXAnchor.constraint(equalTo: centerXAnchor),

            leadingLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingLine.trailingAnchor.constraint(equalTo: textStack.leadingAnchor, constant: -10),
            leadingLine.centerYAnchor.constraint(equalTo: textStack.centerYAnchor),
            leadingLine.heightAnchor.constraint(equalToConstant: hairline),
            leadingLine.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),

            trailingLine.leadingAnchor.constraint(equalTo: textStack.trailingAnchor, constant: 10),
            trailingLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingLine.centerYAnchor.constraint(equalTo: textStack.centerYAnchor),
            trailingLine.heightAnchor.constraint(equalToConstant: hairline),
            trailingLine.widthAnchor.constraint(equalTo: leadingLine.widthAnchor),
        ])
    }
}
