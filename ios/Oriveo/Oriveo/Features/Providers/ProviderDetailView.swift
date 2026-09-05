import SwiftUI

struct ProviderDetailView: View {
    let providerID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showConnectionSettings = false
    @State private var showDeleteAlert = false
    @State private var showEditAPIKey = false
    @State private var showGrokReauthorization = false
    @State private var showOpenAIReauthorization = false
    @State private var showRenameProvider = false
    @State private var showEditEndpoint = false
    @State private var showEditRelay = false
    @State private var showGenerationParameters = false
    @State private var modelSearchText = ""
    @State private var expandedLibraryGroups = Set<String>()
    @State private var enabledModelsFrameBox = ProviderDetailFrameBox()
    @State private var activeAddFeedbacks: [ProviderModelAddFeedbackState] = []
    @State private var highlightedEnabledModelID: String?
    @State private var pendingRemovalBanner: ProviderModelRemovalBannerState?
    @State private var addFeedbackTrigger = 0
    @State private var dismissedHealthBanner = false

    private let providerDetailCoordinateSpace = "providerDetailCoordinateSpace"

    private var provider: Provider? {
        appState.provider(for: providerID)
    }

    private var setupCatalog: ProviderSetupCatalog {
        ProviderSetupCatalog.current()
    }

    private var usesManagedLibrary: Bool {
        guard let provider else { return false }
        if provider.kind.isAggregatedProvider { return true }
        return provider.kind == .relay
            && (!provider.catalogModels.isEmpty || appState.relayCatalogRefreshingProviderIDs.contains(provider.id)
                || provider.lastError == ProviderIssueMessage.catalogUnavailableKey)
    }

    private func subscriptionDisabledNotice(
        for provider: Provider
    ) -> SubscriptionDisabledPresentation? {
        SubscriptionDisabledPresentation.resolve(
            provider: provider,
            openAI: MetadataClient.shared.syncOpenAISubscriptionAvailability(),
            grok: MetadataClient.shared.syncGrokSubscriptionAvailability()
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(proxy.size.width - OriveoTheme.Spacing.xl * 2, 0)
            Group {
                if let provider {
                    ZStack(alignment: .topLeading) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                                topBar()

                                if let disabled = subscriptionDisabledNotice(for: provider) {
                                    SubscriptionDisabledNotice(
                                        notice: disabled.notice,
                                        fallback: disabled.fallback
                                    )
                                }

                                if isProviderUnhealthy(provider), !dismissedHealthBanner {
                                    ProviderConnectionIssueRecoveryCard(
                                        provider: provider,
                                        onUpdateAPIKey: {
                                            if provider.authMode == .subscription {
                                                if provider.kind == .openAI {
                                                    showOpenAIReauthorization = true
                                                } else {
                                                    showGrokReauthorization = true
                                                }
                                            } else {
                                                showEditAPIKey = true
                                            }
                                        },
                                        onRetryConnection: {
                                            Task { await runResync(providerID: provider.id) }
                                        },
                                        onCheckEndpoint: setupCatalog.setupEndpointOptions(for: provider.kind).isEmpty ? nil : {
                                            showEditEndpoint = true
                                        },
                                        onDismiss: {
                                            withAnimation(.easeOut(duration: 0.2)) {
                                                dismissedHealthBanner = true
                                            }
                                        }
                                    )
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }

                                ProviderDetailBrandHeroCard(
                                    provider: provider,
                                    onStartChat: {
                                        appState.startNewChat(preferredProviderID: provider.id)
                                    },
                                    onResync: {
                                        Task { await runResync(providerID: provider.id) }
                                    },
                                    onEditAPIKey: {
                                        if provider.authMode == .subscription {
                                            if provider.kind == .openAI {
                                                showOpenAIReauthorization = true
                                            } else {
                                                showGrokReauthorization = true
                                            }
                                        } else {
                                            showEditAPIKey = true
                                        }
                                    },
                                    onEditName: {
                                        showRenameProvider = true
                                    },
                                    onRemoveResidualAPIKey: {
                                        appState.providerManager.removeStoredRelayCredential(providerID: provider.id)
                                    }
                                )

                                if ProviderBalanceCard.isBalanceCapable(provider.kind) {
                                    ProviderBalanceCard(provider: provider)
                                }

                                modelsContent(for: provider, viewportSize: proxy.size)

                                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                                    ProviderSectionHeader(title: L10n.tr("Settings"))

                                    ProviderSettingsSection(
                                        provider: provider,
                                        showEditEndpoint: $showEditEndpoint,
                                        showConnectionSettings: $showConnectionSettings,
                                        showDeleteAlert: $showDeleteAlert,
                                        showEditRelay: $showEditRelay,
                                        showGenerationParameters: $showGenerationParameters,
                                    )
                                }

                            }
                            .frame(width: contentWidth, alignment: .leading)
                            .padding(.horizontal, OriveoTheme.Spacing.xl)
                            .padding(.top, OriveoTheme.Spacing.lg)
                            .padding(.bottom, OriveoTheme.Spacing.xxl)
                        }
                        .coordinateSpace(name: providerDetailCoordinateSpace)

                        addFeedbackOverlay
                        removalBannerOverlay
                    }
                    .oriveoScreenBackground()
                    .sheet(isPresented: $showConnectionSettings) {
                        ConnectionSettingsSheet(
                            selectedKind: provider.kind,
                            setupCatalog: setupCatalog,
                            selectedEndpointOption: setupCatalog.resolvedSetupEndpointOption(
                                for: provider.kind,
                                baseURLText: provider.baseURLText
                            ),
                            selectedBaseURLText: provider.baseURLText
                        )
                            .presentationDetents([.medium])
                            .presentationDragIndicator(.visible)
                    }
                    .sheet(isPresented: $showEditAPIKey) {
                        EditAPIKeySheet(providerID: providerID)
                            .presentationDetents([.medium])
                            .presentationDragIndicator(.visible)
                    }
                    .sheet(isPresented: $showGrokReauthorization) {
                        if case let .available(config) = MetadataClient.shared.syncGrokSubscriptionAvailability() {
                            GrokSubscriptionAuthorizationSheet(config: config) { tokens in
                                Task {
                                    GrokSubscriptionRuntime.persist(tokens: tokens, providerID: providerID)
                                    try? await appState.updateAPIKey(
                                        providerID: providerID,
                                        newKey: tokens.accessToken
                                    )
                                }
                            }
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                        }
                    }
                    .sheet(isPresented: $showOpenAIReauthorization) {
                        if case let .available(config) = MetadataClient.shared.syncOpenAISubscriptionAvailability() {
                            OpenAISubscriptionAuthorizationSheet(config: config) { tokens in
                                Task {
                                    OpenAISubscriptionRuntime.persist(tokens: tokens, providerID: providerID)
                                    try? await appState.updateAPIKey(
                                        providerID: providerID,
                                        newKey: tokens.accessToken
                                    )
                                }
                            }
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                        }
                    }
                    .sheet(isPresented: $showRenameProvider) {
                        RenameProviderSheet(providerID: providerID)
                            .presentationDetents([.height(220)])
                            .presentationDragIndicator(.visible)
                    }
                    .sheet(isPresented: $showEditEndpoint) {
                        EditProviderEndpointSheet(providerID: providerID)
                            .presentationDetents([.large])
                            .presentationDragIndicator(.visible)
                    }
                    .sheet(isPresented: $showEditRelay) {
                        RelayEditView(providerID: providerID)
                            .presentationDetents([.large])
                    }
                    .sheet(isPresented: $showGenerationParameters) {
                        GenerationParameterDefaultsSheet(provider: provider)
                            .presentationDetents([.large])
                            .presentationDragIndicator(.visible)
                    }
                    .sensoryFeedback(.success, trigger: addFeedbackTrigger)
                    .alert(String(format: L10n.tr("Delete “%@”?", table: .providers), provider.displayName), isPresented: $showDeleteAlert) {
                        Button(L10n.tr("Delete"), role: .destructive) {
                            if !appState.deleteProvider(providerID: provider.id) {
                                ToastManager.shared.show(L10n.tr("Couldn't delete provider. Please try again.", table: .providers))
                            }
                        }
                        Button(L10n.tr("Cancel"), role: .cancel) {}
                    } message: {
                        Text(L10n.tr("This deletes the connection, API key, enabled models, model library, and model behavior settings. It does not delete conversations; message history stays, and models used there are marked unavailable. This cannot be undone.", table: .providers))
                    }
                    .onChange(of: provider.effectiveStatusKind) { _, newKind in
                        if newKind == .connected || newKind == .syncing {
                            dismissedHealthBanner = false
                        }
                    }
                } else {
                    ProgressView()
                        .tint(OriveoTheme.Palette.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .oriveoScreenBackground()
                }
            }
        }
    }

    @ViewBuilder
    private func modelsContent(for provider: Provider, viewportSize: CGSize) -> some View {
        ProviderEnabledModelsSection(
            provider: provider,
            highlightedModelID: highlightedEnabledModelID,
            coordinateSpaceName: providerDetailCoordinateSpace,
            enabledModelsFrameBox: enabledModelsFrameBox,
            onSetDefault: { model in
                appState.setDefaultModel(modelID: model.id, for: provider.id)
            },
            onChat: { model in
                appState.startNewChat(preferredProviderID: provider.id, preferredModelID: model.id)
            },
            onRemove: { model in
                handleEnabledModelRemove(model, for: provider)
            }
        )

        if usesManagedLibrary {
            ProviderModelLibrarySection(
                provider: provider,
                providersVersion: appState.providersVersion,
                modelSearchText: $modelSearchText,
                expandedLibraryGroups: $expandedLibraryGroups,
                coordinateSpaceName: providerDetailCoordinateSpace,
                viewportSize: viewportSize,
                onAddCatalogModel: { model, rowFrame in
                    handleCatalogModelAdd(
                        model,
                        for: provider,
                        viewportSize: viewportSize,
                        rowFrame: rowFrame
                    )
                },
                onRetryCatalog: {
                    Task {
                        if provider.authMode == .subscription {
                            await runResync(providerID: provider.id)
                        } else {
                            await refreshRelayCatalog(providerID: provider.id)
                        }
                    }
                },
                onAddManualModel: {
                    appState.openManualModelEntry(providerID: provider.id, context: .providerDetail)
                },
                isCatalogRefreshing: appState.relayCatalogRefreshingProviderIDs.contains(provider.id)
            )
        }

        Button {
            appState.openManualModelEntry(providerID: provider.id, context: .providerDetail)
        } label: {
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                .foregroundStyle(OriveoTheme.Palette.borderStrong)
                .frame(height: 52)
                .overlay(
                    Text(L10n.tr("+ Add model ID manually", table: .providers))
                        .font(OriveoTheme.Typography.body)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Top Bar

    private func topBar() -> some View {
        HStack {
            Button {
                appState.pop()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Back"))

            Spacer()
        }
    }

    private func isProviderUnhealthy(_ provider: Provider) -> Bool {
        provider.effectiveStatusKind.isWarning
    }

    private func runResync(providerID: UUID) async {
        let targetProvider = appState.provider(for: providerID)
        let isManagedProvider = false
        do {
            if targetProvider?.kind == .relay {
                try await appState.providerManager.reverifyRelayProvider(providerID: providerID)
            } else {
                try await appState.resyncProvider(providerID: providerID)
            }
            if isManagedProvider {
                ToastManager.shared.show(L10n.tr("Model catalog refreshed.", table: .providers), style: .success)
                return
            }
            if let softError = appState.provider(for: providerID)?.lastError?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !softError.isEmpty {
                ToastManager.shared.show(ProviderIssueMessage.localized(softError), style: .warning)
            } else {
                ToastManager.shared.show(L10n.tr("Connection verified.", table: .providers), style: .success)
            }
        } catch is CancellationError {
            return
        } catch {
            if isManagedProvider {
                ToastManager.shared.show(
                    L10n.tr("Could not refresh model catalog. Current models are still available.", table: .providers),
                    style: .error
                )
                return
            }
            let detail = makeProviderError(error).message
            ToastManager.shared.show(
                String(format: L10n.tr("Connection check failed: %@", table: .providers), detail),
                style: .error
            )
        }
    }

    private func refreshRelayCatalog(providerID: UUID) async {
        let refreshed = await appState.providerManager.refreshRelayCatalog(providerID: providerID)
        if refreshed {
            ToastManager.shared.show(L10n.tr("Model catalog refreshed.", table: .providers), style: .success)
        }
    }

    // MARK: - Animation Orchestration

    private func handleCatalogModelAdd(
        _ model: AIModel,
        for provider: Provider,
        viewportSize: CGSize,
        rowFrame: CGRect
    ) {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        let startPoint = ProviderDetailFeedbackGeometry.sourcePoint(
            rowFrame: rowFrame,
            viewport: viewport
        )
        let enabledModelsFrame = enabledModelsFrameBox.frame
        let isTargetVisible = ProviderDetailFeedbackGeometry.isEnabledModelsFrameVisible(
            enabledModelsFrame,
            viewport: viewport
        )
        let destinationPoint = ProviderDetailFeedbackGeometry.destinationPoint(
            enabledModelsFrame: enabledModelsFrame,
            viewport: viewport
        )
        let endPoint = isTargetVisible
            ? destinationPoint
            : CGPoint(x: startPoint.x, y: max(startPoint.y - 60, 40))
        let feedback = ProviderModelAddFeedbackState(
            model: model,
            position: startPoint,
            scale: 0.96,
            opacity: reduceMotion ? 0.9 : 1
        )

        activeAddFeedbacks.append(feedback)
        addFeedbackTrigger += 1

        withAnimation(.snappy) {
            appState.enableModel(modelID: model.id, for: provider.id)
            highlightedEnabledModelID = model.id
        }

        ToastManager.shared.show(
            String(format: L10n.tr("Added %@", table: .providers), model.name),
            style: .success
        )

        DispatchQueue.main.async {
            withAnimation(reduceMotion ? .easeOut(duration: 0.24) : .spring(response: 0.42, dampingFraction: 0.82)) {
                updateAddFeedback(id: feedback.id) { item in
                    if !reduceMotion {
                        item.position = endPoint
                    }
                    item.scale = isTargetVisible ? 0.6 : 0.9
                    item.opacity = 0
                }
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 560_000_000)
            removeAddFeedback(id: feedback.id)
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            clearHighlightIfNeeded(for: model.id)
        }
    }

    private func handleEnabledModelRemove(_ model: AIModel, for provider: Provider) {
        let removal = ProviderModelRemovalBannerState(
            providerID: provider.id,
            model: model,
            shouldRestoreDefault: model.isDefault
        )

        withAnimation(.snappy) {
            appState.disableModel(modelID: model.id, for: provider.id)
            if highlightedEnabledModelID == model.id {
                highlightedEnabledModelID = nil
            }
        }

        presentRemovalBanner(removal)
    }

    private func presentRemovalBanner(_ removal: ProviderModelRemovalBannerState) {
        withAnimation(.snappy) {
            pendingRemovalBanner = removal
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if pendingRemovalBanner?.id == removal.id {
                withAnimation(.easeOut(duration: 0.22)) {
                    pendingRemovalBanner = nil
                }
            }
        }
    }

    private func undoPendingRemoval() {
        guard let pendingRemovalBanner else { return }

        withAnimation(.snappy) {
            appState.enableModel(modelID: pendingRemovalBanner.model.id, for: pendingRemovalBanner.providerID)
            if pendingRemovalBanner.shouldRestoreDefault {
                appState.setDefaultModel(modelID: pendingRemovalBanner.model.id, for: pendingRemovalBanner.providerID)
            }
            highlightedEnabledModelID = pendingRemovalBanner.model.id
            self.pendingRemovalBanner = nil
        }

        addFeedbackTrigger += 1

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            clearHighlightIfNeeded(for: pendingRemovalBanner.model.id)
        }
    }

    private func clearHighlightIfNeeded(for modelID: String) {
        if highlightedEnabledModelID == modelID {
            withAnimation(.easeOut(duration: 0.22)) {
                highlightedEnabledModelID = nil
            }
        }
    }

    @ViewBuilder
    private var addFeedbackOverlay: some View {
        ForEach(activeAddFeedbacks) { feedback in
            ProviderModelAddFeedbackChip(model: feedback.model)
                .scaleEffect(feedback.scale)
                .opacity(feedback.opacity)
                .position(feedback.position)
                .allowsHitTesting(false)
                .zIndex(10)
        }
    }

    @ViewBuilder
    private var removalBannerOverlay: some View {
        VStack {
            Spacer()

            if let pendingRemovalBanner {
                ProviderModelRemovalBanner(
                    model: pendingRemovalBanner.model,
                    undoAction: undoPendingRemoval
                )
                .padding(.horizontal, OriveoTheme.Spacing.xl)
                .padding(.bottom, OriveoTheme.Spacing.lg)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(pendingRemovalBanner != nil)
    }

    private func updateAddFeedback(id: UUID, update: (inout ProviderModelAddFeedbackState) -> Void) {
        guard let index = activeAddFeedbacks.firstIndex(where: { $0.id == id }) else { return }
        update(&activeAddFeedbacks[index])
    }

    private func removeAddFeedback(id: UUID) {
        activeAddFeedbacks.removeAll { $0.id == id }
    }
}

struct SubscriptionDisabledPresentation: Equatable {
    let notice: String?
    let fallback: String

    static func resolve(
        provider: Provider,
        openAI: OpenAISubscriptionAvailability,
        grok: GrokSubscriptionAvailability
    ) -> Self? {
        guard provider.authMode == .subscription else { return nil }
        switch provider.kind {
        case .openAI:
            guard case let .disabled(notice) = openAI else { return nil }
            return .init(
                notice: notice,
                fallback: OpenAISubscriptionError.clientVersionRejected.userFacingMessage
            )
        case .grok:
            guard case let .disabled(notice) = grok else { return nil }
            return .init(
                notice: notice,
                fallback: GrokSubscriptionError.clientVersionRejected.userFacingMessage
            )
        default:
            return nil
        }
    }
}

private struct SubscriptionDisabledNotice: View {
    let notice: String?
    let fallback: String

    private var text: String {
        let trimmed = notice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    var body: some View {
        HStack(alignment: .top, spacing: OriveoTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.warning)

            Text(text)
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(OriveoTheme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                .fill(OriveoTheme.Palette.warningSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                .stroke(OriveoTheme.Palette.warning.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct ProviderConnectionIssueRecoveryCard: View {
    let provider: Provider
    let onUpdateAPIKey: () -> Void
    let onRetryConnection: () -> Void
    var onCheckEndpoint: (() -> Void)?
    let onDismiss: () -> Void

    private var needsKeyOnThisDevice: Bool {
        provider.effectiveStatusKind == .needsKey
    }

    private var headlineText: String {
        needsKeyOnThisDevice
            ? L10n.tr("API key not saved on this device. Tap to add it.", table: .providers)
            : L10n.tr("Connection issue — please check your API key.", table: .providers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            HStack(alignment: .center, spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: needsKeyOnThisDevice ? "key.slash.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.warning)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(OriveoTheme.Palette.surfaceElevated.opacity(0.82)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(headlineText)
                        .font(OriveoTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !needsKeyOnThisDevice,
                       let lastError = provider.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !lastError.isEmpty {
                        Text(ProviderIssueMessage.localized(lastError))
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Dismiss"))
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    recoveryButtons
                }

                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                    recoveryButtons
                }
            }
        }
        .padding(OriveoTheme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                .fill(OriveoTheme.Palette.warningSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                .stroke(OriveoTheme.Palette.warning.opacity(0.20), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var recoveryButtons: some View {
        if provider.kind != .relay || RelayCredentialPolicy.editAction(
            authMode: provider.relayRequested?.authMode,
            hasStoredKey: RelayCredentialPolicy.hasStoredKey(provider.apiKey)
        ) == .rotate {
            Button(action: onUpdateAPIKey) {
                Label(L10n.tr("Edit API Key", table: .providers), systemImage: "key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ProviderRecoveryPrimaryButtonStyle())
        }

        if let onCheckEndpoint {
            Button(action: onCheckEndpoint) {
                Label(provider.kind.setupEndpointTitle, systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ProviderRecoverySecondaryButtonStyle())
        }

        Button(action: onRetryConnection) {
            Label(L10n.tr("Retry"), systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ProviderRecoverySecondaryButtonStyle())
    }
}

private struct ProviderRecoveryPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OriveoTheme.Typography.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .frame(height: 38)
            .background(Capsule(style: .continuous).fill(OriveoTheme.Palette.warning))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct ProviderRecoverySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OriveoTheme.Typography.caption.weight(.semibold))
            .foregroundStyle(OriveoTheme.Palette.warning)
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .frame(height: 38)
            .background(
                Capsule(style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceElevated.opacity(0.82))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(OriveoTheme.Palette.warning.opacity(0.18), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct RenameProviderSheet: View {
    let providerID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var provider: Provider? {
        appState.provider(for: providerID)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                OriveoLabeledField(
                    title: L10n.tr("Name", table: .providers),
                    text: $name,
                    placeholder: provider?.displayName ?? L10n.tr("Name", table: .providers),
                    isSecure: false
                )
                Spacer(minLength: 0)
            }
            .padding(OriveoTheme.Spacing.xl)
            .navigationTitle(L10n.tr("Rename"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Save")) {
                        appState.updateProviderName(providerID: providerID, newName: name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = provider?.displayName ?? ""
            }
        }
    }
}

#Preview {
    ProviderDetailView(providerID: AppState.preview.providers.first!.id)
        .environment(AppState.preview)
}
