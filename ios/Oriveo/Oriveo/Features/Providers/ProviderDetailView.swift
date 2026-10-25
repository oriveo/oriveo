import SwiftUI

struct ProviderDetailView: View {
    /// The three layers one detail hosts: detail, model library and model advanced are each an `AppRoute` pushed onto the `NavigationStack`.
    /// The model library reuses the detail page's add-animation coordinate space, undo banner and capability test sheet, so it is still this view, rendered per page.
    enum Page: Hashable {
        case detail
        case modelLibrary
        case modelAdvanced(modelID: String, readOnly: Bool)
    }

    let providerID: UUID
    let page: Page

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
    /// Protocol filter of the model library subpage.
    @State private var catalogFilter: RelayCatalogBoardModel.Filter = .all
    /// The landing point of the fly-in animation. The reference box is read once, at the moment of the tap, and no view state is written while scrolling.
    @State private var enabledModelsFrameBox = ProviderDetailFrameBox()
    /// The model library catalog projection; the driver is attached outside the outer lazy stack (see `ProviderCatalogLibraryProjection`).
    @State private var libraryProjection = ProviderCatalogLibraryProjection()
    @State private var activeAddFeedbacks: [ProviderModelAddFeedbackState] = []
    @State private var highlightedEnabledModelID: String?
    @State private var pendingRemovalBanner: ProviderModelRemovalBannerState?
    @State private var addFeedbackTrigger = 0
    @State private var dismissedHealthBanner = false
    /// A one-time notice carried over after adding or manual setup completes; taken from AppState when the page appears.
    @State private var setupNotice: ProviderDetailNotice.Kind?
    /// Bottom sheet for testing capabilities.
    @State private var capabilityTest = RelayCapabilityTestController()
    /// Relay / local: state of the re-detect button.
    @State private var redetectRunner = RelayRedetectRunner()
    /// "Re-verify" on the recovery card: each tap is a real request, so it cannot be tapped again while running.
    @State private var reverifyRunner = RelayRedetectRunner()

    private let providerDetailCoordinateSpace = "providerDetailCoordinateSpace"

    /// Filter of the model library's first frame: when entered through a key (id) it is that key's filter, otherwise All.
    let initialCatalogFilter: RelayCatalogBoardModel.Filter

    init(providerID: UUID, page: Page = .detail, keyFilter: String? = nil) {
        self.providerID = providerID
        self.page = page
        let initial: RelayCatalogBoardModel.Filter = keyFilter.map { .key($0) } ?? .all
        initialCatalogFilter = initial
        _catalogFilter = State(initialValue: initial)
    }

    /// `startsInModelLibrary` only matters for relay / local connections: it lands directly on the model library page (the mount-cost test uses it to measure model rows).
    init(providerID: UUID, startsInModelLibrary: Bool) {
        self.init(providerID: providerID, page: startsInModelLibrary ? .modelLibrary : .detail)
    }

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

    /// Whether this page shows the model library block: an official provider's detail page, or the model library subpage of a relay / local connection (`RelayDetailBoardModel.make`
    /// produces the board only for the relay form). The projection driver and the render branch share this one criterion, so one is never in the tree while the other is not.
    private var showsLibrarySection: Bool {
        guard usesManagedLibrary, let provider else { return false }
        return ProviderForm.of(provider) == .relay ? page == .modelLibrary : page == .detail
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
            // Clamp to a readable width before subtracting padding: contentWidth is fed down to
            // the model library and the usage chart, so centring only the outer container would
            // still leave those children laying themselves out against the full width.
            let contentWidth = max(
                min(proxy.size.width, OriveoTheme.Layout.contentMaxWidth) - OriveoTheme.Spacing.xl * 2,
                0
            )
            Group {
                if let provider {
                    let board = RelayDetailBoardModel.make(
                        provider,
                        lastUsedModelRef: appState.lastUsedModelRef,
                        avatarChoice: RelayAvatarChoiceStore.shared.choice(for: provider.id)
                    )
                    ZStack(alignment: .topLeading) {
                        ScrollView {
                            // The outer stack must be lazy: the enabled models and the model library were each a LazyVStack, and
                            // inside a non-lazy VStack the outer stack asks both for their full height on every layout. Adding models deep in the library
                            // inserts rows above the viewport, so every tap re-measured all rows above it, and the cost grew with the enabled count and scroll
                            // depth (150 enabled models: 470ms for the longest block over 14 rapid taps on a simulator, past the 2s watchdog on an
                            // iPhone 13); with a lazy outer stack it is 117ms.
                            // And there can be only this one lazy layer: the enabled section / model library / model library subpage all produce their rows as siblings here and no longer
                            // bring their own LazyVStack - on iOS 26 lazy allocation of nested lazy stacks has a race, and closing the keyboard after a search expanded everything could freeze the app permanently.
                            // spacing is 0: rows must sit flush, and the Spacing.lg between blocks is given explicitly by each block as top padding.
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if board != nil, case let .modelAdvanced(modelID, readOnly) = page {
                                    // Read-only advanced (entered from a catalog row) looks up the catalog entry; the read-only form of its content belongs to the model library card.
                                    if let model = provider.models.first(where: { $0.id == modelID })
                                        ?? (readOnly ? provider.catalogModels.first(where: { $0.id == modelID }) : nil) {
                                        RelayModelAdvancedPage(
                                            provider: provider,
                                            model: model,
                                            partitionID: appState.sessionPartitionUID,
                                            onBack: { appState.pop() },
                                            onTestCapabilities: {
                                                capabilityTest.start(appState: appState, providerID: provider.id, modelID: model.id)
                                            },
                                            readOnly: readOnly
                                        )
                                    } else {
                                        // The model has been removed: keep only the back button.
                                        topBar()
                                    }
                                } else if board != nil, page == .modelLibrary {
                                    RelayModelLibraryPage(
                                        provider: provider,
                                        isRefreshing: appState.relayCatalogRefreshingProviderIDs.contains(provider.id),
                                        onBack: { appState.pop() },
                                        onRefresh: { Task { await refreshRelayCatalog(providerID: provider.id) } }
                                    ) {
                                        modelsContent(for: provider, viewportSize: proxy.size)
                                    }
                                } else {
                                    topBar()

                                    if let setupNotice {
                                        ProviderDetailSetupNoticeBanner(kind: setupNotice)
                                            .padding(.top, OriveoTheme.Spacing.lg)
                                    }

                                    if let disabled = subscriptionDisabledNotice(for: provider) {
                                        SubscriptionDisabledNotice(
                                            notice: disabled.notice,
                                            fallback: disabled.fallback
                                        )
                                        .padding(.top, OriveoTheme.Spacing.lg)
                                    }

                                    if !dismissedHealthBanner, let recovery = RelayDetailBoardModel.recoveryCard(
                                        for: provider,
                                        isReverifying: reverifyRunner.isRunning,
                                        omitsDetail: Self.noticeCoversRecoveryDetail(setupNotice)
                                    ) {
                                        // Relay / local: a failed connection is mostly a wrong address, so offer editing the connection; changing the key goes to the keys page.
                                        RelayDetailRecoveryCard(
                                            card: recovery,
                                            handlers: .init(
                                                editConnection: { showEditRelay = true },
                                                apiKeys: { appState.openRelayKeys(providerID: provider.id) },
                                                reverify: {
                                                    reverifyRunner.tap {
                                                        await runResync(providerID: provider.id)
                                                        return true
                                                    }
                                                }
                                            ),
                                            onDismiss: {
                                                withAnimation(.easeOut(duration: 0.2)) {
                                                    dismissedHealthBanner = true
                                                }
                                            }
                                        )
                                            .padding(.top, OriveoTheme.Spacing.lg)
                                            .transition(.opacity.combined(with: .move(edge: .top)))
                                    } else if isProviderUnhealthy(provider), !dismissedHealthBanner {
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
                                            .padding(.top, OriveoTheme.Spacing.lg)
                                            .transition(.opacity.combined(with: .move(edge: .top)))
                                    }

                                    if let board {
                                        RelayDetailBoardView(
                                            provider: provider,
                                            board: board,
                                            isDetecting: redetectRunner.isRunning,
                                            onRename: { showRenameProvider = true },
                                            onEditConnection: { showEditRelay = true },
                                            onOpenKeys: { appState.openRelayKeys(providerID: provider.id) },
                                            onRemoveResidualAPIKey: {
                                                appState.providerManager.removeStoredRelayCredential(providerID: provider.id)
                                            },
                                            onOpenModelLibrary: { appState.openRelayModelLibrary(providerID: provider.id) },
                                            onOpenWebSearch: { appState.openRelayWebSearch(providerID: provider.id) },
                                            onOpenParameters: { showGenerationParameters = true },
                                            onDetectAgain: { detectAgain(providerID: provider.id) },
                                            onDelete: { showDeleteAlert = true }
                                        )
                                        .padding(.top, OriveoTheme.Spacing.lg)
                                    } else {
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
                                            }
                                        )
                                        .padding(.top, OriveoTheme.Spacing.lg)

                                        if ProviderBalanceCard.isBalanceCapable(provider.kind) {
                                            ProviderBalanceCard(provider: provider)
                                                .padding(.top, OriveoTheme.Spacing.lg)
                                        }

                                        modelsContent(for: provider, viewportSize: proxy.size)
                                    }

                                    if ProviderSettingsRow.usesSettingsSection(for: provider) {
                                        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                                            ProviderSectionHeader(title: L10n.tr("Settings"))

                                            ProviderSettingsSection(
                                                provider: provider,
                                                showEditEndpoint: $showEditEndpoint,
                                                showConnectionSettings: $showConnectionSettings,
                                                showDeleteAlert: $showDeleteAlert,
                                                showGenerationParameters: $showGenerationParameters
                                            )
                                        }
                                        .padding(.top, OriveoTheme.Spacing.lg)
                                    }
                                }
                            }
                            // The flattened group cards / added panel get their look drawn once per whole-card bounds on this lazy container.
                            .providerPanelGroupSurfaces()
                            .background { libraryProjectionDriver(for: provider) }
                            .frame(width: contentWidth, alignment: .leading)
                            .padding(.horizontal, OriveoTheme.Spacing.xl)
                            .padding(.top, OriveoTheme.Spacing.lg)
                            .padding(.bottom, OriveoTheme.Spacing.xxl)
                            .frame(maxWidth: .infinity)
                        }
                        .coordinateSpace(name: providerDetailCoordinateSpace)
                        // The model library search field is a child of the outer lazy stack and is recycled and loses focus when it scrolls out of the buffer; like search in iOS Settings, scrolling dismisses the keyboard.
                        .scrollDismissesKeyboard(.immediately)

                        addFeedbackOverlay
                    }
                    .oriveoScreenBackground()
                    .sheet(isPresented: $showConnectionSettings) {
                        ConnectionSettingsSheet(
                            selectedKind: provider.kind,
                            setupCatalog: setupCatalog,
                            selectedEndpointOption: setupCatalog.sourcedEndpointOption(
                                for: provider.kind,
                                endpointSource: provider.endpointSource
                            ) ?? setupCatalog.resolvedSetupEndpointOption(
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
                    .sheet(isPresented: capabilityTestPresented) {
                        RelayCapabilityTestSheet(controller: capabilityTest)
                    }
                    .onChange(of: provider.effectiveStatusKind) { _, newKind in
                        if newKind == .connected || newKind == .syncing {
                            dismissedHealthBanner = false
                        }
                    }
                    .onAppear {
                        #if DEBUG
                        // For screenshots only: the page's private state cannot be set up from outside.
                        if let groups = RelayFamilyDebugShots.takeExpandedLibraryGroups(on: page) { expandedLibraryGroups = groups }
                        if RelayFamilyDebugShots.takePresentsEditConnection(on: page) { showEditRelay = true }
                        if let seed = RelayFamilyDebugShots.takeCapabilityTest(on: page) {
                            capabilityTest = RelayCapabilityTestController(
                                debugInput: seed.input, modelName: seed.modelName, runningSince: seed.runningSince
                            )
                        }
                        #endif
                        guard page == .detail else { return }
                        if setupNotice == nil, let notice = appState.consumeProviderDetailNotice(for: provider.id) {
                            setupNotice = notice
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
        // The model library of relay / local connections uses the board; official providers do not pass it and look the same as before.
        let catalogFilters = ProviderForm.of(provider) == .relay
            ? RelayCatalogBoardModel.filters(
                provider: provider, models: provider.models + provider.catalogModels, current: catalogFilter
            )
            : []
        let catalogBoard: RelayCatalogBoardContext? = ProviderForm.of(provider) == .relay
            ? RelayCatalogBoardContext(
                partitionID: appState.sessionPartitionUID,
                filter: RelayCatalogBoardModel.effectiveFilter(catalogFilter, available: catalogFilters),
                probeStates: appState.relayModelProbeStates[provider.id] ?? [:]
            )
            : nil

        if let catalogBoard, !catalogFilters.isEmpty {
            RelayCatalogFilterChips(
                filters: catalogFilters,
                selected: catalogBoard.filter,
                keyTitle: { RelayCatalogBoardModel.keyFilterTitle(provider: provider, keyID: $0) ?? $0 }
            ) { filter in
                catalogFilter = filter
            }
            .padding(.top, OriveoTheme.Spacing.lg)
        }

        // Produced as a sibling: it brings its own spacing from above (see its body).
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
            },
            onOpenAdvanced: { model in
                appState.openRelayModelAdvanced(providerID: provider.id, modelID: model.id, readOnly: false)
            },
            catalogBoard: catalogBoard
        )
        // No `.equatable()` wrapper: EquatableView is a single view and would gather the sibling rows into one non-lazy stack, building the whole section at once
        // (150 rows on first screen with 150 added). An unchanged write-back is skipped by each row's own `.equatable()`.

        if showsLibrarySection {
            ProviderModelLibrarySection(
                provider: provider,
                providersVersion: appState.providersVersion,
                projection: libraryProjection,
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
                isCatalogRefreshing: appState.relayCatalogRefreshingProviderIDs.contains(provider.id),
                catalogBoard: catalogBoard,
                onRetryCatalogKey: { keyID in
                    Task { _ = await appState.providerManager.refreshRelayCatalog(providerID: provider.id, onlyKeyID: keyID) }
                },
                onOpenCatalogModel: { model in
                    // Tapping a catalog row opens read-only advanced with no request; enabling goes only through the trailing plus.
                    appState.openRelayModelAdvanced(providerID: provider.id, modelID: model.id, readOnly: true)
                }
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
        .padding(.top, OriveoTheme.Spacing.lg)

        if catalogBoard != nil {
            RelayCatalogLegend()
                .padding(.top, OriveoTheme.Spacing.lg)
        }
    }

    /// The driver of the model library catalog projection: in the tree only while this page shows the model library block (an official provider's detail page / a relay model library subpage).
    @ViewBuilder
    private func libraryProjectionDriver(for provider: Provider) -> some View {
        if showsLibrarySection {
            ProviderCatalogLibraryProjectionDriver(
                provider: provider,
                providersVersion: appState.providersVersion,
                searchText: modelSearchText,
                projection: libraryProjection,
                expandedLibraryGroups: $expandedLibraryGroups
            )
        }
    }

    // MARK: - Top Bar

    private func topBar() -> some View {
        HStack {
            OriveoBackButton {
                appState.pop()
            }
            .padding(.leading, -OriveoBackButton.edgeInset)

            Spacer()
        }
    }

    /// The title of the "saved without verification" notice is the same reason the recovery card would give, plus the original failure text; while it is shown the recovery card does not repeat it.
    static func noticeCoversRecoveryDetail(_ notice: ProviderDetailNotice.Kind?) -> Bool {
        if case .unverifiedSave = notice { return true }
        return false
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

    /// Re-detect: calls the domain function, and the button cannot be tapped again while it runs; a failure reuses the existing catalog failure message.
    private func detectAgain(providerID: UUID) {
        let manager = appState.providerManager
        redetectRunner.tap {
            let succeeded = await manager.redetectRelayModels(providerID: providerID)
            if !succeeded, let message = manager.provider(for: providerID)?.lastError?
                .trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                ToastManager.shared.show(ProviderIssueMessage.localized(message), style: .warning)
            }
            return succeeded
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
        #if DEBUG
        ProviderDetailFrameBox.debugLastAddTarget = .init(
            enabledModelsFrame: enabledModelsFrame,
            usesEnabledTarget: isTargetVisible,
            activeFragments: enabledModelsFrameBox.debugActiveFragments
        )
        #endif
        let feedback = ProviderModelAddFeedbackState(
            model: model,
            position: startPoint,
            scale: 0.96,
            opacity: reduceMotion ? 0.9 : 1
        )

        activeAddFeedbacks.append(feedback)
        addFeedbackTrigger += 1

        var enableResult: ProviderManager.EnableModelResult = .notFound
        withAnimation(.snappy) {
            enableResult = appState.enableModel(modelID: model.id, for: provider.id, lazilyVerifiesRelayTransport: true)
            highlightedEnabledModelID = model.id
        }

        // Same copy and style as the Home picker, so neither surface adds a model silently.
        ModelEnableFeedback.announce(enableResult)

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

    private var capabilityTestPresented: Binding<Bool> {
        Binding(
            get: { capabilityTest.isPresented },
            set: { if !$0 { capabilityTest.dismiss() } }
        )
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
        // Same top capsule toast as "Added"; pendingRemovalBanner only keeps the state Undo needs.
        pendingRemovalBanner = removal
        ToastManager.shared.show(
            String(format: L10n.tr("Removed %@", table: .providers), removal.model.name),
            style: .removed,
            duration: 4,
            actionTitle: L10n.tr("Undo", table: .providers),
            action: { undoPendingRemoval() }
        )
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

/// The connection-issue card for official providers. Under the same criterion (`isWarning`), relay / local connections use `RelayDetailBoardModel.recoveryCard` and never reach here.
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
        Button(action: onUpdateAPIKey) {
            Label(L10n.tr("Edit API Key", table: .providers), systemImage: "key.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ProviderRecoveryPrimaryButtonStyle())

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

extension ProviderDetailNotice.Kind {
    /// Title of the "saved without verification" notice: the same sentence as this connection's status row, no longer worded as "could not get the model catalog".
    static let unverifiedSaveTitleKey = ProviderIssueMessage.unverifiedConnectionKey
}

/// The one-time notice at the top of the detail page: how many models were enabled after adding, or why a manual setup was saved even though its probe failed.
private struct ProviderDetailSetupNoticeBanner: View {
    let kind: ProviderDetailNotice.Kind

    var body: some View {
        HStack(alignment: .top, spacing: OriveoTheme.Spacing.sm) {
            Image(systemName: isWarning ? "info.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isWarning ? OriveoTheme.Palette.warning : OriveoTheme.Palette.success)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                switch kind {
                case .addedModels(let count):
                    Text(L10n.format(
                        L10n.tr("Added %lld models. You can add more in the model library.", table: .providers),
                        count
                    ))
                    .font(OriveoTheme.Typography.footnote)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                case .unverifiedSave(let reason):
                    Text(ProviderIssueMessage.localized(ProviderDetailNotice.Kind.unverifiedSaveTitleKey))
                        .font(OriveoTheme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Text(reason)
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(OriveoTheme.Spacing.md)
        .oriveoRoundedSurface(
            fill: isWarning ? OriveoTheme.Palette.warningSoft : OriveoTheme.Palette.successSoft,
            border: (isWarning ? OriveoTheme.Palette.warning : OriveoTheme.Palette.success).opacity(0.3),
            radius: OriveoTheme.Radius.md,
            shadow: .none
        )
        .accessibilityElement(children: .combine)
    }

    private var isWarning: Bool {
        if case .unverifiedSave = kind { return true }
        return false
    }
}
