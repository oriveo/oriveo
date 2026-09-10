import SwiftUI
import UIKit

final class UIKitProviderBadge: UIView {
    private let logoImageView = UIImageView()

    private var currentKind: ProviderKind?
    private var currentRelayKind: RelayKind?
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

    func configure(kind: ProviderKind, relayKind: RelayKind? = nil, size: CGFloat = 28) {
        if currentKind == kind, currentRelayKind == relayKind { return }
        currentKind = kind
        currentRelayKind = relayKind
        clipsToBounds = false
        setNeedsLayout()

        applyAppearance(for: kind, relayKind: relayKind)

        logoImageView.contentMode = .scaleAspectFit

        if kind == .relay {
            if let assetName = RelayKindAssetResolver.assetName(for: relayKind) {
                backgroundColor = .clear
                logoImageView.image = UIImage(named: assetName)
                logoImageView.tintColor = nil
                logoImageView.preferredSymbolConfiguration = nil
                updateLogoPadding(ProviderBadgeLogoMetrics.brandInset(for: size))
            } else {
                backgroundColor = UIColor(OriveoTheme.Palette.primarySoft)
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
        logoImageView.image = nil
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
    }

    private func updateLogoPadding(_ padding: CGFloat) {
        logoLeading.constant = padding
        logoTrailing.constant = -padding
        logoTop.constant = padding
        logoBottom.constant = -padding
    }

    private func applyAppearance(for kind: ProviderKind, relayKind: RelayKind?) {
        if kind == .relay && RelayKindAssetResolver.assetName(for: relayKind) == nil {
            backgroundColor = UIColor(red: 0.96, green: 0.95, blue: 1.0, alpha: 1.0)
        } else {
            backgroundColor = .clear
        }
    }
}
