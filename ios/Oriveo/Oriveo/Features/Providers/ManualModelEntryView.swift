import SwiftUI

struct ManualModelEntryView: View {
    let providerID: UUID
    let context: ManualModelEntryContext

    @Environment(AppState.self) private var appState

    @State private var modelID = ""
    @State private var retryError: OriveoError?
    @FocusState private var modelIDFocused: Bool

    private var provider: Provider? {
        appState.provider(for: providerID)
    }

    private var isRelayMode: Bool { provider?.kind == .relay }

    private static let relayExamples: [ManualEntryExampleSuggestion] = [
        .init(modelID: "gpt-4o", providerKind: .openAI),
        .init(modelID: "claude-sonnet-4.5", providerKind: .anthropic),
        .init(modelID: "gemini-2.5-flash", providerKind: .gemini)
    ]

    private var defaultPreviewCapabilities: [ModelCapability] {
        guard let kind = provider?.kind else { return [] }
        let defaults = ProviderManager.defaultManualModelCapabilities(for: kind)
        return [.text, .reasoning, .image, .file, .web].filter(defaults.contains)
    }

    private var trimmedModelID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if provider == nil {
                Spacer()
                ProgressView()
                    .tint(OriveoTheme.Palette.primary)
                Spacer()
            } else {
                content
            }
        }
        .oriveoScreenBackground()
        .safeAreaInset(edge: .bottom) {
            if provider != nil {
                bottomBar
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(spacing: 28) {
                if let provider {
                    spotlightHero(provider: provider)
                        .padding(.top, OriveoTheme.Spacing.sm)
                }

                VStack(alignment: .leading, spacing: 28) {
                    inputSection

                    if isRelayMode {
                        examplesSection
                    }

                    if !trimmedModelID.isEmpty, let provider {
                        previewCard(provider: provider)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }

                    if let retryError {
                        OriveoErrorCard(error: retryError) {
                            self.retryError = nil
                        }
                    }
                }
                .padding(.horizontal, OriveoTheme.Spacing.xl)
            }
            .padding(.bottom, OriveoTheme.Spacing.xxl)
            .animation(
                .spring(response: 0.36, dampingFraction: 0.84),
                value: trimmedModelID.isEmpty
            )
        }
    }

    // MARK: - Spotlight Editorial Hero

    private func spotlightHero(provider: Provider) -> some View {
        VStack(spacing: 16) {
            spotlightBadge(provider: provider)

            VStack(spacing: 6) {
                Text("\(provider.displayName) • \(providerKindLabel(provider))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(heroTitle)
                    .font(OriveoTheme.Typography.hero)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                accentLine
                    .padding(.top, 2)

                Text(headerSubtitle)
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(.horizontal, OriveoTheme.Spacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    private func spotlightBadge(provider: Provider) -> some View {
        ZStack {
            ProviderBadgeIcon(
                kind: provider.kind,
                size: 64,
                relayKind: provider.kind == .relay ? provider.relayKind : nil
            )
        }
        .frame(height: 180)
    }

    private var accentLine: some View {
        Capsule(style: .continuous)
            .fill(OriveoTheme.Palette.primaryGradient)
            .frame(width: 36, height: 3)
    }

    private func providerKindLabel(_ provider: Provider) -> String {
        if provider.kind == .relay {
            let relayKind = provider.relayKind ?? .custom
            return RelayKindMeta.meta(for: relayKind).title
        }
        return provider.kind.displayName
    }

    private var heroTitle: String {
        isRelayMode
            ? L10n.tr("Add a model", table: .providers)
            : L10n.tr("Enter model ID manually", table: .providers)
    }


    private func sectionCaps(_ rawText: String) -> some View {
        Text(L10n.tr(rawText).uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            sectionCaps("Model ID")

            HStack(spacing: OriveoTheme.Spacing.sm) {
                TextField(modelIDPlaceholder, text: $modelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .focused($modelIDFocused)

                if !modelID.isEmpty {
                    Button {
                        modelID = ""
                        modelIDFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("Clear"))
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .frame(height: 56)
            .overlay(alignment: .bottom) { animatedUnderline }
            .animation(.easeInOut(duration: 0.16), value: modelID.isEmpty)

            Text(modelIDFootnote)
                .lineLimit(3)
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
        }
    }

    private var animatedUnderline: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(OriveoTheme.Palette.border)
                    .frame(height: 1.5)

                Rectangle()
                    .fill(OriveoTheme.Palette.primaryGradient)
                    .frame(width: modelIDFocused ? geo.size.width : 0, height: 2.5)
                    .animation(.spring(response: 0.42, dampingFraction: 0.78), value: modelIDFocused)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 2.5)
    }

    // MARK: - Examples(Relay only)

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            sectionCaps("Common examples")

            VStack(spacing: 0) {
                ForEach(Array(Self.relayExamples.enumerated()), id: \.element) { index, example in
                    ExampleListRow(suggestion: example) {
                        modelID = example.modelID
                        modelIDFocused = true
                    }

                    if index < Self.relayExamples.count - 1 {
                        Divider()
                            .background(OriveoTheme.Palette.border)
                            .padding(.leading, 60)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(OriveoTheme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(OriveoTheme.Palette.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: OriveoTheme.Palette.shadow.opacity(0.6), radius: 6, y: 3)
        }
    }

    // MARK: - Preview Card

    private func previewCard(provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)

                sectionCaps("Will be added")

                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
                ProviderBadgeIcon(
                    kind: provider.kind,
                    size: 36,
                    relayKind: provider.kind == .relay ? provider.relayKind : nil
                )

                Text(trimmedModelID)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                sectionCaps("Default capabilities")

                ManualEntryFlow(spacing: 6) {
                    ForEach(defaultPreviewCapabilities, id: \.self) { cap in
                        capabilityChip(cap)
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OriveoTheme.Palette.primarySoft)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    OriveoTheme.Palette.cardHighlight,
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(OriveoTheme.Palette.primary.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: OriveoTheme.Palette.primaryGlow, radius: 14, y: 6)
    }

    private func capabilityChip(_ capability: ModelCapability) -> some View {
        HStack(spacing: 4) {
            Image(systemName: capability.systemImage)
                .font(.system(size: 10, weight: .medium))
            Text(capability.title)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(OriveoTheme.Palette.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(OriveoTheme.Palette.cardHighlight)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(OriveoTheme.Palette.primary.opacity(0.20), lineWidth: 0.8)
        )
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        let isModelEmpty = trimmedModelID.isEmpty
        let disabled = isModelEmpty

        return VStack(spacing: OriveoTheme.Spacing.md) {
            Button(primaryButtonTitle) {
                saveManualModel()
            }
            .buttonStyle(OriveoPrimaryButtonStyle())
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)
            .shadow(
                color: disabled ? .clear : OriveoTheme.Palette.primaryGlow,
                radius: disabled ? 0 : 16,
                y: disabled ? 0 : 8
            )
            .animation(.easeInOut(duration: 0.18), value: disabled)

            if !isRelayMode {
                Button(L10n.tr("Retry Sync", table: .providers)) {
                    Task { await retrySync() }
                }
                .buttonStyle(OriveoSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.xl)
        .padding(.vertical, OriveoTheme.Spacing.lg)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(height: 0.5)
        }
    }


    private var headerSubtitle: String {
        isRelayMode
            ? L10n.tr("Enter a model ID your relay supports.", table: .providers)
            : L10n.tr("If auto-sync fails or model listing isn't supported, you can still continue.", table: .providers)
    }

    private var modelIDPlaceholder: String {
        isRelayMode
            ? L10n.tr("For example: gpt-image-2 or claude-4-sonnet", table: .providers)
            : L10n.tr("For example: claude-4-sonnet or gpt-4o", table: .providers)
    }

    private var modelIDFootnote: String {
        isRelayMode
            ? L10n.tr("Use the exact model ID exposed by your relay.", table: .providers)
            : L10n.tr("Just enter one usable model ID. You don't need to understand the protocol details.", table: .providers)
    }

    private var primaryButtonTitle: String {
        isRelayMode ? L10n.tr("Save") : L10n.tr("Save & Continue", table: .providers)
    }

    private var topBar: some View {
        HStack {
            Button {
                appState.pop()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(isRelayMode ? L10n.tr("Add Model", table: .providers) : L10n.tr("Fallback Model", table: .providers))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer()

            Color.clear
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, OriveoTheme.Spacing.md)
    }

    private func retrySync() async {
        guard let provider else { return }

        if provider.kind.supportsModelCatalogSync {
            do {
                try await appState.resyncProvider(providerID: provider.id)
                retryError = nil

                if context == .onboarding {
                    appState.completeProviderSetup(providerID: provider.id, entryPoint: .welcome)
                } else if context == .skillEdit {
                    appState.pop()
                    appState.pop()
                } else {
                    appState.pop()
                }
            } catch {
                retryError = makeProviderError(error, actionTitle: L10n.tr("Try Again"))
            }
        } else {
            retryError = OriveoError(
                id: UUID(),
                title: L10n.tr("Model Sync Failed", table: .providers),
                message: L10n.tr("This provider does not currently guarantee stable automatic model sync. Please continue with a manual model ID.", table: .providers),
                actionTitle: L10n.tr("Got It"),
                detail: L10n.tr("This provider does not support automatic model sync. You can manually enter a model ID instead.", table: .providers),
                severity: .warning
            )
        }
    }

    private func saveManualModel() {
        let trimmed = trimmedModelID
        guard !trimmed.isEmpty else { return }

        let didSave = appState.saveManualModel(
            providerID: providerID,
            modelID: trimmed,
            context: context
        )
        guard !didSave else { return }

        retryError = makeProviderError(
            ProviderServiceError.invalidConfiguration(
                detail: "This connection does not accept a manually entered model id."
            ),
            actionTitle: L10n.tr("Got It")
        )
    }
}


private struct ManualEntryExampleSuggestion: Hashable {
    let modelID: String
    let providerKind: ProviderKind
}

// MARK: - Example List Row

private struct ExampleListRow: View {
    let suggestion: ManualEntryExampleSuggestion
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: OriveoTheme.Spacing.md) {
                ProviderBadgeIcon(kind: suggestion.providerKind, size: 32)

                Text(suggestion.modelID)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.left.circle.fill")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(OriveoTheme.Palette.primary.opacity(0.85))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableScaleButtonStyle())
        .accessibilityHint(L10n.tr("Tap to fill", table: .providers))
    }
}

private struct PressableScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

// MARK: - Flow Layout

private struct ManualEntryFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, maxWidth: maxWidth)
        let totalHeight = rows.reduce(into: CGFloat(0)) { acc, row in
            acc += row.height + (acc == 0 ? 0 : spacing)
        }
        let totalWidth = maxWidth.isFinite ? maxWidth : rows.map(\.width).max() ?? 0
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needsBreak = !rows[rows.count - 1].indices.isEmpty && (x + size.width > maxWidth)
            if needsBreak {
                rows.append(Row())
                x = 0
            }
            let lastIdx = rows.count - 1
            rows[lastIdx].indices.append(index)
            rows[lastIdx].height = max(rows[lastIdx].height, size.height)
            x += size.width + spacing
            rows[lastIdx].width = x - spacing
        }
        return rows
    }
}
