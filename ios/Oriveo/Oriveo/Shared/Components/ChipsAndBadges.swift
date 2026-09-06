import Foundation
import SwiftUI

extension AIModel {
    var normalizedPriceTier: String {
        let normalized = priceTier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty { return normalized }

        let prompt = promptPrice ?? 0
        let completion = completionPrice ?? 0
        guard promptPrice != nil || completionPrice != nil else { return "" }
        guard prompt > 0 || completion > 0 else { return "" }

        return CostFormatter.formatPerMillion(prompt > 0 ? prompt : completion)
    }

    func visibleMetadataCapabilities(
        provider: Provider,
        identity: CapabilityEvidenceRequestIdentity? = nil,
        maxCapabilities: Int = 3
    ) -> [ModelCapability] {
        guard maxCapabilities > 0 else { return [] }
        let evidence = ModelCapabilityEvidencePresentation(
            provider: provider,
            model: self,
            identity: identity
        )
        var nonText = capabilities.filter {
            $0 != .text && $0 != .nativePdf && $0 != .toolCall && evidence.permitsDisplay($0)
        }
        if evidence.permitsToolCallDisplay() {
            nonText.append(.toolCall)
        }
        let mustShow = [.web, .imageGen].filter { nonText.contains($0) }
        guard nonText.count > maxCapabilities, !mustShow.isEmpty else {
            return Array(nonText.prefix(maxCapabilities))
        }
        let reserved = min(maxCapabilities, mustShow.count)
        var result = Array(nonText.filter { !mustShow.contains($0) }.prefix(maxCapabilities - reserved))
        result.append(contentsOf: mustShow.prefix(maxCapabilities - result.count))
        return result
    }
}

struct ModelCapabilityEvidencePresentation {
    private static let reasoningKeys = Set(
        ReasoningMode.allCases
            .filter { $0 != .automatic }
            .map { "reasoning_level/\($0.rawValue)" }
    )
    private static let governedKeys = reasoningKeys.union([
        "tool_call", "web_search", "vision_input",
    ])

    let projection: CapabilityEvidenceProjection
    private let webControlAvailable: Bool
    private let reasoningControlAvailable: Bool
    private let toolCallDecision: ToolCallCapabilityPolicy.Decision
    private let isSubscriptionLink: Bool

    #if DEBUG
    private static let constructionCountsLock = NSLock()
    nonisolated(unsafe) private static var constructionCounts: [String: Int] = [:]

    private static func constructionKey(providerKind: ProviderKind, modelID: String) -> String {
        "\(providerKind.rawValue):\(modelID)"
    }

    private static func recordConstruction(providerKind: ProviderKind, modelID: String) {
        constructionCountsLock.lock()
        defer { constructionCountsLock.unlock() }
        let key = constructionKey(providerKind: providerKind, modelID: modelID)
        constructionCounts[key, default: 0] += 1
    }

    static func resetConstructionCountsForTesting() {
        constructionCountsLock.lock()
        defer { constructionCountsLock.unlock() }
        constructionCounts = [:]
    }

    static func constructionCountForTesting(providerKind: ProviderKind, modelID: String) -> Int {
        constructionCountsLock.lock()
        defer { constructionCountsLock.unlock() }
        return constructionCounts[constructionKey(providerKind: providerKind, modelID: modelID), default: 0]
    }
    #endif

    init(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity? = nil,
        partitionID: String? = nil,
        toolCallMemory: ToolCallMemoryStore = .shared
    ) {
        #if DEBUG
        Self.recordConstruction(providerKind: provider.kind, modelID: model.id)
        #endif
        let resolvedIdentity: CapabilityEvidenceRequestIdentity?
        if let identity {
            resolvedIdentity = identity
        } else if provider.kind == .relay {
            resolvedIdentity = partitionID.flatMap {
                CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                    provider: provider,
                    model: model,
                    partitionID: $0
                )
            }
        } else {
            resolvedIdentity = CapabilityEvidenceRequestIdentity.make(
                provider: provider,
                model: model,
                partitionID: partitionID ?? "capability-presentation",
                hasExplicitValue: false
            )
        }
        projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider,
            model: model,
            identity: resolvedIdentity,
            keys: Self.governedKeys
        )
        webControlAvailable = CapabilityControlResolution.resolve(
            provider: provider, model: model, capability: "web"
        ).isAvailable
        reasoningControlAvailable = CapabilityControlResolution.resolve(
            provider: provider, model: model, capability: "reasoning"
        ).isAvailable
        toolCallDecision = ToolCallCapabilityPolicy.decide(
            provider: provider, model: model, memory: toolCallMemory
        )
        isSubscriptionLink = CapabilityControlResolution.isSubscriptionLink(provider)
    }

    func permitsDisplay(_ capability: ModelCapability) -> Bool {
        switch capability {
        case .reasoning:
            if isSubscriptionLink { return reasoningControlAvailable }
            return reasoningControlAvailable && Self.reasoningKeys.contains { permitsDisplay($0) }
        case .image:
            return permitsDisplay("vision_input")
        case .web:
            if isSubscriptionLink { return webControlAvailable }
            return webControlAvailable && permitsDisplay("web_search")
        default:
            return true
        }
    }

    func permitsToolCallDisplay() -> Bool {
        if let resolution = projection.resolution(for: "tool_call") {
            if resolution.support == .supported { return true }
            if resolution.support == .unsupported { return false }
        }
        return toolCallDecision.verdict == true
    }

    private func permitsDisplay(_ key: String) -> Bool {
        guard let resolution = projection.resolution(for: key) else { return false }
        if resolution.support == .supported { return true }
        return resolution.support == .unknown && resolution.source == .relayDeclaration
    }
}

enum StatusTone {
    case primary
    case success
    case warning
    case danger
    case neutral

    var foreground: Color {
        switch self {
        case .primary:
            return OriveoTheme.Palette.primary
        case .success:
            return OriveoTheme.Palette.success
        case .warning:
            return OriveoTheme.Palette.warning
        case .danger:
            return OriveoTheme.Palette.danger
        case .neutral:
            return OriveoTheme.Palette.textSecondary
        }
    }

    var background: Color {
        switch self {
        case .primary:
            return OriveoTheme.Palette.primarySoft
        case .success:
            return OriveoTheme.Palette.successSoft
        case .warning:
            return OriveoTheme.Palette.warningSoft
        case .danger:
            return OriveoTheme.Palette.dangerSoft
        case .neutral:
            return OriveoTheme.Palette.surface
        }
    }
}

struct StatusPill: View {
    let title: String
    var tone: StatusTone
    var compact: Bool = false
    var micro: Bool = false

    var body: some View {
        Text(title)
            .lineLimit(1)
            .font(font)
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(tone.background)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tone.foreground.opacity(0.18), lineWidth: 1)
            )
    }

    private var font: Font {
        if micro {
            return OriveoTheme.Typography.footnote.weight(.medium)
        }
        if compact {
            return OriveoTheme.Typography.caption.weight(.medium)
        }
        return OriveoTheme.Typography.footnote
    }

    private var horizontalPadding: CGFloat {
        if micro { return 6 }
        return compact ? 8 : OriveoTheme.Spacing.sm
    }

    private var verticalPadding: CGFloat {
        if micro { return 2.5 }
        return compact ? 4 : OriveoTheme.Spacing.xs
    }
}
struct HeroIconTextItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let gradientColors: [Color]
    let shadowColor: Color
}

private enum HeroIconTextStripSize {
    case regular
    case compact

    var itemSpacing: CGFloat {
        switch self {
        case .regular:
            return 6
        case .compact:
            return 5
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .regular:
            return 10.5
        case .compact:
            return 9
        }
    }

    var iconDiameter: CGFloat {
        switch self {
        case .regular:
            return 16
        case .compact:
            return 14
        }
    }

    var iconFontSize: CGFloat {
        switch self {
        case .regular:
            return 7.5
        case .compact:
            return 6.6
        }
    }

    var textFontSize: CGFloat {
        switch self {
        case .regular:
            return 12
        case .compact:
            return 11
        }
    }
}

struct HeroIconTextStrip: View {
    let items: [HeroIconTextItem]
    var maximumVisibleItems: Int = 3
    var compact: Bool = false
    var iconOnly: Bool = false

    private var visibleItems: [HeroIconTextItem] {
        Array(items.prefix(maximumVisibleItems))
    }

    private var size: HeroIconTextStripSize {
        compact ? .compact : .regular
    }

    var body: some View {
        if !visibleItems.isEmpty {
            ViewThatFits(in: .horizontal) {
                stripRow(for: visibleItems)

                if visibleItems.count > 2 {
                    stripRow(for: Array(visibleItems.prefix(2)))
                }

                if visibleItems.count > 1, let firstItem = visibleItems.first {
                    stripRow(for: [firstItem])
                }
            }
        }
    }

    @ViewBuilder
    private func stripRow(for items: [HeroIconTextItem]) -> some View {
        HStack(spacing: iconOnly ? 5 : size.rowSpacing) {
            ForEach(items) { item in
                HeroIconTextLabel(item: item, compact: compact, iconOnly: iconOnly)
                    .fixedSize()
            }
        }
    }
}

struct HeroIconTextLabel: View {
    let item: HeroIconTextItem
    var compact: Bool = false
    var iconOnly: Bool = false

    private var size: HeroIconTextStripSize {
        compact ? .compact : .regular
    }

    var body: some View {
        HStack(spacing: iconOnly ? 0 : size.itemSpacing) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: item.gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size.iconDiameter, height: size.iconDiameter)
                .overlay(
                    Circle()
                        .stroke(iconBorderColor, lineWidth: 0.7)
                )
                .overlay {
                    Image(systemName: item.systemImage)
                        .font(.system(size: size.iconFontSize, weight: .semibold))
                        .foregroundStyle(iconSymbolColor)
                }
                .shadow(color: item.shadowColor, radius: 3.5, y: 1.5)

            if !iconOnly {
                Text(item.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)
                    .font(.system(size: size.textFontSize, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary.opacity(0.94))
            }
        }
    }

    private var iconBorderColor: Color {
        Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.30, darkAlpha: 0.14)
    }

    private var iconSymbolColor: Color {
        Color.dynamic(light: 0xFFFFFF, dark: 0xF8FAFF)
    }
}

struct HeroModelCapabilityStrip: View {
    let capabilities: [ModelCapability]
    var compact: Bool = false
    var iconOnly: Bool = false

    var body: some View {
        HeroIconTextStrip(
            items: visibleCapabilities.map(\.heroIconTextItem),
            compact: compact,
            iconOnly: iconOnly
        )
    }

    private var visibleCapabilities: [ModelCapability] {
        Array(capabilities.prefix(3))
    }
}

private extension ModelCapability {
    var heroIconTextItem: HeroIconTextItem {
        let colors: [Color]
        let shadowColor: Color

        switch self {
        case .reasoning:
            colors = [Color.dynamic(light: 0xF0A11F, dark: 0xF6C24B), Color.dynamic(light: 0xC66312, dark: 0xD97706)]
            shadowColor = Color.dynamic(light: 0xC66312, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.12)
        case .text:
            colors = [Color.dynamic(light: 0x94A3B8, dark: 0x94A3B8), Color.dynamic(light: 0x64748B, dark: 0x64748B)]
            shadowColor = Color.dynamic(light: 0x475569, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.10)
        case .image:
            colors = [Color.dynamic(light: 0xF06292, dark: 0xF472B6), Color.dynamic(light: 0xD946EF, dark: 0xDB2777)]
            shadowColor = Color.dynamic(light: 0xDB2777, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.12)
        case .video:
            colors = [Color.dynamic(light: 0x38BDF8, dark: 0x7DD3FC), Color.dynamic(light: 0x2563EB, dark: 0x2563EB)]
            shadowColor = Color.dynamic(light: 0x2563EB, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.12)
        case .file:
            colors = [Color.dynamic(light: 0x7C7CF9, dark: 0x818CF8), Color.dynamic(light: 0x4F46E5, dark: 0x4F46E5)]
            shadowColor = Color.dynamic(light: 0x4338CA, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.12)
        case .web:
            colors = [Color.dynamic(light: 0x2DC7B4, dark: 0x2DD4BF), Color.dynamic(light: 0x0891B2, dark: 0x0F766E)]
            shadowColor = Color.dynamic(light: 0x0F766E, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.12)
        case .imageGen:
            colors = [Color.dynamic(light: 0x9B6BFF, dark: 0xA78BFA), Color.dynamic(light: 0x6D28D9, dark: 0x7C3AED)]
            shadowColor = Color.dynamic(light: 0x6D28D9, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.12)
        case .nativePdf:
            colors = [Color.dynamic(light: 0x94A3B8, dark: 0x94A3B8), Color.dynamic(light: 0x64748B, dark: 0x64748B)]
            shadowColor = Color.dynamic(light: 0x475569, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.10)
        case .toolCall:
            colors = [Color.dynamic(light: 0xF59E0B, dark: 0xFBBF24), Color.dynamic(light: 0xD97706, dark: 0xB45309)]
            shadowColor = Color.dynamic(light: 0xB45309, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.12)
        }

        return HeroIconTextItem(
            id: rawValue,
            title: title,
            systemImage: systemImage,
            gradientColors: colors,
            shadowColor: shadowColor
        )
    }
}

struct ProviderBadgeIcon: View {
    let kind: ProviderKind
    var size: CGFloat = 44
    /// `.openaiCompatible` / `.codexStyle` → OpenAI;`.anthropicCompatible` → Anthropic;
    var relayKind: RelayKind? = nil
    var body: some View {
        if kind == .relay, let assetName = RelayKindAssetResolver.assetName(for: relayKind) {
            brandLogo(assetName: assetName)
        } else if kind == .relay {
            Image("ProviderRelay")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(
                    width: ProviderBadgeLogoMetrics.relayFallbackContentSize(for: size),
                    height: ProviderBadgeLogoMetrics.relayFallbackContentSize(for: size)
                )
                .frame(width: size, height: size)
        } else {
            brandLogo(assetName: kind.brandAssetName)
        }
    }

    @ViewBuilder
    private func brandLogo(assetName: String) -> some View {
        Image(assetName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(
                width: ProviderBadgeLogoMetrics.brandContentSize(for: size),
                height: ProviderBadgeLogoMetrics.brandContentSize(for: size)
            )
            .frame(width: size, height: size)
    }

}

enum ProviderBadgeLogoMetrics {
    // LobeHub provider assets already include a consistent visual safe area in their 640px canvas.
    static let brandContentScale: CGFloat = 1
    static let relayFallbackContentScale: CGFloat = 0.92

    static func contentScale(for kind: ProviderKind) -> CGFloat {
        brandContentScale
    }

    static func brandContentSize(for size: CGFloat) -> CGFloat {
        size * brandContentScale
    }

    static func brandInset(for size: CGFloat) -> CGFloat {
        (size - brandContentSize(for: size)) / 2
    }

    static func contentInset(for kind: ProviderKind, size: CGFloat) -> CGFloat {
        size * (1 - contentScale(for: kind)) / 2
    }

    static func relayFallbackContentSize(for size: CGFloat) -> CGFloat {
        size * relayFallbackContentScale
    }
}

enum RelayKindAssetResolver {
    static func assetName(for kind: RelayKind?) -> String? {
        switch kind {
        case .openaiCompatible, .codexStyle:
            return "ProviderOpenAI"
        case .anthropicCompatible:
            return "ProviderAnthropic"
        case .geminiCompatible:
            return "ProviderGemini"
        case .custom, .none:
            return nil
        }
    }
}
struct ModelListMetadataRow: View {
    let model: AIModel
    let provider: Provider
    let capabilityEvidenceRevision: UInt64
    var projectedCapabilities: [ModelCapability]? = nil
    var maxCapabilities: Int = 3
    var prominentPrice: Bool = false
    var compact: Bool = false
    var iconOnly: Bool = false
    var showPrice: Bool = true
    var statusTitle: String? = nil
    var statusTone: StatusTone = .primary

    private var normalizedPrice: String {
        model.normalizedPriceTier
    }

    private var rowSpacing: CGFloat {
        compact ? 8 : OriveoTheme.Spacing.sm
    }

    private func resolvedCapabilities(at revision: UInt64) -> [ModelCapability] {
        _ = revision
        return projectedCapabilities ?? model.visibleMetadataCapabilities(
            provider: provider,
            maxCapabilities: maxCapabilities
        )
    }

    var body: some View {
        let visibleCapabilities = resolvedCapabilities(at: capabilityEvidenceRevision)
        let includePrice = showPrice && !normalizedPrice.isEmpty

        if statusTitle != nil || includePrice || !visibleCapabilities.isEmpty {
            ViewThatFits(in: .horizontal) {
                metadataRow(capabilities: visibleCapabilities, includePrice: includePrice)

                if includePrice, visibleCapabilities.count > 2 {
                    metadataRow(capabilities: Array(visibleCapabilities.prefix(2)), includePrice: true)
                }

                metadataRow(capabilities: Array(visibleCapabilities.prefix(1)), includePrice: includePrice)
                metadataRow(capabilities: visibleCapabilities, includePrice: false)

                if let statusTitle {
                    StatusPill(title: statusTitle, tone: statusTone, compact: true)
                        .fixedSize()
                }

                if includePrice {
                    priceLabel
                }
            }
        }
    }

    @ViewBuilder
    private func metadataRow(capabilities: [ModelCapability], includePrice: Bool) -> some View {
        HStack(spacing: rowSpacing) {
            if let statusTitle {
                StatusPill(title: statusTitle, tone: statusTone, compact: true)
                    .fixedSize()
            }

            if !capabilities.isEmpty {
                HeroModelCapabilityStrip(capabilities: capabilities, compact: compact, iconOnly: iconOnly)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if includePrice, !normalizedPrice.isEmpty {
                if !capabilities.isEmpty || statusTitle != nil {
                    Spacer(minLength: compact ? 8 : 12)
                }

                priceLabel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var priceLabel: some View {
        Text(normalizedPrice)
            .font(compact ? OriveoTheme.Typography.caption.weight(.medium) : OriveoTheme.Typography.footnote.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(prominentPrice ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
            .fixedSize()
    }
}

extension ProviderKind {
    var brandAssetName: String {
        switch self {
        case .openAI:
            return "ProviderOpenAI"
        case .anthropic:
            return "ProviderAnthropic"
        case .gemini:
            return "ProviderGemini"
        case .openRouter:
            return "ProviderOpenRouter"
        case .deepseek:
            return "ProviderDeepSeek"
        case .grok:
            return "ProviderGrok"
        case .groq:
            return "ProviderGroq"
        case .together:
            return "ProviderTogether"
        case .fireworks:
            return "ProviderFireworks"
        case .miniMax:
            return "ProviderMiniMax"
        case .zhipu:
            return "ProviderZAI"
        case .qwen:
            return "ProviderQwen"
        case .moonshot:
            return "ProviderKimi"
        case .mistral:
            return "ProviderMistral"
        case .siliconFlow:
            return "ProviderSiliconFlow"
        case .relay:
            return "ProviderOpenAI"
        }
    }

    var brandLogoIsOpaqueTile: Bool {
        false
    }

    var brandWatermarkSymbol: String {
        menuSystemImage
    }

    var brandBackground: Color {
        switch self {
        case .anthropic:
            return Color.dynamic(light: 0xF4EFE6, dark: 0x2A2520)
        case .openRouter:
            return Color.dynamic(light: 0xEEEFFF, dark: 0x1A1A30)
        case .deepseek:
            return Color.dynamic(light: 0xEEF4FF, dark: 0x15243B)
        case .grok:
            return Color.dynamic(light: 0xF2F3F5, dark: 0x1A1B1E)
        case .groq:
            return Color.dynamic(light: 0xFFF1EE, dark: 0x2D1B18)
        case .together:
            return Color.dynamic(light: 0xEDF5FF, dark: 0x152238)
        case .fireworks:
            return Color.dynamic(light: 0xFFF4EE, dark: 0x2D1F18)
        case .miniMax:
            return Color.dynamic(light: 0xFFF0F3, dark: 0x2D1820)
        case .zhipu:
            return Color.dynamic(light: 0xF0F0F2, dark: 0x1A1B20)
        case .qwen:
            return Color.dynamic(light: 0xEEEDFC, dark: 0x1C1A38)
        case .moonshot:
            return Color.dynamic(light: 0xEEF4FF, dark: 0x142033)
        case .mistral:
            return Color.dynamic(light: 0xFFF2E8, dark: 0x2D1D10)
        case .siliconFlow:
            return Color.dynamic(light: 0xF3ECFF, dark: 0x1E1245)
        default:
            return Color.dynamic(light: 0xFFFFFF, dark: 0x1E2433)
        }
    }

    var chartFill: Color {
        switch self {
        case .openAI:
            return Color.dynamic(light: 0x10A37F, dark: 0x22C18D)
        case .anthropic:
            return Color.dynamic(light: 0xC7956D, dark: 0xE0B58E)
        case .gemini:
            return Color.dynamic(light: 0x4285F4, dark: 0x7AB2FF)
        case .openRouter:
            return Color.dynamic(light: 0x6D63FF, dark: 0x9B93FF)
        case .deepseek:
            return Color.dynamic(light: 0x4F7BFF, dark: 0x7EA2FF)
        case .grok:
            return Color.dynamic(light: 0x0F0F10, dark: 0xF2F3F5)
        case .groq:
            return Color.dynamic(light: 0xF55036, dark: 0xFF8A74)
        case .together:
            return Color.dynamic(light: 0x0EA5E9, dark: 0x38BDF8)
        case .fireworks:
            return Color.dynamic(light: 0xFF6B35, dark: 0xFF9B6B)
        case .miniMax:
            return Color.dynamic(light: 0xE8457C, dark: 0xFF6B8A)
        case .zhipu:
            return Color.dynamic(light: 0x333333, dark: 0xA0A0A8)
        case .qwen:
            return Color.dynamic(light: 0x615CED, dark: 0x8B88F5)
        case .moonshot:
            return Color.dynamic(light: 0x2563EB, dark: 0x7DD3FC)
        case .mistral:
            return Color.dynamic(light: 0xFA500F, dark: 0xFF8205)
        case .siliconFlow:
            return Color.dynamic(light: 0x7C3AED, dark: 0xA78BFA)
        case .relay:
            return Color.dynamic(light: 0x64748B, dark: 0x94A3B8)
        }
    }

    var selectionLabel: String? {
        switch self {
        case .openRouter:
            return L10n.tr("Aggregated")
        case .groq:
            return L10n.tr("Ultra-fast")
        case .together:
            return L10n.tr("Open-source")
        case .fireworks:
            return L10n.tr("High-performance")
        case .miniMax:
            return L10n.tr("Chinese AI")
        case .zhipu:
            return L10n.tr("Chinese AI")
        case .qwen:
            return L10n.tr("Chinese AI")
        case .moonshot:
            return L10n.tr("Long context")
        case .siliconFlow:
            return L10n.tr("Aggregated")
        default:
            return nil
        }
    }
}

// MARK: - Recency

enum ModelRecency {
    case new
    case recent

    static func from(createdAt: TimeInterval?) -> ModelRecency? {
        guard let createdAt else { return nil }

        let age = max(0, Date().timeIntervalSince1970 - createdAt)
        let day: TimeInterval = 24 * 60 * 60

        switch age {
        case ..<(30 * day):
            return .new
        case ..<(90 * day):
            return .recent
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .new:
            return L10n.tr("New")
        case .recent:
            return L10n.tr("Recent")
        }
    }

    var systemImage: String {
        switch self {
        case .new:
            return "sparkles"
        case .recent:
            return "clock"
        }
    }
}
