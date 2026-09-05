import SwiftUI
import UIKit

@MainActor
final class UIKitUnhandledToolCallView: UIView {
    static let argumentsByteLimit = 2048

    private let contentStack = UIStackView()
    private let headerControl = UIControl()
    private let headerStack = UIStackView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let chevronView = UIImageView()
    private let detailStack = UIStackView()
    private let detailTitleLabel = UILabel()
    private var configuredCalls: [UnhandledToolCall] = []
    private var hasConfiguredContent = false
    private(set) var isExpanded = false

#if DEBUG
    var accessibilityHeaderStateForTesting: (traits: UIAccessibilityTraits, value: String?, interactive: Bool) {
        (headerControl.accessibilityTraits, headerControl.accessibilityValue, headerControl.isUserInteractionEnabled)
    }
#endif

    var onLayoutChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(calls: [UnhandledToolCall]) {
        guard !calls.isEmpty else {
            resetForReuse()
            return
        }
        chevronView.isHidden = false
        headerControl.isUserInteractionEnabled = true
        headerControl.accessibilityTraits = .button
        titleLabel.text = Self.headline(for: calls)
        headerControl.accessibilityLabel = titleLabel.text
        if !hasConfiguredContent {
            hasConfiguredContent = true
            setExpanded(false, animated: false, notify: false)
        }
        if calls != configuredCalls {
            configuredCalls = calls
            rebuildRows(for: calls)
        }
        isHidden = false
    }

    func resetForReuse() {
        clearRows()
        configuredCalls = []
        hasConfiguredContent = false
        isExpanded = false
        detailStack.isHidden = true
        chevronView.isHidden = false
        chevronView.layer.removeAllAnimations()
        chevronView.transform = .identity
        headerControl.isUserInteractionEnabled = true
        headerControl.accessibilityTraits = .button
        headerControl.accessibilityValue = nil
        isHidden = true
    }

    static func headline(for calls: [UnhandledToolCall]) -> String {
        let names = calls.map { $0.name.isEmpty ? "?" : $0.name }
        if names.count == 1 {
            return String(
                format: L10n.tr("The model tried to use a tool (\"%@\") that isn't available on this connection.", table: .chat),
                names[0]
            )
        }
        return String(
            format: L10n.tr("The model tried to use tools (%@) that aren't available on this connection.", table: .chat),
            names.joined(separator: ", ")
        )
    }

    static func formattedArguments(_ raw: String) -> (text: String, truncated: Bool) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           JSONSerialization.isValidJSONObject(object),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let prettyText = String(data: pretty, encoding: .utf8) {
            text = prettyText
        }
        guard text.utf8.count > argumentsByteLimit else { return (text, false) }
        var scalarEnd = text.unicodeScalars.startIndex
        var usedBytes = 0
        for scalar in text.unicodeScalars {
            let width = scalar.utf8.count
            guard usedBytes + width <= argumentsByteLimit else { break }
            usedBytes += width
            scalarEnd = text.unicodeScalars.index(after: scalarEnd)
        }
        let clipped = String(text.unicodeScalars[text.unicodeScalars.startIndex..<scalarEnd])
        return (clipped + "…", true)
    }

    private func clearRows() {
        detailStack.arrangedSubviews.forEach {
            guard $0 !== detailTitleLabel else { return }
            detailStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func rebuildRows(for calls: [UnhandledToolCall]) {
        clearRows()
        for call in calls {
            detailStack.addArrangedSubview(UnhandledToolCallRow(call: call))
        }
    }

    private func setup() {
        isHidden = true
        backgroundColor = UIColor(OriveoTheme.Palette.surfaceInset)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor(OriveoTheme.Palette.border).cgColor

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = OriveoTheme.Spacing.sm
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: OriveoTheme.Spacing.sm,
            leading: OriveoTheme.Spacing.md,
            bottom: OriveoTheme.Spacing.sm,
            trailing: OriveoTheme.Spacing.md
        )
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        headerControl.addTarget(self, action: #selector(toggleExpanded), for: .touchUpInside)
        headerControl.accessibilityTraits = .button
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = OriveoTheme.Spacing.sm
        headerStack.isUserInteractionEnabled = false
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerControl.addSubview(headerStack)
        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: headerControl.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: headerControl.trailingAnchor),
            headerStack.topAnchor.constraint(equalTo: headerControl.topAnchor),
            headerStack.bottomAnchor.constraint(equalTo: headerControl.bottomAnchor),
        ])

        iconView.image = UIImage(systemName: "wrench.and.screwdriver")
        iconView.tintColor = UIColor(OriveoTheme.Palette.textTertiary)
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        headerStack.addArrangedSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])

        titleLabel.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        titleLabel.textColor = UIColor(OriveoTheme.Palette.textSecondary)
        titleLabel.numberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(titleLabel)

        chevronView.image = UIImage(systemName: "chevron.down")
        chevronView.tintColor = UIColor(OriveoTheme.Palette.textTertiary)
        chevronView.contentMode = .scaleAspectFit
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)
        headerStack.addArrangedSubview(chevronView)
        NSLayoutConstraint.activate([
            chevronView.widthAnchor.constraint(equalToConstant: 16),
            chevronView.heightAnchor.constraint(equalToConstant: 16),
        ])
        contentStack.addArrangedSubview(headerControl)

        detailStack.axis = .vertical
        detailStack.alignment = .fill
        detailStack.spacing = OriveoTheme.Spacing.sm
        detailStack.isHidden = true
        detailTitleLabel.font = UIFont.preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        detailTitleLabel.textColor = UIColor(OriveoTheme.Palette.textTertiary)
        detailTitleLabel.text = L10n.tr("Tool request", table: .chat)
        detailStack.addArrangedSubview(detailTitleLabel)
        contentStack.addArrangedSubview(detailStack)

        setContentCompressionResistancePriority(.required, for: .vertical)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func toggleExpanded() {
        setExpanded(!isExpanded, animated: true, notify: true)
    }

    private func setExpanded(_ expanded: Bool, animated: Bool, notify: Bool) {
        guard isExpanded != expanded || detailStack.isHidden == expanded else { return }
        isExpanded = expanded
        detailStack.isHidden = !expanded
        headerControl.accessibilityValue = expanded
            ? L10n.tr("Expanded", table: .chat)
            : L10n.tr("Collapsed", table: .chat)
        let transform = expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        if animated {
            chevronView.layer.removeAllAnimations()
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.chevronView.transform = transform
            }
        } else {
            chevronView.transform = transform
        }
        if notify { onLayoutChange?() }
    }
}

@MainActor
private final class UnhandledToolCallRow: UIStackView {
    private let nameLabel = UILabel()
    private let argumentsView = UITextView()
    private let truncatedLabel = UILabel()

    init(call: UnhandledToolCall) {
        super.init(frame: .zero)
        axis = .vertical
        alignment = .fill
        spacing = 4

        nameLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = UIColor(OriveoTheme.Palette.textPrimary)
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.text = call.name.isEmpty ? "?" : call.name
        addArrangedSubview(nameLabel)

        let formatted = UIKitUnhandledToolCallView.formattedArguments(call.arguments)
        if !formatted.text.isEmpty {
            argumentsView.isEditable = false
            argumentsView.isScrollEnabled = false
            argumentsView.isSelectable = true
            argumentsView.backgroundColor = .clear
            argumentsView.textContainerInset = .zero
            argumentsView.textContainer.lineFragmentPadding = 0
            argumentsView.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            argumentsView.textColor = UIColor(OriveoTheme.Palette.textSecondary)
            argumentsView.text = formatted.text
            argumentsView.setContentCompressionResistancePriority(.required, for: .vertical)
            addArrangedSubview(argumentsView)
        }
        if formatted.truncated {
            truncatedLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
            truncatedLabel.textColor = UIColor(OriveoTheme.Palette.textTertiary)
            truncatedLabel.text = L10n.tr("Truncated", table: .chat)
            addArrangedSubview(truncatedLabel)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
