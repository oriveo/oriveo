import SwiftUI

enum ProviderSummarySecondaryActionSizing: Equatable, Sendable {
    case fitContent
    case fillAvailableWidth
}

struct ProviderSummaryActionLayout: Equatable, Sendable {
    let showsActionSection: Bool
    let secondaryActionSizing: ProviderSummarySecondaryActionSizing

    var usesEqualWidthHorizontalButtons: Bool {
        secondaryActionSizing == .fillAvailableWidth
    }

    static func resolve(provider: Provider) -> Self {
        let canStartChat = provider.defaultModel != nil
        let supportsResync = provider.kind != .relay
        let usesEqualWidthHorizontalButtons = canStartChat && supportsResync

        return .init(
            showsActionSection: canStartChat || supportsResync,
            secondaryActionSizing: usesEqualWidthHorizontalButtons ? .fillAvailableWidth : .fitContent
        )
    }
}

struct ProviderDetailBrandHeroCard: View {
    let provider: Provider
    let onStartChat: () -> Void
    let onResync: () -> Void
    let onEditAPIKey: () -> Void
    var onEditName: (() -> Void)? = nil
    var onRemoveResidualAPIKey: (() -> Void)? = nil

    private var credentialEditAction: RelayCredentialPolicy.EditAction {
        provider.kind == .relay
            ? RelayCredentialPolicy.editAction(
                authMode: provider.relayRequested?.authMode,
                hasStoredKey: RelayCredentialPolicy.hasStoredKey(provider.apiKey)
            )
            : .rotate
    }

    private var canStartChat: Bool {
        provider.defaultModel != nil
    }

    private var actionLayout: ProviderSummaryActionLayout {
        ProviderSummaryActionLayout.resolve(provider: provider)
    }

    private var resyncActionTitle: String {
        L10n.tr("Verify Connection", table: .providers)
    }

    private var syncedText: String {
        provider.lastCheckedAt.map { relativeTimeText(from: $0) } ?? L10n.tr("Never")
    }

    private var modelsText: String {
        String(format: L10n.tr("%lld available models", table: .providers), Int64(provider.enabledModelCount))
    }

    private var resolvedLogoKind: ProviderKind {
        ProviderLogoResolver.logoKind(for: provider)
    }

    private var resolvedRelayKind: RelayKind? {
        provider.kind == .relay && resolvedLogoKind == .relay ? provider.relayKind : nil
    }

    private var brandColor: Color {
        let kind = resolvedLogoKind
        if kind == .relay {
            return OriveoTheme.Palette.primary
        }
        return kind.chartFill
    }

    private var subduedBrand: Color {
        if resolvedLogoKind == .grok {
            return Color.dynamic(light: 0x2E3036, dark: 0x2E3036)
        }
        return brandColor.hsbAdjusted(saturation: 0.62, brightness: 0.88)
    }

    private var needsKeyOnThisDevice: Bool {
        provider.effectiveStatusKind == .needsKey
    }

    private var statusColor: Color {
        switch provider.effectiveStatusKind {
        case .connected: return Color(red: 0.36, green: 0.96, blue: 0.66)
        case .syncing:   return .white
        case .issue, .needsKey: return Color(red: 1.0, green: 0.82, blue: 0.34)
        }
    }

    private var statusPulsing: Bool {
        if case .syncing = provider.status { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            watermark

            VStack(alignment: .leading, spacing: 12) {
                topRow
                nameAndMeta
                apiKeyRow
                actionsSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(OriveoTheme.Palette.border, lineWidth: 0.6)
        )
        .shadow(
            color: OriveoTheme.Palette.shadow,
            radius: 16,
            x: 0,
            y: 8
        )
        .frame(maxWidth: .infinity)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Background

    private var background: some View {
        brandedBackground
            .allowsHitTesting(false)
    }

    private var brandedBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    subduedBrand.blended(with: .white, fraction: 0.06),
                    subduedBrand.blended(with: .black, fraction: 0.22)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.white.opacity(0.16), Color.white.opacity(0.0)],
                center: UnitPoint(x: 0.92, y: -0.05),
                startRadius: 0,
                endRadius: 280
            )
            .blendMode(.plusLighter)

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.18)],
                startPoint: .center,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.06),
                    Color.white.opacity(0)
                ],
                startPoint: .init(x: 0.2, y: -0.1),
                endPoint: .init(x: 0.4, y: 1.2)
            )
            .blendMode(.softLight)
        }
    }

    // MARK: - Watermark

    private var watermarkAssetName: String? {
        let kind = resolvedLogoKind
        if kind == .relay || kind.brandLogoIsOpaqueTile { return nil }
        return kind.brandAssetName
    }

    private var watermark: some View {
        Group {
            if let asset = watermarkAssetName {
                Color.white
                    .opacity(0.10)
                    .frame(width: 200, height: 200)
                    .mask {
                        Image(asset)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                    }
            } else {
                Image(systemName: resolvedLogoKind.brandWatermarkSymbol)
                    .font(.system(size: 164, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.10))
                    .frame(width: 200, height: 200)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .offset(x: 50, y: 40)
        .allowsHitTesting(false)
    }

    // MARK: - Top row: badge + status capsule

    private var topRow: some View {
        HStack(alignment: .center, spacing: 12) {
            ProviderBadgeIcon(
                kind: resolvedLogoKind,
                size: 48,
                relayKind: resolvedRelayKind
            )

            Spacer(minLength: 0)

            statusCapsule
        }
    }

    private var statusCapsule: some View {
        HStack(spacing: 6) {
            OriveoStatusDot(color: statusColor, size: 6, pulsing: statusPulsing)

            Text(provider.effectiveStatusTitle)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.22))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.30), lineWidth: 0.6)
        )
    }

    // MARK: - Name + meta

    private var nameAndMeta: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(provider.displayName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                if let onEditName {
                    Button(action: onEditName) {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("Edit"))
                }
            }

            HStack(spacing: 8) {
                Text(modelsText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(1)

                Circle()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 3.5, height: 3.5)

                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(syncedText)
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - API Key row

    @ViewBuilder
    private var apiKeyRow: some View {
        if credentialEditAction == .rotate {
            Button(action: onEditAPIKey) {
                let isSubscription = provider.authMode == .subscription
                HStack(spacing: 12) {
                    Image(systemName: isSubscription ? "person.badge.key.fill" : "key.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.22)))
                        .overlay(Circle().stroke(Color.white.opacity(0.30), lineWidth: 0.6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(isSubscription
                             ? L10n.tr("Subscription", table: .providers)
                             : L10n.tr("API Key", table: .providers))
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)

                        Text(isSubscription
                             ? (provider.kind == .openAI
                                ? L10n.tr("Signed in with ChatGPT", table: .providers)
                                : L10n.tr("Signed in with x.ai", table: .providers))
                             : apiKeyDisplayValue)
                            .font(.system(
                                size: 13.5,
                                weight: .semibold,
                                design: isSubscription ? .default : .monospaced
                            ))
                            .foregroundStyle(isSubscription ? Color.white : apiKeyTextColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .monospacedDigit()
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.18))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        } else if provider.kind == .relay,
                  credentialEditAction == .removeResidual,
                  let onRemoveResidualAPIKey {
            Button(action: onRemoveResidualAPIKey) {
                Label(L10n.tr("Remove stored key", table: .providers), systemImage: "key.slash")
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
        }
    }

    private var apiKeyDisplayValue: String {
        if needsKeyOnThisDevice { return L10n.tr("Tap to set", table: .providers) }
        guard RelayCredentialPolicy.requiresCredential(provider.relayRequested) else {
            return L10n.tr("This connection doesn't need a key", table: .providers)
        }
        let preview = provider.apiKeyPreview
        if !preview.isEmpty { return preview }
        switch provider.status {
        case .connected, .syncing:
            return L10n.tr("Tap to view", table: .providers)
        case .issue:
            return L10n.tr("Tap to set", table: .providers)
        }
    }

    private var apiKeyTextColor: Color {
        provider.apiKeyPreview.isEmpty ? .white.opacity(0.78) : .white
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        if actionLayout.showsActionSection {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    primaryAction
                    secondaryAction
                }

                VStack(spacing: 10) {
                    primaryAction
                    stackedSecondaryAction
                }
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if canStartChat {
            Button(action: onStartChat) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.bubble.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(L10n.tr("New Chat"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(HeroPrimaryButtonStyle(brandColor: subduedBrand))
        } else {
            Button {
                onResync()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                    Text(provider.status == .syncing ? L10n.tr("Syncing...", table: .providers) : resyncActionTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(provider.status == .syncing)
            .buttonStyle(HeroPrimaryButtonStyle(brandColor: subduedBrand))
        }
    }

    @ViewBuilder
    private var secondaryAction: some View {
        if canStartChat {
            Button {
                onResync()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text(provider.status == .syncing ? L10n.tr("Syncing...", table: .providers) : resyncActionTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: actionLayout.secondaryActionSizing == .fillAvailableWidth ? .infinity : nil)
            }
            .disabled(provider.status == .syncing)
            .buttonStyle(HeroSecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private var stackedSecondaryAction: some View {
        if canStartChat {
            Button {
                onResync()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text(provider.status == .syncing ? L10n.tr("Syncing...", table: .providers) : resyncActionTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(provider.status == .syncing)
            .buttonStyle(HeroSecondaryButtonStyle())
        }
    }
}

private struct HeroPrimaryButtonStyle: ButtonStyle {
    let brandColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(brandColor.hsbAdjusted(saturation: 0.85, brightness: 0.55))
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.86 : 0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 0.5)
            )
    }
}

private struct HeroSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.72 : 0.95))
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.20))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
            )
    }
}

enum ProviderSummaryPresentation {
    static func showsInlineErrorBanner(for provider: Provider) -> Bool {
        false
    }
}

struct ProviderSectionHeader: View {
    let title: String
    var trailing: String?
    var helpMessage: String? = nil

    @State private var showingHelp = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Capsule(style: .continuous)
                .fill(OriveoTheme.Palette.primary)
                .frame(width: 4, height: 20)

            Text(title)
                .font(OriveoTheme.Typography.title2.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            if let helpMessage {
                Button {
                    showingHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(helpMessage)
                .alert(title, isPresented: $showingHelp) {
                    Button(L10n.tr("OK"), role: .cancel) {}
                } message: {
                    Text(helpMessage)
                }
            }

            Spacer(minLength: 0)

            if let trailing {
                Text(trailing)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .monospacedDigit()
            }
        }
    }
}
