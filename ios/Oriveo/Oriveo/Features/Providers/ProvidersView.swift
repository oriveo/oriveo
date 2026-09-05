import SwiftUI

struct ProvidersView: View {
    @Environment(AppState.self) private var appState
    @State private var providerToDelete: Provider?
    @State private var lastCachedUID: String = AppSessionStore.activeUID
    @State private var budgetCacheUID: String?
    @State private var lastBudgetRefreshAt: Date?
    @State private var managedBalanceLoadedUID: String?
    @State private var providerBalancesByID: [UUID: ProviderBalance] = [:]
    @State private var spotlightIndex: Int = 0

    private var monthlyCostByProvider: [UUID: Double] {
        appState.localMonthlyCostByProvider
    }

    private var dailyCostsLast7DaysByProvider: [UUID: [Double]] { [:] }

    private var localMonthlyCostSummary: MonthlyCostSummary {
        appState.localMonthlyCostSummary
    }

    private var monthlyCostSummary: MonthlyCostSummary {
        localMonthlyCostSummary
    }

    private var providerBalancesRefreshKey: String {
        let providersKey = appState.providers
            .filter { ProviderBalanceCard.isBalanceCapable($0.kind) }
            .map {
                [
                    $0.id.uuidString,
                    $0.kind.rawValue,
                    $0.apiKey,
                    $0.baseURLText ?? "",
                ].joined(separator: "~")
            }
            .joined(separator: "|")
        return [
            appState.selectedTab == .providers ? "active" : "inactive",
            AppSessionStore.activeUID,
            providersKey,
        ].joined(separator: "|")
    }

    private var managedBalanceMicrousd: Int64? { nil }

    private var usageInsightsEntryAction: () -> Void {
        { }
    }

    private struct ProviderMetrics {
        var connected = 0
        var syncing = 0
        var issue = 0
        var availableModels = 0
    }

    private var providerMetrics: ProviderMetrics {
        var m = ProviderMetrics()
        for provider in appState.providers {
            switch provider.effectiveStatusKind {
            case .connected: m.connected += 1
            case .syncing: m.syncing += 1
            case .issue, .needsKey: m.issue += 1
            }
            m.availableModels += provider.availableModelCount
        }
        return m
    }

    private func spotlightProviders(costByProvider: [UUID: Double]) -> [Provider] {
        let eligible = appState.providers
        guard !eligible.isEmpty else { return [] }

        let withCost = eligible
            .map { ($0, costByProvider[$0.id] ?? 0) }
            .filter { $0.1 > CostFormatter.costEpsilon }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }

        if !withCost.isEmpty {
            return Array(withCost.prefix(1))
        }

        let scored = eligible.sorted { lhs, rhs in
            statusPriority(lhs.status) < statusPriority(rhs.status)
        }
        return Array(scored.prefix(1))
    }

    private func statusPriority(_ status: ProviderConnectionState) -> Int {
        switch status {
        case .connected: return 0
        case .syncing: return 1
        case .issue: return 2
        }
    }

    var body: some View {
        let metrics = providerMetrics
        let costByProvider = monthlyCostByProvider
        let dailyCosts = dailyCostsLast7DaysByProvider
        let costSummary = monthlyCostSummary
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HeaderBar(
                    onAdd: { appState.openProviderSetup(from: .providers) }
                )

                if appState.providers.isEmpty {
                    ProvidersFullEmptyState(
                        onAdd: { appState.openProviderSetup(from: .providers) }
                    )
                } else {
                    spotlightSection(costByProvider: costByProvider, dailyCosts: dailyCosts)
                    summaryStrip(metrics: metrics)
                    allProvidersSection(costByProvider: costByProvider)
                }

                if costSummary.isVisible {
                    costsSection(summary: costSummary)
                }
            }
            .padding(.horizontal, OriveoTheme.Spacing.lg)
            .padding(.top, 8)
            .padding(.bottom, 180)
        }
        .scrollIndicators(.hidden)
        .background(ProvidersScreenBackground())
        .onAppear {
        }
        .task(id: providerBalancesRefreshKey, priority: .utility) {
            guard appState.selectedTab == .providers else { return }
            await refreshProviderBalances()
        }

        .alert(String(format: L10n.tr("Delete “%@”?", table: .providers), providerToDelete?.displayName ?? ""), isPresented: Binding(
            get: { providerToDelete != nil },
            set: { if !$0 { providerToDelete = nil } }
        )) {
            Button(L10n.tr("Delete"), role: .destructive) {
                if let provider = providerToDelete {
                    appState.deleteProvider(providerID: provider.id)
                }
                providerToDelete = nil
            }
            Button(L10n.tr("Cancel"), role: .cancel) {
                providerToDelete = nil
            }
        } message: {
            Text(L10n.tr("This deletes the connection, API key, enabled models, model library, and model behavior settings. It does not delete conversations; message history stays, and models used there are marked unavailable. This cannot be undone.", table: .providers))
        }
    }

    // MARK: - Spotlight section

    @ViewBuilder
    private func spotlightSection(
        costByProvider: [UUID: Double],
        dailyCosts: [UUID: [Double]]
    ) -> some View {
        let hero = spotlightProviders(costByProvider: costByProvider)
        if !hero.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: L10n.tr("Active this month", table: .providers), systemImage: "sparkles", tone: .active)

                if hero.count == 1 {
                    Button {
                        appState.openProviderDetail(providerID: hero[0].id)
                    } label: {
                        ProviderHeroCard(
                            provider: hero[0],
                            monthlyEstimatedCost: costByProvider[hero[0].id] ?? 0,
                            dailyCostsLast7Days: dailyCosts[hero[0].id] ?? []
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HeroCardButtonStyle())
                } else {
                    SpotlightCarousel(
                        providers: hero,
                        currentIndex: $spotlightIndex,
                        costForProvider: { costByProvider[$0.id] ?? 0 },
                        dailyCostsForProvider: { dailyCosts[$0.id] ?? [] },
                        onTap: { appState.openProviderDetail(providerID: $0.id) }
                    )
                }
            }
        }
    }


    @ViewBuilder
    private func summaryStrip(metrics: ProviderMetrics) -> some View {
        ProvidersSummaryStrip(
            providerCount: appState.providers.count,
            availableModelCount: metrics.availableModels,
            connectedCount: metrics.connected,
            syncingCount: metrics.syncing,
            issueCount: metrics.issue
        )
    }

    // MARK: - All providers section

    private func allProvidersSection(costByProvider: [UUID: Double]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: L10n.tr("All providers"), systemImage: "square.grid.2x2.fill", tone: .all)

            VStack(spacing: 0) {
                ForEach(Array(appState.providers.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 {
                        OriveoFadeHairline(insetLeading: 85, insetTrailing: 14)
                    }

                    Button {
                        appState.openProviderDetail(providerID: provider.id)
                    } label: {
                        ProviderListCard(
                            provider: provider,
                            monthlyEstimatedCost: costByProvider[provider.id] ?? 0,
                            managedBalanceMicrousd: managedBalanceMicrousd,
                            providerBalance: providerBalancesByID[provider.id]
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ProviderRowButtonStyle())
                    .contextMenu {
                        Button(role: .destructive) {
                            providerToDelete = provider
                        } label: {
                            Label(L10n.tr("Delete"), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .oriveoGradientPanel(radius: 22)
        }
    }

    // MARK: - Costs section

    private func costsSection(summary: MonthlyCostSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: L10n.tr("Costs", table: .providers), systemImage: "creditcard.fill", tone: .costs)
            ProvidersCostSummaryCard(
                summary: summary,
                onOpenDetails: usageInsightsEntryAction
            )
        }
    }

    // MARK: - Usage Summary

    @MainActor
    private func refreshProviderBalances() async {
        let providers = appState.providers.filter {
            ProviderBalanceCard.isBalanceCapable($0.kind) &&
                $0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let validIDs = Set(providers.map(\.id))
        ProviderBalanceStore.shared.removeMissingProviders(validIDs: validIDs)
        providerBalancesByID = [:]

        await withTaskGroup(of: (UUID, ProviderBalance?).self) { group in
            for provider in providers {
                let providerID = provider.id
                let kind = provider.kind
                let apiKey = provider.apiKey
                let baseURL = provider.baseURLText
                group.addTask {
                    let balance = try? await ProviderBalanceStore.shared.load(
                        providerID: providerID,
                        kind: kind,
                        apiKey: apiKey,
                        baseURL: baseURL
                    )
                    return (providerID, balance)
                }
            }

            var loaded: [UUID: ProviderBalance] = [:]
            for await (providerID, balance) in group {
                if let balance { loaded[providerID] = balance }
            }
            guard Task.isCancelled == false else { return }
            providerBalancesByID = loaded
        }
    }
}

private struct HeaderBar: View {
    let onAdd: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.tr("Providers"))
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            Spacer(minLength: 12)

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(OriveoTheme.Palette.primary)
                    )
                    .overlay(
                        Circle()
                            .stroke(OriveoTheme.Palette.cardHighlight, lineWidth: 0.5)
                    )
                    .shadow(color: OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.45 : 0.30), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(HeaderAddButtonStyle())
            .accessibilityLabel(L10n.tr("Add Provider"))
        }
    }
}

private struct HeaderAddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeInOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct HeroCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.02 : 0)
            .animation(.spring(response: 0.30, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

private struct ProviderRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                OriveoTheme.Palette.textPrimary
                    .opacity(configuration.isPressed ? 0.05 : 0)
            )
            .scaleEffect(configuration.isPressed ? 0.995 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Section header

private enum SectionHeaderTone {
    case active
    case all
    case costs

    var accent: Color {
        switch self {
        case .active:
            return OriveoTheme.Palette.success
        case .all:
            return Color.dynamic(light: 0x2563EB, dark: 0x60A5FA)
        case .costs:
            return OriveoTheme.Palette.warning
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let systemImage: String
    let tone: SectionHeaderTone

    var body: some View {
        HStack(spacing: 7) {
            sectionIcon

            Text(title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
        }
        .padding(.leading, 4)
    }

    private var sectionIcon: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(tone.accent)
            .frame(width: 20, height: 20)
    }
}


private struct ProvidersSummaryStrip: View {
    let providerCount: Int
    let availableModelCount: Int
    let connectedCount: Int
    let syncingCount: Int
    let issueCount: Int

    @Environment(\.colorScheme) private var colorScheme

    private var statusBadge: ProvidersHeaderStatusSummary? {
        if issueCount > 0 {
            return .init(
                systemImage: "exclamationmark.triangle.fill",
                value: "\(issueCount)",
                label: L10n.tr("Issue", table: .providers),
                tone: .warning
            )
        }
        if syncingCount > 0 {
            return .init(
                systemImage: "arrow.triangle.2.circlepath",
                value: "\(syncingCount)",
                label: L10n.tr("Syncing", table: .providers),
                tone: .primary
            )
        }
        if providerCount > 0, connectedCount == providerCount {
            return .init(
                systemImage: "checkmark.circle.fill",
                value: nil,
                label: L10n.tr("All synced", table: .providers),
                tone: .success
            )
        }
        if providerCount > 0 {
            return .init(
                systemImage: "circle.lefthalf.filled",
                value: "\(connectedCount)/\(providerCount)",
                label: L10n.tr("Connected", table: .providers),
                tone: .success
            )
        }
        return nil
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                metricsLine
                Spacer(minLength: 0)
                if let badge = statusBadge {
                    ProvidersHeaderStatusBadge(status: badge)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                metricsLine
                if let badge = statusBadge {
                    ProvidersHeaderStatusBadge(status: badge)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var metricsLine: some View {
        HStack(spacing: 8) {
            countText(format: L10n.tr("%lld providers"), count: providerCount)
            dotDivider
            countText(format: L10n.tr("%lld models"), count: availableModelCount)
        }
    }

    private func countText(format: String, count: Int) -> Text {
        let full = String(format: format, Int64(count))
        let digits = "\(count)"
        guard let range = full.range(of: digits) else {
            return Text(full)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OriveoTheme.Palette.textSecondary)
        }
        let prefix = String(full[..<range.lowerBound])
        let suffix = String(full[range.upperBound...])
        let bold = Text(digits)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(OriveoTheme.Palette.textPrimary)
            .monospacedDigit()
        let lead = Text(prefix)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(OriveoTheme.Palette.textSecondary)
        let trail = Text(suffix)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(OriveoTheme.Palette.textSecondary)
        return lead + bold + trail
    }

    private var dotDivider: some View {
        Circle()
            .fill(OriveoTheme.Palette.textTertiary.opacity(0.5))
            .frame(width: 3, height: 3)
            .padding(.horizontal, 2)
    }
}

private struct ProvidersHeaderStatusSummary {
    let systemImage: String
    let value: String?
    let label: String
    let tone: StatusTone
}

private struct ProvidersHeaderStatusBadge: View {
    let status: ProvidersHeaderStatusSummary

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(status.tone.foreground.opacity(0.92))

            if let value = status.value {
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .monospacedDigit()
            }

            Text(status.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(status.tone.foreground.opacity(colorScheme == .dark ? 0.14 : 0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(status.tone.foreground.opacity(colorScheme == .dark ? 0.24 : 0.18), lineWidth: 0.6)
        )
    }
}

// MARK: - Spotlight carousel

private struct SpotlightCarousel: View {
    let providers: [Provider]
    @Binding var currentIndex: Int
    let costForProvider: (Provider) -> Double
    let dailyCostsForProvider: (Provider) -> [Double]
    let onTap: (Provider) -> Void

    var body: some View {
        VStack(spacing: 12) {
            TabView(selection: $currentIndex) {
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                    Button { onTap(provider) } label: {
                        ProviderHeroCard(
                            provider: provider,
                            monthlyEstimatedCost: costForProvider(provider),
                            dailyCostsLast7Days: dailyCostsForProvider(provider)
                        )
                        .padding(.horizontal, 2)
                    }
                    .buttonStyle(HeroCardButtonStyle())
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 172)

            HStack(spacing: 6) {
                ForEach(0..<providers.count, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(
                            i == currentIndex
                                ? OriveoTheme.Palette.textPrimary.opacity(0.78)
                                : OriveoTheme.Palette.textTertiary.opacity(0.35)
                        )
                        .frame(width: i == currentIndex ? 18 : 6, height: 6)
                        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: currentIndex)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}


private struct ProvidersFullEmptyState: View {
    let onAdd: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.35 : 0.18),
                                OriveoTheme.Palette.primary.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 70
                        )
                    )
                    .frame(width: 140, height: 140)

                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [OriveoTheme.Palette.primary, OriveoTheme.Palette.primaryPressed],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 8) {
                Text(L10n.tr("Connect your first provider", table: .providers))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)

                Text(L10n.tr("Connect a provider first. Model switching, chat, and cost transparency all start here.", table: .providers))
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 300)
            }

            Button(action: onAdd) {
                HStack(spacing: 7) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(L10n.tr("Add Provider"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [OriveoTheme.Palette.primary, OriveoTheme.Palette.primaryPressed],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.45 : 0.28), radius: 12, x: 0, y: 6)
            }
            .buttonStyle(HeaderAddButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(OriveoTheme.Palette.surface.opacity(colorScheme == .dark ? 0.55 : 0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(OriveoTheme.Palette.border.opacity(0.6), lineWidth: 0.5)
        )
        .padding(.top, 8)
    }
}

// MARK: - Providers Screen Background

private struct ProvidersScreenBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(baseFillStyle)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.06 : 0.10),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: colorScheme == .dark ? 400 : 440
                        )
                    )
                    .frame(
                        width: colorScheme == .dark ? 600 : 580,
                        height: colorScheme == .dark ? 600 : 580
                    )
                    .position(
                        x: geo.size.width / 2,
                        y: colorScheme == .dark ? -100 : -70
                    )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                OriveoTheme.Palette.primary.opacity(colorScheme == .dark ? 0.05 : 0.08),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: colorScheme == .dark ? 380 : 420
                        )
                    )
                    .frame(
                        width: colorScheme == .dark ? 560 : 540,
                        height: colorScheme == .dark ? 560 : 540
                    )
                    .position(
                        x: geo.size.width / 2,
                        y: geo.size.height + (colorScheme == .dark ? 80 : 60)
                    )
            }
        }
        .ignoresSafeArea()
    }

    private var baseFillStyle: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        OriveoTheme.Palette.backgroundBase,
                        OriveoTheme.Palette.background,
                        OriveoTheme.Palette.backgroundBase
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }

        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    OriveoTheme.Palette.backgroundBase,
                    OriveoTheme.Palette.background,
                    OriveoTheme.Palette.surfaceInset
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

#Preview {
    ProvidersView()
        .environment(AppState.preview)
}
