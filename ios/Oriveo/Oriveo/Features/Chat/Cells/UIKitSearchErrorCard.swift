import SwiftUI
import UIKit

/// External search error card: the answer is still delivered; the card explains which search service failed and why, and that this answer did not use web search.
/// The primary button follows primaryAction; the secondary button is "Answer again with X". Pure UIKit (same as UIKitRecoveryCard, to avoid embedding a UIHostingController in the cell).
final class UIKitSearchErrorCard: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let buttonRow = UIStackView()
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private var presentation: SearchErrorCardPresentation?

    var onAction: ((ExternalSearchCardAction) -> Void)?

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Returns true if the content changed (the caller uses it to signal a height change).
    @discardableResult
    func apply(_ presentation: SearchErrorCardPresentation?) -> Bool {
        guard presentation != self.presentation else { return false }
        self.presentation = presentation
        isHidden = presentation == nil
        guard let presentation else { return true }
        titleLabel.text = presentation.title
        detailLabel.text = presentation.detail
        configure(primaryButton, presentation.primary, primary: true)
        configure(secondaryButton, presentation.secondary, primary: false)
        buttonRow.isHidden = presentation.primary == nil && presentation.secondary == nil
        accessibilityElements = [titleLabel, detailLabel, primaryButton, secondaryButton].filter { !$0.isHidden }
        return true
    }

    private func configure(_ button: UIButton, _ model: SearchErrorCardPresentation.Button?, primary: Bool) {
        button.isHidden = model == nil
        guard let model else { return }
        var config = primary ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.title = model.title
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.baseForegroundColor = primary ? OriveoTheme.Palette.onPrimaryUIColor : UIColor(OriveoTheme.Palette.textPrimary)
        if primary { config.baseBackgroundColor = OriveoTheme.Palette.primaryUIColor }
        if model.external {
            config.image = UIImage(systemName: "arrow.up.right")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            config.imagePlacement = .trailing
            config.imagePadding = 4
        }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return outgoing
        }
        button.configuration = config
        button.accessibilityTraits = model.external ? [.button, .link] : .button
    }

    @objc private func primaryTapped() {
        if let action = presentation?.primary?.action { onAction?(action) }
    }

    @objc private func secondaryTapped() {
        if let action = presentation?.secondary?.action { onAction?(action) }
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        backgroundColor = UIColor(OriveoTheme.Palette.warningSoft)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(OriveoTheme.Palette.warningLine).cgColor

        let main = UIStackView()
        main.axis = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.translatesAutoresizingMaskIntoConstraints = false
        addSubview(main)
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            main.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            main.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            main.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        let header = UIStackView()
        header.axis = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(textStyle: .subheadline))
        iconView.tintColor = UIColor(OriveoTheme.Palette.warning)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.isAccessibilityElement = false

        let texts = UIStackView()
        texts.axis = .vertical
        texts.spacing = 2
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = UIColor(OriveoTheme.Palette.textPrimary)
        titleLabel.numberOfLines = 0
        detailLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = UIColor(OriveoTheme.Palette.textSecondary)
        detailLabel.numberOfLines = 0
        for label in [titleLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            texts.addArrangedSubview(label)
        }
        header.addArrangedSubview(iconView)
        header.addArrangedSubview(texts)
        main.addArrangedSubview(header)

        buttonRow.axis = .horizontal
        buttonRow.alignment = .center
        buttonRow.spacing = 8
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)
        for button in [primaryButton, secondaryButton] {
            button.setContentCompressionResistancePriority(.required, for: .vertical)
            buttonRow.addArrangedSubview(button)
        }
        main.addArrangedSubview(buttonRow)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = UIColor(OriveoTheme.Palette.warningLine).cgColor
    }

    #if DEBUG
    var _testPrimaryTitle: String? { primaryButton.isHidden ? nil : primaryButton.configuration?.title }
    var _testSecondaryTitle: String? { secondaryButton.isHidden ? nil : secondaryButton.configuration?.title }
    #endif
}

/// Search-term chips under the external search activity row: appended per call, the one currently searching shows a spinner.
final class UIKitSearchQueryChips: UIView {
    private let stack = UIStackView()
    private var trail: ExternalSearchActivityTrail?

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Returns true if the content changed.
    @discardableResult
    func apply(_ trail: ExternalSearchActivityTrail?) -> Bool {
        guard trail != self.trail else { return false }
        self.trail = trail
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let trail else { return true }
        for (index, query) in trail.queries.enumerated() {
            let searching = trail.inFlight && index == trail.queries.count - 1
            stack.addArrangedSubview(Self.chip(ExternalSearchActivityTrail.chipText(query), searching: searching))
        }
        return true
    }

    private static func chip(_ text: String, searching: Bool) -> UIView {
        let chip = UIStackView()
        chip.axis = .horizontal
        chip.alignment = .center
        chip.spacing = 5
        chip.isLayoutMarginsRelativeArrangement = true
        chip.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        chip.backgroundColor = UIColor(OriveoTheme.Palette.surfaceInset)
        chip.layer.cornerRadius = 12
        chip.layer.cornerCurve = .continuous
        chip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if searching {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            spinner.color = UIColor(OriveoTheme.Palette.textTertiary)
            spinner.startAnimating()
            spinner.setContentHuggingPriority(.required, for: .horizontal)
            spinner.widthAnchor.constraint(equalToConstant: 12).isActive = true
            spinner.heightAnchor.constraint(equalToConstant: 12).isActive = true
            chip.addArrangedSubview(spinner)
        } else {
            let icon = UIImageView(image: UIImage(systemName: "magnifyingglass")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)))
            icon.tintColor = UIColor(OriveoTheme.Palette.textTertiary)
            icon.setContentHuggingPriority(.required, for: .horizontal)
            chip.addArrangedSubview(icon)
        }
        let label = UILabel()
        label.text = text
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor(OriveoTheme.Palette.textSecondary)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        chip.addArrangedSubview(label)
        chip.isAccessibilityElement = true
        chip.accessibilityLabel = text
        return chip
    }

    #if DEBUG
    var _testChipCount: Int { stack.arrangedSubviews.count }
    #endif
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
