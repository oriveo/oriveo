import SwiftUI

struct ProviderHeroCard: View {
    let provider: Provider
    let monthlyEstimatedCost: Double

    @Environment(\.colorScheme) private var colorScheme

    private var resolvedLogoKind: ProviderKind {
        ProviderLogoResolver.logoKind(for: provider)
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

    private var resolvedRelayKind: RelayKind? {
        provider.kind == .relay && resolvedLogoKind == .relay ? provider.relayKind : nil
    }

    private var modelsText: String {
        if provider.kind.isAggregatedProvider,
           provider.enabledModelCount != provider.availableModelCount {
            return String(format: L10n.tr("%lld added models"), Int64(provider.enabledModelCount))
        }
        return String(format: L10n.tr("%lld models"), Int64(provider.availableModelCount))
    }

    private var syncRelativeText: String {
        provider.lastCheckedAt.map { relativeTimeText(from: $0) } ?? L10n.tr("Never")
    }

    private var monthlyCostText: String {
        let formatted = CostFormatter.format(monthlyEstimatedCost)
        return formatted.isEmpty ? "$0" : formatted
    }

    private var isZeroCost: Bool {
        monthlyEstimatedCost <= CostFormatter.costEpsilon
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

            HStack(alignment: .top, spacing: 12) {
                identityColumn
                Spacer(minLength: 8)
                statsColumn
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(OriveoTheme.Palette.cardHighlight, lineWidth: 0.6)
        )
        .shadow(color: OriveoTheme.Palette.shadow, radius: 12, x: 0, y: 6)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Background

    private var background: some View {
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
                endRadius: 240
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


    private var watermarkAssetName: String? {
        let kind = resolvedLogoKind
        if kind == .relay || kind.brandLogoIsOpaqueTile { return nil }
        return kind.brandAssetName
    }

    private var watermark: some View {
        Group {
            if let asset = watermarkAssetName {
                Color.white.opacity(0.10)
                    .frame(width: 150, height: 150)
                    .mask {
                        Image(asset)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 150, height: 150)
                    }
            } else {
                Image(systemName: resolvedLogoKind.brandWatermarkSymbol)
                    .font(.system(size: 124, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.10))
                    .frame(width: 150, height: 150)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .offset(x: 35, y: 20)
        .allowsHitTesting(false)
    }

    // MARK: - Identity column: logo + name + model + meta

    private let logoTileSize: CGFloat = 52

    private var identityColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderBadgeIcon(
                kind: resolvedLogoKind,
                size: logoTileSize,
                relayKind: resolvedRelayKind
            )
            .padding(.all, -ProviderBadgeLogoMetrics.brandInset(for: logoTileSize))

            Text(provider.displayName)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                if let modelName = primaryModelName {
                    modelRow(modelName)
                }
                Text(subInfoText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
    }

    private var statusCapsule: some View {
        HStack(spacing: 6) {
            OriveoStatusDot(color: statusColor, size: 6, pulsing: statusPulsing)

            Text(provider.effectiveStatusTitle)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.22))
        )
    }


    private var statsColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            statusCapsule
            Spacer(minLength: 8)
            costView
        }
    }

    private var costView: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(L10n.tr("This Month", table: .providers))
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.65))
            Text(monthlyCostText)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(isZeroCost ? 0.78 : 1.0))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .shadow(color: OriveoTheme.Palette.shadow, radius: 1.5, x: 0, y: 1)
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var subInfoText: String {
        guard let date = provider.lastCheckedAt else { return modelsText }
        return modelsText + "  •  " + relativeTimeText(from: date)
    }

    private var primaryModelName: String? {
        let candidate = provider.models.first(where: { $0.isDefault && $0.isAvailable })
            ?? provider.models.first(where: { $0.isAvailable })
            ?? provider.models.first
        guard let model = candidate else { return nil }
        let raw = model.name.isEmpty ? model.id : model.name
        return Self.shortenedModelName(raw)
    }

    static func shortenedModelName(_ raw: String) -> String {
        var s = raw

        if let lastSlash = s.lastIndex(of: "/") {
            s = String(s[s.index(after: lastSlash)...])
        }

        let datePatterns = [
            #"[-_]\d{4}-\d{2}-\d{2}(-?(preview|exp|latest))?$"#,
            #"[-_]\d{8}(-?(preview|exp|latest))?$"#,
            #"[-_]\d{6}(-?(preview|exp|latest))?$"#,
        ]
        for pattern in datePatterns {
            if let r = s.range(of: pattern, options: .regularExpression) {
                s.removeSubrange(r)
                break
            }
        }

        return s
    }

    private func modelRow(_ name: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ModelFamilyIcon.sfSymbol(for: name))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

// MARK: - Color blend helper

extension Color {
    func blended(with other: Color, fraction: Double) -> Color {
        let f = max(0, min(1, fraction))
        let uiA = UIColor(self)
        let uiB = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        uiA.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        uiB.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            red: Double(r1 + (r2 - r1) * CGFloat(f)),
            green: Double(g1 + (g2 - g1) * CGFloat(f)),
            blue: Double(b1 + (b2 - b1) * CGFloat(f)),
            opacity: Double(a1 + (a2 - a1) * CGFloat(f))
        )
    }

    func hsbAdjusted(saturation: Double = 1, brightness: Double = 1) -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let newS = max(0, min(1, s * CGFloat(saturation)))
        let newB = max(0, min(1, b * CGFloat(brightness)))
        return Color(UIColor(hue: h, saturation: newS, brightness: newB, alpha: a))
    }
}

// MARK: - Model family icon

fileprivate enum ModelFamilyIcon {
    static func sfSymbol(for modelName: String) -> String {
        let lower = modelName.lowercased()

        if lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
            return "brain.head.profile"
        }
        if lower.hasPrefix("gpt") {
            return "brain"
        }
        if lower.hasPrefix("claude") {
            return "sparkles"
        }
        if lower.hasPrefix("gemini") {
            return "diamond"
        }
        if lower.hasPrefix("grok") {
            return "bolt"
        }
        if lower.hasPrefix("deepseek") {
            return "magnifyingglass"
        }
        if lower.hasPrefix("llama") {
            return "leaf"
        }
        if lower.hasPrefix("mistral") || lower.hasPrefix("mixtral") {
            return "wind"
        }
        if lower.hasPrefix("qwen") {
            return "questionmark.bubble"
        }
        if lower.hasPrefix("kimi") || lower.hasPrefix("moonshot") {
            return "moon"
        }
        if lower.hasPrefix("glm") || lower.hasPrefix("chatglm") {
            return "circle.hexagongrid"
        }
        if lower.hasPrefix("yi-") || lower == "yi" {
            return "1.circle"
        }
        if lower.hasPrefix("phi") {
            return "function"
        }
        return "cpu"
    }
}

