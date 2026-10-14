import SwiftUI
import UIKit

final class UIKitProviderBadge: UIView {
    private let logoImageView = UIImageView()
    /// Initial letter of a relay avatar: neutral secondary text color, no backing plate, no outline.
    private let initialLabel = UILabel()

    private var currentKind: ProviderKind?
    private var currentRelayKind: RelayKind?
    private var currentRelayAvatar: RelayAvatar?
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        logoImageView.layer.cornerRadius = 0
        logoImageView.clipsToBounds = false
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            if let kind = currentKind {
                applyAppearance(for: kind, relayKind: currentRelayKind)
            }
        }
    }

    /// A non-nil `relayAvatar` means a relay connection: draw the unified avatar and ignore relayKind.
    func configure(kind: ProviderKind, relayKind: RelayKind? = nil, relayAvatar: RelayAvatar? = nil, size: CGFloat = 28) {
        if currentKind == kind, currentRelayKind == relayKind, currentRelayAvatar == relayAvatar { return }
        currentKind = kind
        currentRelayKind = relayKind
        currentRelayAvatar = relayAvatar
        initialLabel.isHidden = true
        logoImageView.isHidden = false
        clipsToBounds = false
        setNeedsLayout()

        applyAppearance(for: kind, relayKind: relayKind)

        logoImageView.contentMode = .scaleAspectFit

        if let relayAvatar {
            backgroundColor = .clear
            logoImageView.tintColor = nil
            logoImageView.preferredSymbolConfiguration = nil
            switch relayAvatar {
            case let .brand(assetName):
                logoImageView.image = UIImage(named: assetName)
                updateLogoPadding(ProviderBadgeLogoMetrics.brandInset(for: size))
            case let .initial(text):
                logoImageView.image = nil
                logoImageView.isHidden = true
                initialLabel.text = text
                initialLabel.font = .systemFont(ofSize: size * 0.6, weight: .semibold)
                initialLabel.isHidden = false
            case .generic:
                logoImageView.image = UIImage(named: "ProviderRelay")
                updateLogoPadding((size - ProviderBadgeLogoMetrics.relayFallbackContentSize(for: size)) / 2)
            }
        } else if kind == .relay {
            if let assetName = RelayKindAssetResolver.assetName(for: relayKind) {
                backgroundColor = .clear
                logoImageView.image = UIImage(named: assetName)
                logoImageView.tintColor = nil
                logoImageView.preferredSymbolConfiguration = nil
                updateLogoPadding(ProviderBadgeLogoMetrics.brandInset(for: size))
            } else {
                // Relay custom or unset: the brand logo on a clear background (no plate, matching the top bar and the picker).
                backgroundColor = .clear
                logoImageView.image = UIImage(named: "ProviderRelay")
                logoImageView.tintColor = nil
                logoImageView.preferredSymbolConfiguration = nil
                updateLogoPadding((size - ProviderBadgeLogoMetrics.relayFallbackContentSize(for: size)) / 2)
            }
        } else {
            backgroundColor = .clear
            logoImageView.image = UIImage(named: kind.brandAssetName)
            logoImageView.tintColor = nil
            logoImageView.preferredSymbolConfiguration = nil
            updateLogoPadding(ProviderBadgeLogoMetrics.contentInset(for: kind, size: size))
        }
    }

    func resetForReuse() {
        currentKind = nil
        currentRelayKind = nil
        currentRelayAvatar = nil
        logoImageView.image = nil
        logoImageView.isHidden = false
        initialLabel.text = nil
        initialLabel.isHidden = true
        logoImageView.layer.cornerRadius = 0
        logoImageView.clipsToBounds = false
        backgroundColor = .clear
        clipsToBounds = false
    }

    // MARK: - Private

    private var logoLeading: NSLayoutConstraint!
    private var logoTrailing: NSLayoutConstraint!
    private var logoTop: NSLayoutConstraint!
    private var logoBottom: NSLayoutConstraint!

    private func setupViews() {
        clipsToBounds = false

        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logoImageView)

        logoLeading = logoImageView.leadingAnchor.constraint(equalTo: leadingAnchor)
        logoTrailing = logoImageView.trailingAnchor.constraint(equalTo: trailingAnchor)
        logoTop = logoImageView.topAnchor.constraint(equalTo: topAnchor)
        logoBottom = logoImageView.bottomAnchor.constraint(equalTo: bottomAnchor)

        NSLayoutConstraint.activate([logoLeading, logoTrailing, logoTop, logoBottom])

        initialLabel.translatesAutoresizingMaskIntoConstraints = false
        initialLabel.textAlignment = .center
        initialLabel.textColor = UIColor(OriveoTheme.Palette.textSecondary)
        initialLabel.adjustsFontSizeToFitWidth = true
        initialLabel.minimumScaleFactor = 0.5
        initialLabel.isHidden = true
        initialLabel.isAccessibilityElement = false
        addSubview(initialLabel)
        NSLayoutConstraint.activate([
            initialLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            initialLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            initialLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func updateLogoPadding(_ padding: CGFloat) {
        logoLeading.constant = padding
        logoTrailing.constant = -padding
        logoTop.constant = padding
        logoBottom.constant = -padding
    }

    private func applyAppearance(for kind: ProviderKind, relayKind: RelayKind?) {
        backgroundColor = .clear
    }
}
