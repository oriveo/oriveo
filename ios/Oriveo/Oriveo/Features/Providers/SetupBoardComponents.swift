import SwiftUI

// MARK: - Shared parts of the add-page boards (Setup / LocalSetup)

/// Hero, text only: small label + two-tone icon -> large title (accessibility heading, the page's only title) -> subtitle.
struct SetupBoardHero: View {
    let icon: PhosphorIcon
    let labelKey: String
    let titleKey: String
    let subtitleKey: String
    /// Trailing tag of the small-label line (the manual setup page tags "Manual setup"); when not given, it is exactly as before.
    var trailingKey: String? = nil

    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                icon.image(.duotone)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .accessibilityHidden(true)

                Text(L10n.tr(labelKey, table: .providers))
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let trailingKey {
                    Spacer(minLength: OriveoTheme.Spacing.sm)
                    Text(L10n.tr(trailingKey, table: .providers))
                        .font(OriveoTheme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }

            Text(L10n.tr(titleKey, table: .providers))
                .font(OriveoTheme.Typography.hero)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(L10n.tr(subtitleKey, table: .providers))
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, OriveoTheme.Spacing.sm)
        .padding(.bottom, OriveoTheme.Spacing.xs)
    }
}

/// Check card shell: light fill + stroke of the same color.
struct SetupDetectionCardSurface<Content: View>: View {
    enum Tone {
        case progress
        case success
        case warning
    }

    let tone: Tone
    /// Pass `.contain` when the card holds operable controls (the collapsed list under a relay failure item); by default the whole card is read out as one.
    var accessibilityChildren: AccessibilityChildBehavior = .combine
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            content
        }
        .padding(OriveoTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
            ZStack {
                shape.fill(fill)
                shape.stroke(stroke, lineWidth: 1)
            }
        }
        .accessibilityElement(children: accessibilityChildren)
    }

    private var fill: Color {
        switch tone {
        case .progress: OriveoTheme.Palette.primarySoft.opacity(0.62)
        case .success: OriveoTheme.Palette.successSoft
        case .warning: OriveoTheme.Palette.warningSoft
        }
    }

    private var stroke: Color {
        switch tone {
        case .progress: OriveoTheme.Palette.primary.opacity(0.3)
        case .success: OriveoTheme.Palette.success.opacity(0.45)
        case .warning: OriveoTheme.Palette.warning.opacity(0.3)
        }
    }
}

/// Check card verdict row: icon + title + optional second line.
struct SetupDetectionHeadline: View {
    let icon: PhosphorIcon?
    let tint: Color
    let title: String
    var detail: String? = nil
    var showsProgress = false

    var body: some View {
        HStack(alignment: .top, spacing: OriveoTheme.Spacing.md) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
            } else if let icon {
                icon.image(.duotone)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OriveoTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Relay protocol ratio bar and legend. Colors come only from existing brand color tokens: Chat = OpenAI green, Responses = the same color at 60%,
/// Messages = Anthropic, Gemini = Gemini blue.
struct RelayProtocolMixBar: View {
    let shares: [RelayProtocolShare]

    static func color(for transport: RelayTransport) -> Color {
        switch transport {
        case .openaiResponses: ProviderTints.tint(for: "openai").opacity(0.6)
        case .anthropicMessages: ProviderTints.tint(for: "anthropic")
        case .geminiGenerateContent: ProviderTints.tint(for: "gemini")
        case .openaiChatCompletions, .auto, .llamacppNative: ProviderTints.tint(for: "openai")
        }
    }

    var body: some View {
        let total = max(1, shares.reduce(0) { $0 + $1.count })
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            GeometryReader { proxy in
                let gaps = CGFloat(max(0, shares.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(shares, id: \.transport) { share in
                        Capsule()
                            .fill(Self.color(for: share.transport))
                            .frame(width: max(4, (proxy.size.width - gaps) * CGFloat(share.count) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: OriveoTheme.Spacing.md) { legendItems }
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) { legendItems }
            }
        }
    }

    @ViewBuilder
    private var legendItems: some View {
        ForEach(shares, id: \.transport) { share in
            HStack(spacing: 6) {
                Circle()
                    .fill(Self.color(for: share.transport))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(verbatim: "\(RelayProtocolMix.legendName(share.transport)) \(share.count)")
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
    }
}

/// The local check card's three cells: channel / context / thinking.
struct LocalDetectionTiles: View {
    let summary: LocalSetupBoardModel.Summary

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let context = LocalSetupBoardModel.contextValue(summary.contextLength)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OriveoTheme.Spacing.sm) { tiles(context) }
            VStack(spacing: OriveoTheme.Spacing.sm) { tiles(context) }
        }
    }

    @ViewBuilder
    private func tiles(_ context: (text: String?, key: String?)) -> some View {
        tile(LocalSetupBoardModel.channelTileKey, value: relayTransportLabel(summary.channel), forcesLTR: true)
        tile(
            LocalSetupBoardModel.contextTileKey,
            value: context.text ?? L10n.tr(context.key ?? LocalSetupBoardModel.contextUnavailableKey, table: .providers),
            forcesLTR: context.text != nil
        )
        tile(LocalSetupBoardModel.thinkingTileKey, value: L10n.tr(summary.thinking.valueKey, table: .providers), forcesLTR: false)
    }

    private func tile(_ titleKey: String, value: String, forcesLTR: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr(titleKey, table: .providers))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            Text(value)
                .font(OriveoTheme.Typography.body.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .environment(\.layoutDirection, forcesLTR ? .leftToRight : layoutDirection)
        }
        .padding(OriveoTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceInset.opacity(0.7))
        )
        .accessibilityElement(children: .combine)
    }
}

/// The secondary "Manual" row under the hairline in the bottom action bar.
struct SetupBoardSecondaryRow: View {
    let icon: PhosphorIcon
    let titleKey: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: OriveoTheme.Spacing.sm) {
            LinearGradient(
                colors: [.clear, OriveoTheme.Palette.borderStrong.opacity(0.65), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, OriveoTheme.Spacing.lg)
            .accessibilityHidden(true)

            Button(action: action) {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    icon.image(.regular)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text(L10n.tr(titleKey, table: .providers))
                        .font(OriveoTheme.Typography.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.48)
        }
    }
}

/// The "Found on your local network" chip row under the address slot; the caller renders nothing when there is no result.
struct SetupNetworkChipRow: View {
    let addresses: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OriveoTheme.Spacing.sm) { content }
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) { content }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        Text(L10n.tr(LocalSetupBoardModel.networkRowTitleKey, table: .providers))
            .font(OriveoTheme.Typography.footnote)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
        ForEach(addresses, id: \.self) { address in
            HStack(spacing: 6) {
                Circle()
                    .fill(OriveoTheme.Palette.success)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(verbatim: Self.chipText(address))
                    .font(OriveoTheme.Typography.footnote.weight(.medium))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .padding(.vertical, 6)
            .background(Capsule().fill(OriveoTheme.Palette.primarySoft.opacity(0.62)))
        }
    }

    /// The chip shows only host:port; the scheme is already expressed by the address slot's prefix chip.
    static func chipText(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return address }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}
