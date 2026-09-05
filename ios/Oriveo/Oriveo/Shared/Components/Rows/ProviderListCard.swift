import SwiftUI

struct ProviderListCard: View {
    let provider: Provider
    var monthlyEstimatedCost: Double = 0
    var managedBalanceMicrousd: Int64? = nil
    var providerBalance: ProviderBalance? = nil
    @Environment(\.colorScheme) private var colorScheme

    private var enabledModelsText: String? {
        guard provider.kind.isAggregatedProvider,
              provider.enabledModelCount != provider.availableModelCount
        else { return nil }
        return String(format: L10n.tr("%lld added models"), Int64(provider.enabledModelCount))
    }

    private var modelsText: String {
        if let enabledModelsText { return enabledModelsText }
        return String(format: L10n.tr("%lld models"), Int64(provider.availableModelCount))
    }

    private var syncRelativeText: String {
        provider.lastCheckedAt.map { relativeTimeText(from: $0) } ?? L10n.tr("Never")
    }

    private var trailingAmount: ProviderListTrailingAmount? {
        ProviderListCardPresentation.trailingAmount(
            providerKind: provider.kind,
            monthlyEstimatedCost: monthlyEstimatedCost,
            managedBalanceMicrousd: managedBalanceMicrousd,
            providerBalance: providerBalance
        )
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

    private var statusColor: Color {
        switch provider.effectiveStatusKind {
        case .connected: return OriveoTheme.Palette.success
        case .syncing: return OriveoTheme.Palette.primary
        case .issue, .needsKey: return OriveoTheme.Palette.warning
        }
    }

    private var statusIsPulsing: Bool {
        if case .syncing = provider.status { return true }
        return false
    }

    private var showsInlineStatus: Bool {
        !provider.effectiveStatusKind.isHealthy
    }

    var body: some View {
        HStack(spacing: 0) {
            brandBar
                .padding(.leading, 14)
                .padding(.trailing, 16)

            ProviderBadgeIcon(
                kind: resolvedLogoKind,
                size: 38,
                relayKind: resolvedRelayKind
            )
            .padding(.trailing, 13)

            VStack(alignment: .leading, spacing: 3) {
                nameRow
                subRow
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            trailingRegion
                .padding(.leading, 8)
                .padding(.trailing, 14)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }


    private var brandBar: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        brandColor.opacity(colorScheme == .dark ? 1.0 : 0.92),
                        brandColor.opacity(colorScheme == .dark ? 0.72 : 0.62)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 3.5, height: 38)
    }


    private var nameRow: some View {
        HStack(spacing: 8) {
            Text(provider.displayName)
                .font(.system(size: 16.5, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)

            if showsInlineStatus {
                statusInline
                    .fixedSize()
            }

            Spacer(minLength: 0)
        }
    }

    private var statusInline: some View {
        HStack(spacing: 4) {
            OriveoStatusDot(color: statusColor, size: 6, pulsing: statusIsPulsing)

            Text(provider.effectiveStatusTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
    }

    // MARK: - Sub row(models • synced ago)

    private var subRow: some View {
        HStack(spacing: 6) {
            Text(modelsText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .lineLimit(1)
                .layoutPriority(1)

            subDot

            Text(syncRelativeText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }

    private var subDot: some View {
        Circle()
            .fill(OriveoTheme.Palette.textTertiary.opacity(0.45))
            .frame(width: 2.5, height: 2.5)
    }

    // MARK: - Trailing(cost + chevron)

    private var trailingRegion: some View {
        HStack(alignment: .center, spacing: 12) {
            if let trailingAmount {
                amountInline(trailingAmount)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textTertiary.opacity(0.55))
        }
        .fixedSize()
    }

    private func amountInline(_ amount: ProviderListTrailingAmount) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(L10n.tr(amount.label.rawValue, table: .providers))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)

            Text(amount.text)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(
                    amount.isZero
                        ? OriveoTheme.Palette.textTertiary.opacity(0.85)
                        : OriveoTheme.Palette.textPrimary
                )
                .monospacedDigit()
        }
        .lineLimit(1)
    }
}

enum ProviderListAmountLabel: String, Equatable {
    case balance = "Balance:"
    case usage = "Usage:"
}

struct ProviderListTrailingAmount: Equatable {
    let label: ProviderListAmountLabel
    let text: String
    let isZero: Bool
}

@MainActor
enum ProviderListCardPresentation {
    static func trailingAmount(
        providerKind: ProviderKind,
        monthlyEstimatedCost: Double,
        managedBalanceMicrousd: Int64?,
        providerBalance: ProviderBalance?
    ) -> ProviderListTrailingAmount? {
        switch providerKind {
        default:
            if balanceCapableProviderKinds.contains(providerKind) {
                return ProviderListTrailingAmount(
                    label: .balance,
                    text: providerBalance.map(providerBalanceText) ?? "--",
                    isZero: providerBalance?.total == 0
                )
            }
            let formatted = CostFormatter.format(monthlyEstimatedCost)
            return ProviderListTrailingAmount(
                label: .usage,
                text: formatted.isEmpty ? "$0" : compactCurrencyText(formatted),
                isZero: monthlyEstimatedCost <= CostFormatter.costEpsilon
            )
        }
    }

    private static let balanceAmountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = true
        return formatter
    }()

    private static func providerBalanceText(_ balance: ProviderBalance) -> String {
        let symbol = balance.currency.uppercased() == "CNY" ? "¥" : "$"
        let number = balanceAmountFormatter.string(from: NSNumber(value: abs(balance.total)))
            ?? String(format: "%.2f", abs(balance.total))
        return "\(balance.total < 0 ? "-" : "")\(symbol)\(number)"
    }

    static func showsErrorCopy(for provider: Provider) -> Bool {
        false
    }
}


private func compactCurrencyText(_ text: String) -> String {
    let decimalSeparator = Locale.current.decimalSeparator ?? "."
    guard let separatorIndex = text.lastIndex(of: Character(decimalSeparator)) else {
        return text
    }

    let prefix = text[..<text.index(after: separatorIndex)]
    var suffix = String(text[text.index(after: separatorIndex)...])

    while suffix.count > 2, suffix.last == "0" {
        suffix.removeLast()
    }

    return String(prefix) + suffix
}

enum RelativeTimeFormatter {
    static func text(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return L10n.tr("Just now")
        }

        let minutes = Int(interval / 60)
        if minutes < 60 {
            return String(format: L10n.tr("%lld min ago"), minutes)
        }

        let hours = Int(interval / 3600)
        if hours < 24 {
            return String(format: L10n.tr("%lld hr ago"), hours)
        }

        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) {
            return L10n.tr("Yesterday")
        }

        let formatter = DateFormatter()
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }

    static func callAsFunction(from date: Date) -> String {
        text(from: date)
    }
}

func relativeTimeText(from date: Date) -> String {
    RelativeTimeFormatter.text(from: date)
}
