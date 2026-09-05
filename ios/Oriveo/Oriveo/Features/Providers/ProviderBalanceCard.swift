import SwiftUI

struct ProviderBalanceCard: View {
    let provider: Provider
    @State private var state: LoadState = .idle
    @State private var balance: ProviderBalance?
    @State private var errorKind: BalanceQueryError?
    @State private var refreshTrigger: Int = 0

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
        case hidden
    }

    static let balanceCapableKinds = balanceCapableProviderKinds

    static func isBalanceCapable(_ kind: ProviderKind) -> Bool {
        balanceCapableKinds.contains(kind)
    }

    private var isRefreshing: Bool { state == .loading }
    private var hasData: Bool { balance != nil }

    var body: some View {
        Group {
            if state == .hidden {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                    header
                    content
                }
                .padding(OriveoTheme.Spacing.lg)
                .background(decoratedBackground)
                .clipShape(RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous))
                .overlay(cardBorder)
                .shadow(color: OriveoTheme.Palette.shadow, radius: 12, x: 0, y: 6)
                .shadow(color: OriveoTheme.Palette.shadow.opacity(0.5), radius: 2, x: 0, y: 1)
                .task(id: provider.id) {
                    await loadIfNeeded(forceRefresh: false)
                }
            }
        }
        .onChange(of: provider.apiKey) {
            Task { await loadIfNeeded(forceRefresh: true) }
        }
        .onChange(of: provider.baseURLText) {
            Task { await loadIfNeeded(forceRefresh: true) }
        }
    }


    private var decoratedBackground: some View {
        ZStack {
            OriveoTheme.Palette.surface

            RadialGradient(
                colors: [
                    OriveoTheme.Palette.primary.opacity(0.14),
                    Color.clear,
                ],
                center: UnitPoint(x: 1.02, y: -0.05),
                startRadius: 0,
                endRadius: 240
            )

            LinearGradient(
                colors: [
                    Color.white.opacity(0.0),
                    Color.white.opacity(0.08),
                    Color.white.opacity(0.0),
                ],
                startPoint: UnitPoint(x: 0.0, y: -0.1),
                endPoint: UnitPoint(x: 0.8, y: 1.2)
            )
            .blendMode(.plusLighter)

            watermark
        }
        .allowsHitTesting(false)
    }

    private var watermark: some View {
        Image(systemName: "chart.pie.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 130, height: 130)
            .foregroundStyle(OriveoTheme.Palette.primary)
            .opacity(0.06)
            .rotationEffect(.degrees(-12))
            .offset(x: 70, y: 45)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous)
            .stroke(OriveoTheme.Palette.border, lineWidth: 1)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: OriveoTheme.Spacing.md) {
            iconChip
            Text(L10n.tr("Account Balance", table: .providers))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Spacer()
            refreshButton
        }
    }

    private var iconChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OriveoTheme.Palette.primarySoft)
            Image(systemName: "creditcard.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.primary)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }

    private var refreshButton: some View {
        Button {
            refreshTrigger &+= 1
            Task { await loadIfNeeded(forceRefresh: true) }
        } label: {
            ZStack {
                Circle()
                    .fill(OriveoTheme.Palette.primarySoft)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .symbolEffect(
                        .rotate,
                        options: .speed(1.2).repeat(.continuous),
                        isActive: isRefreshing
                    )
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .opacity(isRefreshing ? 0.85 : 1)
        .accessibilityLabel(L10n.tr("Refresh", table: .providers))
        .sensoryFeedback(.impact(weight: .light), trigger: refreshTrigger)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let b = balance {
            loadedContent(b)
                .transition(.opacity)
        } else if state == .failed {
            failedContent
                .transition(.opacity)
        } else {
            skeletonContent
                .transition(.opacity)
        }
    }

    private var skeletonContent: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceInset)
                .frame(width: 140, height: 36)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceInset)
                .frame(height: 6)
            HStack(spacing: OriveoTheme.Spacing.lg) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceInset)
                    .frame(width: 80, height: 28)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceInset)
                    .frame(width: 80, height: 28)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func loadedContent(_ b: ProviderBalance) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatAmount(b.total, currency: b.currency))
                    .font(OriveoTheme.Typography.display(32))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: b.total)
                Text(b.currency)
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .padding(.bottom, 2)
                Spacer(minLength: 0)
            }

            if shouldShowBreakdown(b) {
                breakdown(b)
            }
        }
    }

    private func shouldShowBreakdown(_ b: ProviderBalance) -> Bool {
        isVisible(b.granted) || isVisible(b.topUp) || isVisible(b.totalUsage)
    }

    private func isVisible(_ value: Double?) -> Bool {
        guard let v = value else { return false }
        return v != 0
    }

    @ViewBuilder
    private func breakdown(_ b: ProviderBalance) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            if let progress = usageProgress(b) {
                usageProgressBar(progress: progress)
            }

            HStack(spacing: OriveoTheme.Spacing.lg) {
                if let granted = b.granted, granted != 0 {
                    breakdownItem(
                        icon: "sparkles",
                        title: grantedLabel(for: provider.kind),
                        value: formatAmount(granted, currency: b.currency)
                    )
                }
                if let topUp = b.topUp, topUp != 0 {
                    let owing = provider.kind == .moonshot && topUp < 0
                    breakdownItem(
                        icon: owing ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill",
                        title: topUpLabel(for: provider.kind),
                        value: formatAmount(topUp, currency: b.currency),
                        isWarning: owing
                    )
                }
                if let totalUsage = b.totalUsage, totalUsage != 0 {
                    breakdownItem(
                        icon: "arrow.up.circle.fill",
                        title: L10n.tr("Used", table: .providers),
                        value: formatAmount(totalUsage, currency: b.currency)
                    )
                }
                Spacer()
            }
        }
    }

    private func usageProgress(_ b: ProviderBalance) -> Double? {
        guard let used = b.totalUsage, used > 0 else { return nil }
        let denom = b.total + used
        guard denom > 0 else { return nil }
        return min(max(used / denom, 0), 1)
    }

    private func usageProgressBar(progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(OriveoTheme.Palette.primarySoft)
                Capsule()
                    .fill(OriveoTheme.Palette.primary)
                    .frame(width: max(geo.size.width * progress, 4))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(L10n.tr("Used", table: .providers))
        .accessibilityValue("\(Int(progress * 100))%")
    }

    @ViewBuilder
    private func breakdownItem(icon: String, title: String, value: String, isWarning: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                Circle()
                    .fill(isWarning
                          ? OriveoTheme.Palette.warningSoft
                          : OriveoTheme.Palette.surfaceInset)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isWarning
                                     ? OriveoTheme.Palette.warning
                                     : OriveoTheme.Palette.textSecondary)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                HStack(spacing: 4) {
                    Text(value)
                        .font(OriveoTheme.Typography.monoCaption)
                        .foregroundStyle(isWarning ? OriveoTheme.Palette.warning : OriveoTheme.Palette.textPrimary)
                    if isWarning {
                        Text(L10n.tr("Owing", table: .providers))
                            .font(OriveoTheme.Typography.footnote.weight(.semibold))
                            .foregroundStyle(OriveoTheme.Palette.warning)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var failedContent: some View {
        if case .keyInvalid = errorKind {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                Text(L10n.tr("API Key invalid", table: .providers))
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.warning)
                Text(L10n.tr("Check your key", table: .providers))
                    .font(OriveoTheme.Typography.caption)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
        } else {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Text(L10n.tr("Unable to fetch, retry", table: .providers))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                Spacer()
                Button {
                    refreshTrigger &+= 1
                    Task { await loadIfNeeded(forceRefresh: true) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L10n.tr("Refresh", table: .providers))
                            .font(OriveoTheme.Typography.caption.weight(.semibold))
                    }
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(OriveoTheme.Palette.primarySoft, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Loading

    private func loadIfNeeded(forceRefresh: Bool) async {
        guard Self.isBalanceCapable(provider.kind) else {
            withAnimation(.easeOut(duration: 0.2)) { state = .hidden }
            return
        }
        let apiKey = provider.apiKey
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            withAnimation(.easeOut(duration: 0.2)) {
                errorKind = .keyInvalid(detail: "Missing API key.")
                state = .failed
            }
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            state = .loading
            errorKind = nil
        }
        do {
            let result = try await ProviderBalanceStore.shared.load(
                providerID: provider.id,
                kind: provider.kind,
                apiKey: apiKey,
                baseURL: provider.baseURLText,
                forceRefresh: forceRefresh
            )
            withAnimation(.easeOut(duration: 0.25)) {
                balance = result
                state = .loaded
            }
        } catch let error as BalanceQueryError {
            withAnimation(.easeOut(duration: 0.2)) {
                errorKind = error
                switch error {
                case .silentHidden:
                    state = .hidden
                default:
                    state = .failed
                }
            }
        } catch {
            withAnimation(.easeOut(duration: 0.2)) {
                errorKind = .network(detail: error.localizedDescription)
                state = .failed
            }
        }
    }

    // MARK: - Helpers

    private static let amountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = true
        return f
    }()

    private func formatAmount(_ value: Double, currency: String) -> String {
        let symbol: String = switch currency.uppercased() {
        case "USD": "$"
        case "CNY": "¥"
        default: "\(currency) "
        }
        let number = Self.amountFormatter.string(from: NSNumber(value: value))
            ?? String(format: "%.2f", value)
        return symbol + number
    }

    private func grantedLabel(for kind: ProviderKind) -> String {
        switch kind {
        case .moonshot: return L10n.tr("Voucher", table: .providers)
        default: return L10n.tr("Granted")
        }
    }

    private func topUpLabel(for kind: ProviderKind) -> String {
        switch kind {
        case .moonshot: return L10n.tr("Cash", table: .providers)
        default: return L10n.tr("Top-up", table: .providers)
        }
    }
}
