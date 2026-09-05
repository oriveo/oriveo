import SwiftUI
import UIKit

final class UIKitRecoveryCard: UIView {
    static let fixedButtonHeight: CGFloat = 48
    static let fixedButtonHeightPriority = UILayoutPriority(999)

    struct Config {
        let title: String
        let message: String
        let primaryTitle: String
        let secondaryTitle: String?
        let tertiaryTitle: String?
        let tone: StatusTone
        let technicalDetail: String?
        let actionsEnabled: Bool
        let primaryAction: () -> Void
        let secondaryAction: (() -> Void)?
        let tertiaryAction: (() -> Void)?
        let onDismiss: (() -> Void)?
        var primaryRevealsTechnicalDetail: Bool = false
        var showsTechnicalDetail: Bool = false
        var onTechnicalDetailVisibilityChanged: ((Bool) -> Void)? = nil
        var onLayoutChange: (() -> Void)? = nil
    }

    private let config: Config

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private let tertiaryButton = UIButton(type: .system)
    private let detailToggleButton = UIButton(type: .system)
    private let detailLabel = UILabel()
    private let detailContainer = UIView()
    private let dismissButton = UIButton(type: .system)

    private var showsTechnicalDetail: Bool

    init(config: Config) {
        self.config = config
        showsTechnicalDetail = config.showsTechnicalDetail
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        let toneFg = UIColor(config.tone.foreground)
        let toneBg = UIColor(config.tone.background)
        let toneBorder = toneFg.withAlphaComponent(0.24)

        backgroundColor = toneBg
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = toneBorder.cgColor
        clipsToBounds = true

        let mainStack = UIStackView()
        mainStack.axis = .vertical
        mainStack.alignment = .fill
        mainStack.spacing = OriveoTheme.Spacing.md
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = OriveoTheme.Spacing.sm

        let iconName = config.tone == .danger ? "xmark.circle.fill" : "exclamationmark.circle.fill"
        iconView.image = UIImage(systemName: iconName)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        iconView.tintColor = toneFg
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        headerRow.addArrangedSubview(iconView)

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 6

        titleLabel.text = config.title
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = UIColor(OriveoTheme.Palette.textPrimary)
        titleLabel.numberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        textStack.addArrangedSubview(titleLabel)

        messageLabel.text = config.message
        messageLabel.font = .systemFont(ofSize: 16)
        messageLabel.textColor = UIColor(OriveoTheme.Palette.textSecondary)
        messageLabel.numberOfLines = 0
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        textStack.addArrangedSubview(messageLabel)

        headerRow.addArrangedSubview(textStack)
        mainStack.addArrangedSubview(headerRow)

        let buttonRow = UIStackView()
        buttonRow.axis = .horizontal
        buttonRow.spacing = OriveoTheme.Spacing.sm
        buttonRow.distribution = .fillEqually

        configurePrimaryButton(primaryButton, title: config.primaryTitle)
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        primaryButton.isEnabled = config.actionsEnabled
        primaryButton.alpha = config.actionsEnabled ? 1 : 0.6
        buttonRow.addArrangedSubview(primaryButton)

        if let secondaryTitle = config.secondaryTitle, config.secondaryAction != nil {
            configureSecondaryButton(secondaryButton, title: secondaryTitle)
            secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)
            secondaryButton.isEnabled = config.actionsEnabled
            secondaryButton.alpha = config.actionsEnabled ? 1 : 0.6
            buttonRow.addArrangedSubview(secondaryButton)
        }

        mainStack.addArrangedSubview(buttonRow)

        if let tertiaryTitle = config.tertiaryTitle, config.tertiaryAction != nil {
            configureTextButton(tertiaryButton, title: tertiaryTitle)
            tertiaryButton.addTarget(self, action: #selector(tertiaryTapped), for: .touchUpInside)
            tertiaryButton.isEnabled = config.actionsEnabled
            tertiaryButton.alpha = config.actionsEnabled ? 1 : 0.4
            mainStack.addArrangedSubview(tertiaryButton)
        }

        if let detail = config.technicalDetail, !detail.isEmpty {
            configureTextButton(
                detailToggleButton,
                title: showsTechnicalDetail ? L10n.tr("Hide technical details") : L10n.tr("Technical details")
            )
            detailToggleButton.addTarget(self, action: #selector(toggleDetail), for: .touchUpInside)
            mainStack.addArrangedSubview(detailToggleButton)

            detailContainer.backgroundColor = UIColor(OriveoTheme.Palette.surfaceInset)
            detailContainer.layer.cornerRadius = 8
            detailContainer.layer.cornerCurve = .continuous
            detailContainer.layer.borderWidth = 1
            detailContainer.layer.borderColor = UIColor(OriveoTheme.Palette.border).cgColor
            detailContainer.isHidden = !showsTechnicalDetail
            detailContainer.alpha = showsTechnicalDetail ? 1 : 0

            detailLabel.text = detail
            detailLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            detailLabel.textColor = UIColor(OriveoTheme.Palette.textSecondary)
            detailLabel.numberOfLines = 0
            detailLabel.setContentCompressionResistancePriority(.required, for: .vertical)
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            detailContainer.addSubview(detailLabel)

            NSLayoutConstraint.activate([
                detailLabel.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: OriveoTheme.Spacing.md),
                detailLabel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: OriveoTheme.Spacing.md),
                detailLabel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -OriveoTheme.Spacing.md),
                detailLabel.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor, constant: -OriveoTheme.Spacing.md),
            ])
            mainStack.addArrangedSubview(detailContainer)
        }

        if config.onDismiss != nil {
            dismissButton.setImage(
                UIImage(systemName: "xmark")?
                    .withConfiguration(UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)),
                for: .normal
            )
            dismissButton.tintColor = UIColor(OriveoTheme.Palette.textTertiary)
            dismissButton.translatesAutoresizingMaskIntoConstraints = false
            dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
            addSubview(dismissButton)

            NSLayoutConstraint.activate([
                dismissButton.topAnchor.constraint(equalTo: topAnchor, constant: OriveoTheme.Spacing.sm),
                dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OriveoTheme.Spacing.sm),
                dismissButton.widthAnchor.constraint(equalToConstant: 32),
                dismissButton.heightAnchor.constraint(equalToConstant: 32),
            ])

            titleLabel.textAlignment = .natural
        }

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: OriveoTheme.Spacing.lg),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OriveoTheme.Spacing.lg),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OriveoTheme.Spacing.lg),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -OriveoTheme.Spacing.lg),
        ])
    }


    private func configurePrimaryButton(_ button: UIButton, title: String) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(OriveoTheme.Palette.primary)
        config.cornerStyle = .medium
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
            return outgoing
        }
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = button.heightAnchor.constraint(equalToConstant: Self.fixedButtonHeight)
        heightConstraint.priority = Self.fixedButtonHeightPriority
        heightConstraint.isActive = true
    }

    private func configureSecondaryButton(_ button: UIButton, title: String) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = UIColor(OriveoTheme.Palette.primary)
        config.baseBackgroundColor = UIColor(OriveoTheme.Palette.surfaceChrome)
        config.cornerStyle = .medium
        config.background.strokeColor = UIColor(OriveoTheme.Palette.borderStrong)
        config.background.strokeWidth = 1
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
            return outgoing
        }
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        let heightConstraint = button.heightAnchor.constraint(equalToConstant: Self.fixedButtonHeight)
        heightConstraint.priority = Self.fixedButtonHeightPriority
        heightConstraint.isActive = true
    }

    private func configureTextButton(_ button: UIButton, title: String) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = UIColor(OriveoTheme.Palette.primary)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 14)
            return outgoing
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        button.configuration = config
        button.contentHorizontalAlignment = .leading
    }

    // MARK: - Actions

    @objc private func primaryTapped() {
        if config.primaryRevealsTechnicalDetail {
            setTechnicalDetailVisible(true)
            return
        }
        config.primaryAction()
    }

    @objc private func secondaryTapped() { config.secondaryAction?() }
    @objc private func tertiaryTapped() { config.tertiaryAction?() }
    @objc private func dismissTapped() { config.onDismiss?() }

    @objc private func toggleDetail() {
        setTechnicalDetailVisible(!showsTechnicalDetail)
    }

    private func setTechnicalDetailVisible(_ visible: Bool) {
        guard showsTechnicalDetail != visible else { return }
        showsTechnicalDetail = visible
        config.onTechnicalDetailVisibilityChanged?(showsTechnicalDetail)
        if showsTechnicalDetail {
            detailContainer.isHidden = false
        }
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: .curveEaseInOut,
            animations: {
                self.detailContainer.alpha = self.showsTechnicalDetail ? 1 : 0
            },
            completion: { [weak self] _ in
                if self?.showsTechnicalDetail == false {
                    self?.detailContainer.isHidden = true
                }
                self?.config.onLayoutChange?()
            }
        )
        var config = detailToggleButton.configuration ?? .plain()
        config.title = showsTechnicalDetail
            ? L10n.tr("Hide technical details")
            : L10n.tr("Technical details")
        detailToggleButton.configuration = config
    }
}
