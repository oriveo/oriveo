import SwiftUI

struct ProvidersCostSummaryCard: View {
    let summary: MonthlyCostSummary
    var onOpenDetails: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var subtitle: String {
        switch summary.source {
        case .localDevice:
            return L10n.tr("Based on usage on this device")
        case .accountAPI:
            return L10n.tr("Across all providers in this account")
        }
    }

    private var costFont: Font {
        if UIFont(name: "PlusJakartaSans-Bold", size: 36) != nil {
            return .custom("PlusJakartaSans-Bold", size: 36)
        }
        return .system(size: 36, weight: .bold)
    }

    private var dollarFont: Font {
        if UIFont(name: "PlusJakartaSans-Bold", size: 20) != nil {
            return .custom("PlusJakartaSans-Bold", size: 20)
        }
        return .system(size: 20, weight: .bold)
    }

    private var monthLabel: String {
        Date().formatted(.dateTime.month(.abbreviated).year()).uppercased()
    }

    private var fullCostText: String {
        let formatted = CostFormatter.format(summary.totalCost)
        return formatted.isEmpty ? "$0" : formatted
    }

    private var hasDollarPrefix: Bool {
        fullCostText.hasPrefix("$")
    }

    private var costAmountBody: String {
        hasDollarPrefix ? String(fullCostText.dropFirst()) : fullCostText
    }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 16) {
            titleRow

            heroBlock

            if !summary.providers.isEmpty {
                if summary.providers.count + summary.hiddenProviderCount >= 2 {
                    SegmentedCostBar(
                        providers: summary.providers,
                        totalCost: summary.totalCost
                    )
                    .padding(.top, 2)
                }

                ProviderBreakdownList(
                    providers: summary.providers,
                    totalCost: summary.totalCost,
                    hiddenCount: summary.hiddenProviderCount
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        //   5. panel overlays (cornerGlow / insetBottomReflection / borderStroke)
        .background(watermark, alignment: .topTrailing)
        .background(brandSheen)
        .oriveoGradientPanel(radius: 22)

        if let onOpenDetails {
            Button {
                onOpenDetails()
            } label: {
                content
            }
            .buttonStyle(CostCardButtonStyle())
        } else {
            content
        }
    }

    private var brandSheen: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                .init(0, 0),    .init(0.5, 0),    .init(1, 0),
                .init(0, 0.5),  .init(0.5, 0.5),  .init(1, 0.5),
                .init(0, 1),    .init(0.5, 1),    .init(1, 1)
            ],
            colors: [
                .clear,
                .clear,
                OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.26 : 0.18),

                .clear,
                .clear,
                OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.10 : 0.07),

                OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.14 : 0.10),
                .clear,
                .clear
            ]
        )
        .allowsHitTesting(false)
    }

    private var watermark: some View {
        Image(systemName: "creditcard.fill")
            .font(.system(size: 80, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.07 : 0.045))
            .rotationEffect(.degrees(-14))
            .offset(x: 28, y: -22)
            .allowsHitTesting(false)
    }

    // MARK: - Title row

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 8) {
                OriveoIconPlate(size: 22, cornerRadius: 7) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                }

                Text(L10n.tr("By Provider", table: .providers))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if onOpenDetails != nil {
                OriveoIconPlate(size: 24, cornerRadius: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
            }
        }
    }

    // MARK: - Hero block

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            monthChip
            costAmountRow
            baseline
            Text(subtitle)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 1)
        }
    }

    private var monthChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(OriveoTheme.Palette.primary.opacity(0.85))
                .frame(width: 4, height: 4)

            Text(monthLabel)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.95 : 0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.18 : 0.09))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.32 : 0.18), lineWidth: 0.6)
                )
        )
    }

    private var costAmountRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if hasDollarPrefix {
                Text("$")
                    .font(dollarFont)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .accessibilityHidden(true)
            }

            Text(costAmountBody)
                .font(costFont)
                .tracking(-1.4)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fullCostText)
    }

    private var baseline: some View {
        LinearGradient(
            colors: [
                OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.68 : 0.55),
                OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.28 : 0.20),
                Color.clear
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 120, height: 1.5)
        .padding(.top, -1)
    }
}

// MARK: - Segmented stacked bar

private struct SegmentedCostBar: View {
    let providers: [MonthlyCostSummaryProviderEntry]
    let totalCost: Double

    @Environment(\.colorScheme) private var colorScheme

    private var visibleShare: Double {
        guard totalCost > CostFormatter.costEpsilon else { return 0 }
        let sum = providers.reduce(0.0) { $0 + min(max($1.cost / totalCost, 0), 1) }
        return min(max(sum, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 0)
            let count = providers.count
            let gap: CGFloat = count > 1 ? 3 : 0
            let totalGap = max(0, CGFloat(count - 1)) * gap
            let usable = max(width - totalGap, 0)
            let minSegment: CGFloat = 4

            HStack(spacing: gap) {
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, entry in
                    let share = totalCost > CostFormatter.costEpsilon
                        ? min(max(entry.cost / totalCost, 0), 1)
                        : 0
                    let rawWidth = usable * share
                    let segmentWidth = share > 0 ? max(rawWidth, minSegment) : 0

                    if segmentWidth > 0 {
                        SegmentedCostBarPiece(tint: ChartColorResolver.color(forIndex: index))
                            .frame(width: segmentWidth)
                    }
                }

                if visibleShare < 0.999 {
                    Capsule(style: .continuous)
                        .fill(OriveoTheme.Palette.textTertiary.opacity(colorScheme == .dark ? 0.10 : 0.07))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 10)
    }
}

private struct SegmentedCostBarPiece: View {
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        tint.lightenedForGradient(by: 0.06),
                        tint
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(colorScheme == .dark ? 0.45 : 0.32), lineWidth: 0.5)
            )
            .overlay(alignment: .top) {
                Capsule(style: .continuous)
                    .stroke(OriveoTheme.Palette.cardHighlight, lineWidth: 1)
                    .blur(radius: 0.3)
                    .mask(
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(LinearGradient(
                                    colors: [.black, .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ))
                                .frame(height: 3)
                            Spacer(minLength: 0)
                        }
                    )
            }
    }
}

// MARK: - Provider Breakdown List

private struct ProviderBreakdownList: View {
    let providers: [MonthlyCostSummaryProviderEntry]
    let totalCost: Double
    let hiddenCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OriveoFadeHairline()
                .padding(.bottom, 2)

            ForEach(Array(providers.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    OriveoFadeHairline(insetLeading: 26)
                }

                ProviderBreakdownRow(
                    entry: entry,
                    totalCost: totalCost,
                    colorIndex: index
                )
            }

            if hiddenCount > 0 {
                ProviderBreakdownOverflowRow(hiddenCount: hiddenCount)
            }
        }
    }
}

private struct ProviderBreakdownRow: View {
    let entry: MonthlyCostSummaryProviderEntry
    let totalCost: Double
    let colorIndex: Int

    @Environment(\.colorScheme) private var colorScheme

    private var share: Double {
        guard totalCost > CostFormatter.costEpsilon else { return 0 }
        return min(max(entry.cost / totalCost, 0), 1)
    }

    private var shareText: String {
        let fractionLength = share < 0.1 ? 1 : 0
        return share.formatted(.percent.precision(.fractionLength(fractionLength)))
    }

    private var providerAccent: Color {
        ChartColorResolver.color(forIndex: colorIndex)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            providerAccent.lightenedForGradient(by: 0.06),
                            providerAccent
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(providerAccent.opacity(colorScheme == .dark ? 0.40 : 0.30), lineWidth: 0.5)
                )
                .overlay(alignment: .top) {
                    Capsule(style: .continuous)
                        .stroke(OriveoTheme.Palette.cardHighlight, lineWidth: 1)
                        .blur(radius: 0.3)
                        .mask(
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(LinearGradient(
                                        colors: [.black, .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ))
                                    .frame(height: 2)
                                Spacer(minLength: 0)
                            }
                        )
                }
                .frame(width: 16, height: 7)

            Text(entry.displayName)
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(-0.07)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(CostFormatter.format(entry.cost))
                .font(.system(size: 13.5, weight: .bold))
                .tracking(-0.1)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)

            Text(shareText)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .frame(minWidth: 36, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.vertical, 8)
    }
}

private struct ProviderBreakdownOverflowRow: View {
    let hiddenCount: Int

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Capsule(style: .continuous)
                .fill(OriveoTheme.Palette.textTertiary.opacity(colorScheme == .dark ? 0.22 : 0.14))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(OriveoTheme.Palette.textTertiary.opacity(colorScheme == .dark ? 0.30 : 0.20), lineWidth: 0.5)
                )
                .frame(width: 16, height: 7)

            Text(String(format: L10n.tr("%d more"), hiddenCount))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Button Style

private struct CostCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Chart color resolution

private enum ChartColorResolver {
    private static let brandHue: Double = 257.0

    static func color(forIndex index: Int) -> Color {
        let hue: Double
        if index == 0 {
            hue = brandHue / 360.0
        } else {
            let bucket = (((index - 1) % palette.count) + palette.count) % palette.count
            hue = palette[bucket] / 360.0
        }

        return Color(uiColor: UIColor { trait in
            let isDark = trait.userInterfaceStyle == .dark
            return UIColor(
                hue: CGFloat(hue),
                saturation: isDark ? 0.50 : 0.55,
                brightness: isDark ? 0.82 : 0.88,
                alpha: 1
            )
        })
    }

    private static let palette: [Double] = [
        15,   // coral red       (idx 0)
        160,  // teal             (idx 1)
        275,  // violet           (idx 2)
        55,   // gold             (idx 3)
        215,  // ocean blue       (idx 4)
        330,  // rose             (idx 5)
        130,  // emerald          (idx 6)
        245,  // indigo           (idx 7)
        35,   // amber orange     (idx 8)
        190,  // cyan             (idx 9)
        300,  // magenta          (idx 10)
        355   // crimson          (idx 11)
    ]
}

// MARK: - Helpers

private extension Color {
    func lightenedForGradient(by ratio: Double) -> Color {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let mix = max(0, min(1, ratio))
        return Color(
            red: r * (1 - mix) + 1.0 * mix,
            green: g * (1 - mix) + 1.0 * mix,
            blue: b * (1 - mix) + 1.0 * mix,
            opacity: a
        )
    }
}
