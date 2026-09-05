import SwiftUI
import UIKit

struct RelayKindPickerView: View {
    let onSelect: (RelayKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xl) {
            headerSection
            defaultSetupSection
            protocolProfilesSection
            advancedSection
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            Text(L10n.tr("STEP 1 OF 2", table: .providers))
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(OriveoTheme.Palette.primary)

            Text(L10n.tr("Choose relay type", table: .providers))
                .font(OriveoTheme.Typography.title1)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            Text(L10n.tr("Use the option named by your relay provider. Oriveo fills the default connection settings.", table: .providers))
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Default Setup

    private var defaultSetupSection: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            sectionHeader(L10n.tr("Default setup", table: .providers))
            heroCard(.openaiCompatible)
        }
    }

    @ViewBuilder
    private func heroCard(_ kind: RelayKind) -> some View {
        let meta = RelayKindMeta.meta(for: kind)
        Button {
            onSelect(kind)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Text(meta.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.white)
                    defaultBadge
                }
                Text(meta.subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let endpointPath = meta.endpointPath {
                    Text(endpointPath)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.18))
                        )
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .background(alignment: .trailing) {
                watermark(for: kind, size: 176, tint: Color.white.opacity(0.17), overhang: 40)
            }
            .background(
                LinearGradient(
                    colors: [meta.tint, meta.tintDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: meta.tint.opacity(0.42), radius: 18, y: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayKindButtonStyle())
    }

    private var defaultBadge: some View {
        Text(L10n.tr("Default"))
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.35)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.24))
            )
    }

    // MARK: - Compatibility Profiles

    private var protocolProfilesSection: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            sectionHeader(L10n.tr("Compatibility profiles", table: .providers))
            VStack(spacing: OriveoTheme.Spacing.md) {
                tintedCard(.codexStyle)
                tintedCard(.anthropicCompatible)
                tintedCard(.geminiCompatible)
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            sectionHeader(L10n.tr("Advanced"))
            tintedCard(.custom, badge: L10n.tr("Advanced"))
        }
    }

    @ViewBuilder
    private func tintedCard(_ kind: RelayKind, badge: String? = nil) -> some View {
        let meta = RelayKindMeta.meta(for: kind)
        Button {
            onSelect(kind)
        } label: {
            HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 9) {
                        Text(meta.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        if let badge {
                            tintedBadge(badge, tint: meta.tint)
                        }
                    }
                    Text(meta.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let endpointPath = meta.endpointPath {
                        Text(endpointPath)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(meta.tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(meta.tint.opacity(0.55))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(alignment: .trailing) {
                watermark(for: kind, size: 116, tint: meta.tint.opacity(0.09), overhang: 24)
            }
            .background(meta.tint.opacity(0.11))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayKindButtonStyle())
    }

    private func tintedBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.35)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.16))
            )
    }

    // MARK: - Watermark

    @ViewBuilder
    private func watermark(for kind: RelayKind, size: CGFloat, tint: Color, overhang: CGFloat) -> some View {
        if let asset = RelayKindMeta.meta(for: kind).watermarkAsset {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(tint)
                .offset(x: overhang)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(OriveoTheme.Typography.footnote.weight(.semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .padding(.horizontal, 4)
    }
}


private struct RelayKindButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { oldValue, newValue in
                if !oldValue && newValue {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}


struct RelayKindMeta {
    let title: String
    let subtitle: String
    let endpointPath: String?
    let examples: String?
    let warning: String?
    let assetName: String?
    let systemImage: String
    let tint: Color
    let tintDeep: Color

    var watermarkAsset: String? { assetName ?? "ProviderRelay" }

    static func meta(for kind: RelayKind) -> RelayKindMeta {
        switch kind {
        case .openaiCompatible:
            return RelayKindMeta(
                title: L10n.tr("OpenAI compatible", table: .providers),
                subtitle: L10n.tr("For OpenAI-compatible relays and self-hosted gateways.", table: .providers),
                endpointPath: "/v1/chat/completions",
                examples: nil,
                warning: nil,
                assetName: "ProviderOpenAI",
                systemImage: "checkmark.seal.fill",
                tint: Color.dynamic(light: 0x16A34A, dark: 0x22C55E),
                tintDeep: Color.dynamic(light: 0x0E8F5B, dark: 0x15803D)
            )
        case .codexStyle:
            return RelayKindMeta(
                title: L10n.tr("OpenAI Responses compatible", table: .providers),
                subtitle: L10n.tr("For relays that require the Responses API.", table: .providers),
                endpointPath: "/v1/responses",
                examples: nil,
                warning: nil,
                assetName: "ProviderOpenAI",
                systemImage: "bolt.shield.fill",
                tint: Color.dynamic(light: 0x2563EB, dark: 0x60A5FA),
                tintDeep: Color.dynamic(light: 0x1D4ED8, dark: 0x3B82F6)
            )
        case .anthropicCompatible:
            return RelayKindMeta(
                title: L10n.tr("Anthropic compatible", table: .providers),
                subtitle: L10n.tr("For Claude-compatible relay endpoints.", table: .providers),
                endpointPath: nil,
                examples: nil,
                warning: nil,
                assetName: "ProviderAnthropic",
                systemImage: "a.circle.fill",
                tint: Color.dynamic(light: 0xC2410C, dark: 0xFB923C),
                tintDeep: Color.dynamic(light: 0x9A3412, dark: 0xF97316)
            )
        case .geminiCompatible:
            return RelayKindMeta(
                title: L10n.tr("Gemini compatible", table: .providers),
                subtitle: L10n.tr("For Gemini-compatible relay endpoints.", table: .providers),
                endpointPath: nil,
                examples: nil,
                warning: nil,
                assetName: "ProviderGemini",
                systemImage: "g.circle.fill",
                tint: Color.dynamic(light: 0x4F46E5, dark: 0x818CF8),
                tintDeep: Color.dynamic(light: 0x7C3AED, dark: 0xA78BFA)
            )
        case .custom:
            return RelayKindMeta(
                title: L10n.tr("Fully custom (advanced)", table: .providers),
                subtitle: L10n.tr("Start with safe defaults, then adjust transport, auth, headers, and query parameters.", table: .providers),
                endpointPath: nil,
                examples: nil,
                warning: nil,
                assetName: nil,
                systemImage: "slider.horizontal.3",
                tint: Color.dynamic(light: 0x64748B, dark: 0x94A3B8),
                tintDeep: Color.dynamic(light: 0x475569, dark: 0x64748B)
            )
        }
    }
}
