import SwiftUI

private enum ProviderCategoryFilter: String, CaseIterable {
    case all, direct, aggregators, custom
}

struct ProviderSetupView: View {
    let entryPoint: ProviderSetupEntryPoint
    let preselectedKind: ProviderKind?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind: ProviderKind?
    @State private var apiKey = ""
    @State private var isSubmitting = false
    @State private var submitTask: Task<Void, Never>?
    @State private var showConnectionSettings = false
    @State private var selectedCategory: ProviderCategoryFilter = .all
    @State private var inlineStatusText: String?
    @State private var setupError: OriveoError?
    @State private var providerSelectionIsManual = false
    @State private var selectedEndpointID = ""
    @State private var hasAppliedPreselection = false
    @State private var didHandOffToRelay = false
    @State private var isAdditionalInstance = false
    @State private var connectedActionKind: ProviderKind?
    @State private var grokAuthMode: ProviderAuthMode = .apiKey
    @State private var showsGrokSubscriptionSheet = false
    @State private var openAIAuthMode: ProviderAuthMode = .apiKey
    @State private var showsOpenAISubscriptionSheet = false

    private var isModelPickerContext: Bool { entryPoint == .modelPicker }

    private let providerColumns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top),
    ]

    private var setupCatalog: ProviderSetupCatalog {
        ProviderSetupCatalog.current()
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isModelPickerContext {
                topBar
            }

            if let setupError {
                ProviderSetupTopErrorBanner(error: setupError) {
                    self.setupError = nil
                }
                .padding(.horizontal, OriveoTheme.Spacing.xl)
                .padding(.bottom, OriveoTheme.Spacing.md)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let inlineStatusText {
                providerSetupSyncingStatusBanner(text: inlineStatusText)
                    .padding(.horizontal, OriveoTheme.Spacing.xl)
                    .padding(.bottom, OriveoTheme.Spacing.md)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                        SetupHeroSection(compact: preselectedKind != nil)

                        ProviderCategoryChips(selected: $selectedCategory)

                        if selectedCategory == .custom {
                            VStack(alignment: .leading, spacing: 8) {
                                LocalComputeEntry {
                                    didHandOffToRelay = true
                                    appState.navigation.path.append(.localComputeSetup(entryPoint: entryPoint))
                                }

                                CustomRelayEntry {
                                    didHandOffToRelay = true
                                    appState.openRelaySetup(from: entryPoint)
                                }
                            }
                        } else {
                            if selectedCategory == .all || selectedCategory == .direct {
                                providerSection(
                                    label: L10n.tr("Direct AI Providers", table: .providers),
                                    providers: setupCatalog.directProviders
                                )
                            }

                            if selectedCategory == .all || selectedCategory == .aggregators {
                                providerSection(
                                    label: L10n.tr("Aggregators", table: .providers),
                                    providers: setupCatalog.aggregatorProviders
                                )
                            }

                            if let selectedKind {
                                if selectedKind == .grok, grokSubscriptionConfig != nil {
                                    GrokConnectionModeSection(mode: $grokAuthMode)
                                        .id("grokAuthMode")
                                } else if selectedKind == .openAI, openAISubscriptionConfig != nil {
                                    OpenAIConnectionModeSection(mode: $openAIAuthMode)
                                        .id("openAIAuthMode")
                                }

                                if usesGrokSubscriptionFlow {
                                    GrokSubscriptionConnectSection(isSubmitting: isSubmitting) {
                                        showsGrokSubscriptionSheet = true
                                    }
                                } else if usesOpenAISubscriptionFlow {
                                    OpenAISubscriptionConnectSection(isSubmitting: isSubmitting) {
                                        showsOpenAISubscriptionSheet = true
                                    }
                                } else {
                                    APIKeyConnectionSection(
                                        kind: selectedKind,
                                        setupCatalog: setupCatalog,
                                        apiKey: apiKeyBinding,
                                        isSubmitting: isSubmitting,
                                        footnote: providerFootnoteText(for: selectedKind),
                                        onConnectionSettings: { showConnectionSettings = true }
                                    )
                                    .id("apiKeySection")

                                    if !setupCatalog.setupEndpointOptions(for: selectedKind).isEmpty {
                                        ProviderEndpointPicker(
                                            kind: selectedKind,
                                            setupCatalog: setupCatalog,
                                            selectedOptionID: $selectedEndpointID
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, OriveoTheme.Spacing.xl)
                    .padding(.bottom, OriveoTheme.Spacing.xl)
                    .padding(.top, OriveoTheme.Spacing.xs)
                    .animation(.spring(response: 0.4, dampingFraction: 0.88), value: selectedKind != nil)
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedCategory)
                }
                .onChange(of: selectedKind) { _, newValue in
                    guard newValue != nil else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                            proxy.scrollTo("apiKeySection", anchor: .top)
                        }
                    }
                }
            }
        }
        .oriveoScreenBackground()
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: setupError != nil)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: inlineStatusText != nil)
        .onAppear {
            if didHandOffToRelay {
                didHandOffToRelay = false
                selectedKind = nil
            }
            applyPreselectedKindIfNeeded()
            SwipeBackCoordinator.shared.isBackSwipeEnabled = !isSubmitting
        }
        .onChange(of: isSubmitting) { _, newValue in
            SwipeBackCoordinator.shared.isBackSwipeEnabled = !newValue
        }
        .onDisappear {
            submitTask?.cancel()
            submitTask = nil
            SwipeBackCoordinator.shared.isBackSwipeEnabled = true
        }
        .navigationTitle(isModelPickerContext ? L10n.tr("Add Provider") : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isModelPickerContext ? .visible : .hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if selectedCategory != .custom, !usesSubscriptionFlow {
                VStack(spacing: 0) {
                    Divider()
                        .overlay(OriveoTheme.Palette.border)

                    Button(isSubmitting ? L10n.tr("Working...", table: .providers) : L10n.tr("Continue")) {
                        beginSubmit()
                    }
                    .buttonStyle(OriveoPrimaryButtonStyle())
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.4)
                    .padding(.horizontal, OriveoTheme.Spacing.xl)
                    .padding(.top, OriveoTheme.Spacing.lg)
                    .padding(.bottom, OriveoTheme.Spacing.lg)
                    .background(OriveoTheme.Palette.surfaceChrome)
                }
            }
        }
        .sheet(isPresented: $showConnectionSettings) {
            ConnectionSettingsSheet(
                selectedKind: selectedKind,
                setupCatalog: setupCatalog,
                selectedEndpointOption: selectedKind.flatMap {
                    setupCatalog.resolvedSetupEndpointOption(for: $0, baseURLText: selectedBaseURLText(for: $0))
                },
                selectedBaseURLText: selectedKind.flatMap { selectedBaseURLText(for: $0) }
            )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsGrokSubscriptionSheet) {
            if let config = grokSubscriptionConfig {
                GrokSubscriptionAuthorizationSheet(config: config) { tokens in
                    submitTask = Task { await completeGrokSubscriptionSetup(tokens: tokens) }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showsOpenAISubscriptionSheet) {
            if let config = openAISubscriptionConfig {
                OpenAISubscriptionAuthorizationSheet(config: config) { tokens in
                    submitTask = Task { await completeOpenAISubscriptionSetup(tokens: tokens) }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog(
            connectedActionKind.map { setupCatalog.displayName(for: $0) } ?? "",
            isPresented: Binding(
                get: { connectedActionKind != nil },
                set: { if !$0 { connectedActionKind = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let kind = connectedActionKind {
                Button(L10n.tr("Manage existing", table: .providers)) {
                    connectedActionKind = nil
                    manageExistingProvider(kind)
                }
                Button(L10n.tr("Add another account", table: .providers)) {
                    connectedActionKind = nil
                    isAdditionalInstance = true
                    selectProvider(kind, manual: true)
                }
                Button(L10n.tr("Cancel"), role: .cancel) {
                    connectedActionKind = nil
                }
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func providerSection(label: String, providers: [ProviderKind]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(OriveoTheme.Typography.eyebrow)
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .padding(.leading, 2)

            LazyVGrid(columns: providerColumns, spacing: 12) {
                ForEach(providers, id: \.self) { kind in
                    ProviderShowcaseCard(
                        kind: kind,
                        setupCatalog: setupCatalog,
                        isSelected: selectedKind == kind,
                        isConnected: connectedCount(for: kind) > 0
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { handleProviderTap(kind) }
                }
            }
        }
    }

    private func providerSetupSyncingStatusBanner(text: String) -> some View {
        OriveoCard(fill: OriveoTheme.Palette.primarySoft, border: OriveoTheme.Palette.primary.opacity(0.2)) {
            HStack(spacing: OriveoTheme.Spacing.md) {
                ProgressView()
                    .tint(OriveoTheme.Palette.primary)
                Text(text)
                    .font(OriveoTheme.Typography.caption)
                    .foregroundStyle(OriveoTheme.Palette.primary)
            }
        }
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
            .disabled(isSubmitting)
            .opacity(isSubmitting ? 0.45 : 1)

            Spacer()

            Text(L10n.tr("Add Provider"))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            Spacer()

            Color.clear
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, OriveoTheme.Spacing.md)
    }

    // MARK: - API Key binding

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { apiKey },
            set: { newValue in
                apiKey = newValue
                inlineStatusText = nil
                setupError = nil

                guard !providerSelectionIsManual else { return }
                let inferredKind = ProviderKind.inferred(fromAPIKey: newValue)
                if selectedKind != inferredKind {
                    selectedEndpointID = inferredKind.flatMap { setupCatalog.defaultSetupEndpointID(for: $0) } ?? ""
                }
                selectedKind = inferredKind
            }
        )
    }

    // MARK: - State & logic

    private var canContinue: Bool {
        selectedCategory != .custom
            && selectedKind != nil
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
    }

    private var grokSubscriptionConfig: GrokSubscriptionAuthConfig? {
        guard case let .available(config) = MetadataClient.shared.syncGrokSubscriptionAvailability() else {
            return nil
        }
        return config
    }

    private var usesGrokSubscriptionFlow: Bool {
        selectedKind == .grok && grokAuthMode == .subscription && grokSubscriptionConfig != nil
    }

    private var openAISubscriptionConfig: OpenAISubscriptionAuthConfig? {
        guard case let .available(config) = MetadataClient.shared.syncOpenAISubscriptionAvailability() else {
            return nil
        }
        return config
    }

    private var usesOpenAISubscriptionFlow: Bool {
        selectedKind == .openAI && openAIAuthMode == .subscription && openAISubscriptionConfig != nil
    }

    private var usesSubscriptionFlow: Bool {
        usesGrokSubscriptionFlow || usesOpenAISubscriptionFlow
    }

    private func connectedCount(for kind: ProviderKind) -> Int {
        guard kind != .relay else { return 0 }
        return appState.providers.filter { $0.kind == kind }.count
    }

    private func handleProviderTap(_ kind: ProviderKind) {
        if connectedCount(for: kind) > 0 {
            connectedActionKind = kind
        } else {
            isAdditionalInstance = false
            selectProvider(kind, manual: true)
        }
    }

    private func selectProvider(_ kind: ProviderKind, manual: Bool) {
        providerSelectionIsManual = manual
        inlineStatusText = nil
        setupError = nil

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            selectedKind = kind
            selectedEndpointID = setupCatalog.defaultSetupEndpointID(for: kind) ?? ""
        }
    }

    private func manageExistingProvider(_ kind: ProviderKind) {
        if let existing = appState.providers.first(where: { $0.kind == kind }) {
            appState.openProviderDetail(providerID: existing.id)
        } else {
            appState.pop()
        }
    }

    private func applyPreselectedKindIfNeeded() {
        guard !hasAppliedPreselection, let preselectedKind else { return }
        hasAppliedPreselection = true
        selectProvider(preselectedKind, manual: true)
    }

    private func continueTapped() async {
        guard let selectedKind else { return }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.isEmpty || ProviderKeyInput.isPrintableASCII(trimmedKey) else {
            setupError = ProviderKeyInput.illegalCharsError()
            return
        }
        let endpointOverride = setupCatalog.usesConfigurableBaseURL(selectedKind)
            ? setupCatalog.resolvedSetupBaseURLText(for: selectedKind, optionID: selectedEndpointID)
            : setupCatalog.defaultBaseURLText(for: selectedKind)

        setupError = nil
        inlineStatusText = L10n.tr("Validating connection and syncing models...", table: .providers)
        isSubmitting = true

        do {
            let provider = try await appState.registerProvider(
                kind: selectedKind,
                apiKey: trimmedKey,
                baseURLText: endpointOverride,
                isAdditionalInstance: isAdditionalInstance
            )

            if Task.isCancelled {
                inlineStatusText = nil
                isSubmitting = false
                return
            }

            finalizeSetup(provider: provider, kind: selectedKind)
        } catch is CancellationError {
            inlineStatusText = nil
            isSubmitting = false
        } catch {
            setupError = makeProviderError(error)
            inlineStatusText = nil
            isSubmitting = false
        }
    }

    private func finalizeSetup(provider: Provider, kind: ProviderKind) {
        inlineStatusText = nil
        isSubmitting = false

        if ProviderManager.providerStatusIsIssue(provider.status) {
            ToastManager.shared.show(
                L10n.tr("Saved, but the key looks invalid. You can verify it later in provider settings.", table: .providers),
                style: .warning
            )
        } else if let softError = provider.lastError?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !softError.isEmpty {
            ToastManager.shared.show(ProviderIssueMessage.localized(softError), style: .warning)
        }

        if isModelPickerContext {
            appState.completeProviderSetup(providerID: provider.id, entryPoint: entryPoint)
            dismiss()
        } else if kind.supportsModelCatalogSync {
            appState.completeProviderSetup(providerID: provider.id, entryPoint: entryPoint)
        } else {
            let context: ManualModelEntryContext
            if entryPoint == .welcome {
                context = .onboarding
            } else if entryPoint == .skillEdit {
                context = .skillEdit
            } else {
                context = .providers
            }
            appState.openManualModelEntry(providerID: provider.id, context: context)
        }
    }

    private func completeGrokSubscriptionSetup(tokens: GrokSubscriptionTokens) async {
        setupError = nil
        inlineStatusText = L10n.tr("Validating connection and syncing models...", table: .providers)
        isSubmitting = true

        do {
            let provider = try await appState.registerProvider(
                kind: .grok,
                apiKey: tokens.accessToken,
                baseURLText: setupCatalog.defaultBaseURLText(for: .grok),
                isAdditionalInstance: isAdditionalInstance,
                authMode: .subscription
            )
            if Task.isCancelled {
                inlineStatusText = nil
                isSubmitting = false
                return
            }
            GrokSubscriptionRuntime.persist(tokens: tokens, providerID: provider.id)
            finalizeSetup(provider: provider, kind: .grok)
        } catch is CancellationError {
            inlineStatusText = nil
            isSubmitting = false
        } catch {
            setupError = makeProviderError(error)
            inlineStatusText = nil
            isSubmitting = false
        }
    }

    private func completeOpenAISubscriptionSetup(tokens: OpenAISubscriptionTokens) async {
        setupError = nil
        inlineStatusText = L10n.tr("Validating connection and syncing models...", table: .providers)
        isSubmitting = true

        do {
            let provider = try await appState.registerProvider(
                kind: .openAI,
                apiKey: tokens.accessToken,
                baseURLText: setupCatalog.defaultBaseURLText(for: .openAI),
                isAdditionalInstance: isAdditionalInstance,
                authMode: .subscription,
                subscriptionAccountID: tokens.accountID
            )
            if Task.isCancelled {
                inlineStatusText = nil
                isSubmitting = false
                return
            }
            OpenAISubscriptionRuntime.persist(tokens: tokens, providerID: provider.id)
            finalizeSetup(provider: provider, kind: .openAI)
        } catch is CancellationError {
            inlineStatusText = nil
            isSubmitting = false
        } catch {
            setupError = makeProviderError(error)
            inlineStatusText = nil
            isSubmitting = false
        }
    }

    private func beginSubmit() {
        guard submitTask == nil else { return }

        submitTask = Task {
            await continueTapped()
            await MainActor.run {
                submitTask = nil
            }
        }
    }

    private func selectedBaseURLText(for kind: ProviderKind) -> String? {
        if setupCatalog.usesConfigurableBaseURL(kind) {
            return setupCatalog.resolvedSetupBaseURLText(for: kind, optionID: selectedEndpointID)
        }
        return setupCatalog.defaultBaseURLText(for: kind)
    }

    private func providerFootnoteText(for kind: ProviderKind) -> String? {
        kind.setupEndpointFootnote ?? setupCatalog.autoFillNote(for: kind)
    }
}


private struct SetupHeroSection: View {
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                OriveoTheme.Palette.primary.opacity(0.22),
                                OriveoTheme.Palette.primary.opacity(0.06),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: compact ? 52 : 66
                        )
                    )
                    .frame(width: compact ? 108 : 138, height: compact ? 108 : 138)
                    .blur(radius: 14)

                let iconSize: CGFloat = compact ? 54 : 66
                let iconRadius: CGFloat = compact ? 16 : 20
                let symbolSize: CGFloat = compact ? 23 : 28

                ZStack {
                    RoundedRectangle(cornerRadius: iconRadius, style: .continuous)
                        .fill(OriveoTheme.Palette.primaryGradient)

                    RoundedRectangle(cornerRadius: iconRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.45), location: 0),
                                    .init(color: .white.opacity(0.10), location: 0.45),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    RoundedRectangle(cornerRadius: iconRadius - 4, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .padding(5)

                    RoundedRectangle(cornerRadius: iconRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.6), .white.opacity(0.05), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )

                    Image(systemName: "link.badge.plus")
                        .font(.system(size: symbolSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                }
                .frame(width: iconSize, height: iconSize)
                .shadow(color: OriveoTheme.Palette.primary.opacity(0.40), radius: 14, y: 6)
                .shadow(color: OriveoTheme.Palette.primary.opacity(0.22), radius: 4, y: 1)
            }

            VStack(spacing: 4) {
                Text(L10n.tr("Connect a Provider", table: .providers))
                    .font(.system(size: compact ? 18 : 20, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)

                Text(L10n.tr("Choose your AI provider, then enter your API key", table: .providers))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, compact ? 0 : 2)
        .padding(.bottom, compact ? 4 : 8)
    }
}


private struct ChipBarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ProviderCategoryChips: View {
    @Binding var selected: ProviderCategoryFilter
    @State private var barWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ProviderCategoryFilter.allCases, id: \.self) { category in
                    let isActive = selected == category
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            selected = category
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: chipIcon(for: category))
                                .font(.system(size: 11, weight: .semibold))
                            Text(chipLabel(for: category))
                                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .foregroundStyle(isActive ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(isActive ? OriveoTheme.Palette.primarySoft : OriveoTheme.Palette.surface)
                        )
                        .overlay(
                            Capsule()
                                .stroke(
                                    isActive ? OriveoTheme.Palette.primary.opacity(0.25) : OriveoTheme.Palette.border,
                                    lineWidth: 0.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .frame(minWidth: barWidth, alignment: .center)
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ChipBarWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(ChipBarWidthKey.self) { barWidth = $0 }
    }

    private func chipLabel(for category: ProviderCategoryFilter) -> String {
        switch category {
        case .all: return L10n.tr("All")
        case .direct: return L10n.tr("Direct", table: .providers)
        case .aggregators: return L10n.tr("Aggregators", table: .providers)
        case .custom: return L10n.tr("Custom", table: .providers)
        }
    }

    private func chipIcon(for category: ProviderCategoryFilter) -> String {
        switch category {
        case .all: return "square.grid.2x2.fill"
        case .direct: return "bolt.fill"
        case .aggregators: return "square.stack.3d.up.fill"
        case .custom: return "slider.horizontal.3"
        }
    }
}


private struct ProviderShowcaseCard: View {
    let kind: ProviderKind
    let setupCatalog: ProviderSetupCatalog
    let isSelected: Bool
    var isConnected: Bool = false

    private var brandWatermark: some View {
        Group {
            if kind.brandLogoIsOpaqueTile {
                Image(systemName: kind.brandWatermarkSymbol)
                    .font(.system(size: 102, weight: .light))
                    .foregroundStyle(kind.chartFill.opacity(isSelected ? 0.16 : 0.11))
                    .rotationEffect(.degrees(-8))
            } else {
                kind.chartFill.opacity(isSelected ? 0.14 : 0.09)
                    .frame(width: 112, height: 112)
                    .mask {
                        Image(kind.brandAssetName)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 112, height: 112)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .offset(x: 24, y: 22)
        .allowsHitTesting(false)
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ProviderBadgeIcon(kind: kind, size: 36)
                .frame(width: 36, height: 36)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(kind.chartFill))
                        .shadow(color: kind.chartFill.opacity(0.35), radius: 3, y: 1)
                        .transition(.scale.combined(with: .opacity))
                } else if isConnected {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(OriveoTheme.Palette.success)
                            .frame(width: 5, height: 5)
                        Text(L10n.tr("Connected", table: .providers))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.success)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(OriveoTheme.Palette.success.opacity(0.12))
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.bottom, 8)

            Text(setupCatalog.displayName(for: kind))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? kind.chartFill : OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let tagline = setupCatalog.tagline(for: kind) {
                Text(L10n.tr(tagline))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .padding(12)
        .background {
            ZStack {
                cardShape.fill(kind.brandBackground)

                brandWatermark
            }
            .clipShape(cardShape)
        }
        .shadow(
            color: isSelected
                ? kind.chartFill.opacity(0.18)
                : OriveoTheme.Palette.shadow.opacity(0.45),
            radius: isSelected ? 12 : 8,
            y: isSelected ? 5 : 3
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSelected)
    }
}


private struct LocalComputeEntry: View {
    let onTap: () -> Void

    var body: some View {
        CustomProviderEntry(
            title: L10n.tr("Local compute", table: .providers),
            subtitle: L10n.tr("Connect Ollama, LM Studio, llama.cpp, or vLLM", table: .providers),
            systemImage: "cpu",
            iconColor: OriveoTheme.Palette.primary,
            onTap: onTap
        )
    }
}

private struct CustomRelayEntry: View {
    let onTap: () -> Void

    var body: some View {
        CustomProviderEntry(
            title: L10n.tr("Custom Relay", table: .providers),
            subtitle: L10n.tr("Use your own Codex, Claude, or Gemini relay", table: .providers),
            systemImage: "arrow.triangle.swap",
            iconColor: Color(hex: 0xF59E0B),
            onTap: onTap
        )
    }
}

private struct CustomProviderEntry: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let iconColor: Color
    let onTap: () -> Void

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        Button(action: onTap) {
            HStack(spacing: OriveoTheme.Spacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(iconColor)
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Text(subtitle)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 70)
            .background {
                ZStack {
                    cardShape.fill(OriveoTheme.Palette.surfaceElevated)
                    cardShape.fill(
                        LinearGradient(
                            colors: [OriveoTheme.Palette.cardHighlight.opacity(0.5), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                }
            }
            .clipShape(cardShape)
            .shadow(color: OriveoTheme.Palette.shadow.opacity(0.4), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }
}


private struct APIKeyConnectionSection: View {
    let kind: ProviderKind
    let setupCatalog: ProviderSetupCatalog
    @Binding var apiKey: String
    let isSubmitting: Bool
    let footnote: String?
    let onConnectionSettings: () -> Void

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous)

        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
            HStack(spacing: OriveoTheme.Spacing.md) {
                ProviderBadgeIcon(kind: kind, size: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: L10n.tr("Connect %@", table: .providers), setupCatalog.displayName(for: kind)))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)

                    Text(L10n.tr("Enter your API key to get started", table: .providers))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
            }

            OriveoLabeledField(
                title: "API Key",
                text: $apiKey,
                placeholder: setupCatalog.apiKeyPlaceholder(for: kind),
                footnote: footnote,
                isSecure: true,
                isEnabled: !isSubmitting
            )

            Button(L10n.tr("Connection settings", table: .providers)) {
                onConnectionSettings()
            }
            .buttonStyle(OriveoTextButtonStyle())
        }
        .padding(OriveoTheme.Spacing.xl)
        .background {
            ZStack(alignment: .topLeading) {
                cardShape.fill(OriveoTheme.Palette.surface)

                Circle()
                    .fill(kind.chartFill.opacity(0.08))
                    .frame(width: 100, height: 100)
                    .blur(radius: 20)
                    .offset(x: -30, y: -30)
            }
            .clipShape(cardShape)
        }
        .shadow(
            color: kind.chartFill.opacity(0.08),
            radius: 12, y: 4
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Error Banner

private struct ProviderSetupTopErrorBanner: View {
    let error: OriveoError
    let onDismiss: () -> Void

    private var foreground: Color {
        switch error.severity {
        case .warning:
            OriveoTheme.Palette.warning
        case .critical:
            OriveoTheme.Palette.danger
        }
    }

    private var background: Color {
        switch error.severity {
        case .warning:
            OriveoTheme.Palette.warningSoft
        case .critical:
            OriveoTheme.Palette.dangerSoft
        }
    }

    private var iconName: String {
        switch error.severity {
        case .warning:
            "exclamationmark.triangle.fill"
        case .critical:
            "exclamationmark.circle.fill"
        }
    }

    var body: some View {
        OriveoCard(fill: background, border: foreground.opacity(0.28)) {
            HStack(alignment: .top, spacing: OriveoTheme.Spacing.md) {
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(foreground)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                    Text(error.title)
                        .font(OriveoTheme.Typography.title3)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)

                    Text(error.message)
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Dismiss"))
            }
        }
    }
}

// MARK: - Advanced Settings

struct ConnectionSettingsSheet: View {
    let selectedKind: ProviderKind?
    let setupCatalog: ProviderSetupCatalog
    var selectedEndpointOption: ProviderEndpointOption? = nil
    var selectedBaseURLText: String? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                Text(L10n.tr("Connection settings", table: .providers))
                    .font(OriveoTheme.Typography.title1)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)

                OriveoCard {
                    VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                        settingRow(
                            title: L10n.tr("Provider", table: .providers),
                            value: selectedKind.map { setupCatalog.displayName(for: $0) } ?? L10n.tr("Auto")
                        )
                        if selectedKind.map({ !setupCatalog.setupEndpointOptions(for: $0).isEmpty }) == true {
                            settingRow(
                                title: selectedKind?.setupEndpointTitle ?? L10n.tr("Official Endpoint", table: .providers),
                                value: selectedKind.flatMap { kind in
                                    selectedEndpointOption.map { kind.localizedSetupEndpointLabel(for: $0) }
                                } ?? L10n.tr("Selectable", table: .providers)
                            )
                        }
                        settingRow(
                            title: L10n.tr("Base URL", table: .providers),
                            value: selectedBaseURLText
                                ?? (selectedKind.flatMap { setupCatalog.autoFillNote(for: $0) } == nil ? L10n.tr("Manual", table: .providers) : L10n.tr("Auto-filled", table: .providers))
                        )
                    }
                }

                Text(
                    selectedKind?.setupEndpointFootnote
                        ?? L10n.tr("These settings are automatically configured for each provider. Custom endpoint support will be available in a future update.", table: .providers)
                )
                    .font(OriveoTheme.Typography.caption)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)

                Spacer()

                Button(L10n.tr("Done")) {
                    dismiss()
                }
                .buttonStyle(OriveoPrimaryButtonStyle())
            }
            .padding(OriveoTheme.Spacing.xl)
            .oriveoScreenBackground()
        }
    }

    private func settingRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Spacer()
            Text(value)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
        }
    }
}


struct ProviderEndpointPicker: View {
    let kind: ProviderKind
    let setupCatalog: ProviderSetupCatalog
    @Binding var selectedOptionID: String

    private var options: [ProviderEndpointOption] {
        setupCatalog.setupEndpointOptions(for: kind)
    }

    private let columns = [
        GridItem(.flexible(), spacing: OriveoTheme.Spacing.md, alignment: .top),
        GridItem(.flexible(), spacing: OriveoTheme.Spacing.md, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                Text(kind.setupEndpointTitle)
                    .font(OriveoTheme.Typography.caption.weight(.medium))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)

                if let footnote = kind.setupEndpointFootnote {
                    Text(footnote)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                }
            }

            LazyVGrid(columns: columns, spacing: OriveoTheme.Spacing.md) {
                ForEach(options) { option in
                    let isSelected = selectedOptionID == option.id
                    ProviderEndpointOptionCard(
                        kind: kind,
                        option: option,
                        isSelected: isSelected
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            selectedOptionID = option.id
                        }
                    }
                }
            }
        }
    }
}

private struct ProviderEndpointOptionCard: View {
    let kind: ProviderKind
    let option: ProviderEndpointOption
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: OriveoTheme.Spacing.sm) {
                StatusPill(
                    title: option.id.uppercased(),
                    tone: isSelected ? .primary : .neutral,
                    compact: true
                )

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                }
            }

            Text(kind.localizedSetupEndpointLabel(for: option))
                .font(OriveoTheme.Typography.body.weight(.semibold))
                .foregroundStyle(isSelected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textPrimary)
                .lineLimit(2)

            Text(option.baseURLText)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(OriveoTheme.Spacing.md)
        .oriveoRoundedSurface(
            fill: isSelected
                ? OriveoTheme.Palette.primarySoft.opacity(0.92)
                : OriveoTheme.Palette.surfaceElevated,
            border: isSelected
                ? OriveoTheme.Palette.primary.opacity(0.28)
                : OriveoTheme.Palette.border,
            shadow: .soft
        )
    }
}


private struct GrokConnectionModeSection: View {
    @Binding var mode: ProviderAuthMode

    @ScaledMetric(relativeTo: .footnote) private var optionMinHeight: CGFloat = 74

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            Text(L10n.tr("How do you want to connect Grok?", table: .providers))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            VStack(spacing: OriveoTheme.Spacing.sm) {
                option(
                    mode: .apiKey,
                    icon: "key.fill",
                    title: L10n.tr("API key", table: .providers),
                    subtitle: L10n.tr("Use a key from console.x.ai, billed by usage.", table: .providers)
                )
                option(
                    mode: .subscription,
                    icon: "person.badge.key.fill",
                    title: L10n.tr("Subscription sign-in", table: .providers),
                    subtitle: L10n.tr(
                        "Use your SuperGrok or X Premium quota. No API credits are used.",
                        table: .providers
                    )
                )
            }
        }
    }

    private func option(mode target: ProviderAuthMode, icon: String, title: String, subtitle: String) -> some View {
        let isSelected = mode == target
        return Button {
            mode = target
        } label: {
            HStack(spacing: OriveoTheme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textSecondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Text(subtitle)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
                    .frame(width: 22, height: 22)
            }
            .padding(OriveoTheme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: optionMinHeight, alignment: .leading)
            .oriveoRoundedSurface(
                fill: isSelected
                    ? OriveoTheme.Palette.primarySoft.opacity(0.92)
                    : OriveoTheme.Palette.surfaceElevated,
                border: isSelected
                    ? OriveoTheme.Palette.primary.opacity(0.28)
                    : OriveoTheme.Palette.border,
                shadow: .soft
            )
        }
        .buttonStyle(.plain)
    }
}

private struct GrokSubscriptionConnectSection: View {
    let isSubmitting: Bool
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            Text(L10n.tr(
                "You'll authorize with your x.ai account in the browser, then come back here.",
                table: .providers
            ))
            .font(OriveoTheme.Typography.footnote)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Button(L10n.tr("Sign in with x.ai", table: .providers), action: onConnect)
                .buttonStyle(OriveoPrimaryButtonStyle())
                .disabled(isSubmitting)
                .opacity(isSubmitting ? 0.4 : 1)
        }
        .padding(OriveoTheme.Spacing.lg)
        .oriveoRoundedSurface(
            fill: OriveoTheme.Palette.surfaceElevated,
            border: OriveoTheme.Palette.border,
            shadow: .soft
        )
    }
}

private struct OpenAIConnectionModeSection: View {
    @Binding var mode: ProviderAuthMode

    @ScaledMetric(relativeTo: .footnote) private var optionMinHeight: CGFloat = 74

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            Text(L10n.tr("How do you want to connect ChatGPT?", table: .providers))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            VStack(spacing: OriveoTheme.Spacing.sm) {
                option(
                    mode: .apiKey,
                    icon: "key.fill",
                    title: L10n.tr("API key", table: .providers),
                    subtitle: L10n.tr("Use a key from platform.openai.com, billed by usage.", table: .providers)
                )
                option(
                    mode: .subscription,
                    icon: "person.badge.key.fill",
                    title: L10n.tr("Subscription sign-in", table: .providers),
                    subtitle: L10n.tr(
                        "Use your ChatGPT Plus or Pro plan to run Codex. No API credits are used.",
                        table: .providers
                    )
                )
            }
        }
    }

    private func option(mode target: ProviderAuthMode, icon: String, title: String, subtitle: String) -> some View {
        let isSelected = mode == target
        return Button {
            mode = target
        } label: {
            HStack(spacing: OriveoTheme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textSecondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Text(subtitle)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
                    .frame(width: 22, height: 22)
            }
            .padding(OriveoTheme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: optionMinHeight, alignment: .leading)
            .oriveoRoundedSurface(
                fill: isSelected
                    ? OriveoTheme.Palette.primarySoft.opacity(0.92)
                    : OriveoTheme.Palette.surfaceElevated,
                border: isSelected
                    ? OriveoTheme.Palette.primary.opacity(0.28)
                    : OriveoTheme.Palette.border,
                shadow: .soft
            )
        }
        .buttonStyle(.plain)
    }
}

private struct OpenAISubscriptionConnectSection: View {
    let isSubmitting: Bool
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            Text(L10n.tr(
                "You'll sign in with your ChatGPT account in the browser, then come back here. Your messages are processed by OpenAI Codex.",
                table: .providers
            ))
            .font(OriveoTheme.Typography.footnote)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Button(L10n.tr("Sign in with ChatGPT", table: .providers), action: onConnect)
                .buttonStyle(OriveoPrimaryButtonStyle())
                .disabled(isSubmitting)
                .opacity(isSubmitting ? 0.4 : 1)
        }
        .padding(OriveoTheme.Spacing.lg)
        .oriveoRoundedSurface(
            fill: OriveoTheme.Palette.surfaceElevated,
            border: OriveoTheme.Palette.border,
            shadow: .soft
        )
    }
}
