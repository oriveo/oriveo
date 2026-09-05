import SwiftUI

struct RelayEditView: View {
    let providerID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var editor: Editor?
    @State private var original: Editor?
    @State private var isSaving = false
    @State private var showDeleteAlert = false
    @State private var showEditAPIKey = false
    @State private var showSecurityModePicker = false
    @State private var showDiscardAlert = false
    @State private var showRenameSheet = false
    @State private var saveError: OriveoError?
    @State private var pendingUnverifiedSave: PendingUnverifiedRelaySave?
    @State private var showsUnverifiedSaveConfirmation = false
    @State private var saveGeneration = 0
    @State private var showRelayKindPicker = false
    @State private var pendingRelayKind: RelayKind?
    @State private var isTestingConnection = false
    @State private var testConnectionResult: TestConnectionResult?
    @State private var reconnectGeneration = 0
    @State private var verifiedReconnectGeneration = -1
    @State private var reconnectTask: Task<Void, Never>?
    @State private var endpointNormalizationHighlightToken = 0

    private var provider: Provider? {
        appState.provider(for: providerID)
    }

    private var runtimeConfig: MetadataClient.RelayRuntimeConfig {
        MetadataClient.shared.syncRelayRuntimeConfig()
    }

    var body: some View {
        NavigationStack {
            Group {
                if let provider, let editor {
                    content(for: provider, editor: editor)
                } else {
                    ProgressView()
                        .tint(OriveoTheme.Palette.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .oriveoScreenBackground()
            .onChange(of: editor?.transport) { _, newTransport in
                if let newTransport, newTransport != .openaiResponses {
                    editor?.webSearchToolName = nil
                }
            }
            .onChange(of: editor) { _, currentEditor in
                guard let pendingUnverifiedSave else { return }
                guard RelayEditUnverifiedSavePolicy.mayPersist(
                    candidateProviderID: pendingUnverifiedSave.provider.id,
                    editorSnapshot: pendingUnverifiedSave.editorSnapshot,
                    currentEditor: currentEditor,
                    currentProviderID: provider?.id,
                    targetProviderID: providerID
                ) else {
                    clearPendingUnverifiedSave()
                    return
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("Close")) { attemptClose() }
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(String(format: L10n.tr("Edit • %@", table: .providers), provider?.displayName ?? ""))
                        .font(OriveoTheme.Typography.title3)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                }
            }
            .onAppear {
                initializeEditorIfNeeded()
            }
            .sheet(isPresented: $showEditAPIKey) {
                EditAPIKeySheet(providerID: providerID)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSecurityModePicker) {
                if let provider, let editor {
                    RelaySecurityModePickerSheet(
                        endpoint: editor.endpoint,
                        currentMode: editor.securityMode,
                        hasCredentialMaterial: RelaySecurityModeSelection.hasCredentialMaterial(
                            savedRequested: provider.relayRequested,
                            storedAPIKey: provider.apiKey,
                            draftAuthMode: editor.authMode,
                            draftHeaders: editor.headers,
                            draftQueryParams: editor.queryParams
                        ),
                        onSelect: { applySecurityMode($0, provider: provider) }
                    )
                }
            }
            .alert(String(format: L10n.tr("Delete “%@”?", table: .providers), provider?.displayName ?? ""), isPresented: $showDeleteAlert) {
                Button(L10n.tr("Delete"), role: .destructive) {
                    performDelete()
                }
                Button(L10n.tr("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("This deletes the connection, API key, enabled models, model library, and model behavior settings. It does not delete conversations; message history stays, and models used there are marked unavailable. This cannot be undone.", table: .providers))
            }
            .alert(L10n.tr("Discard unsaved changes?", table: .providers), isPresented: $showDiscardAlert) {
                Button(L10n.tr("Discard"), role: .destructive) { dismiss() }
                Button(L10n.tr("Keep editing", table: .providers), role: .cancel) {}
            } message: {
                Text(L10n.tr("Your changes to this relay have not been saved.", table: .providers))
            }
            .alert(
                L10n.tr("Connection has not been verified.", table: .providers),
                isPresented: $showsUnverifiedSaveConfirmation
            ) {
                Button(L10n.tr("Save anyway (unverified)", table: .providers)) {
                    saveUnverifiedRelay()
                }
                Button(L10n.tr("Keep editing", table: .providers), role: .cancel) {}
            } message: {
                Text(L10n.tr("We couldn't verify the connection. You can retry from the provider details."))
            }
            .sheet(isPresented: $showRelayKindPicker) {
                relayKindPickerSheet
            }
            .alert(
                L10n.tr("Reset relay defaults?", table: .providers),
                isPresented: Binding(
                    get: { pendingRelayKind != nil },
                    set: { if !$0 { pendingRelayKind = nil } }
                )
            ) {
                Button(L10n.tr("Reset", table: .providers), role: .destructive) {
                    if let kind = pendingRelayKind { applyKindReset(to: kind) }
                    pendingRelayKind = nil
                }
                Button(L10n.tr("Cancel"), role: .cancel) {
                    pendingRelayKind = nil
                }
            } message: {
                Text(L10n.tr("Switching the relay type resets transport, auth, and Codex identity to the new defaults. Your model ID and capability picks are kept.", table: .providers))
            }
            .interactiveDismissDisabled(shouldDisableInteractiveDismiss)
        }
    }

    @ViewBuilder
    private var relayKindPickerSheet: some View {
        NavigationStack {
            ScrollView {
                RelayKindPickerView { kind in
                    showRelayKindPicker = false
                    if kind != editor?.relayKind {
                        pendingRelayKind = kind
                    }
                }
                .padding(OriveoTheme.Spacing.xl)
            }
            .oriveoScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("Cancel")) { showRelayKindPicker = false }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func attemptClose() {
        if let editor, let original, editor != original {
            showDiscardAlert = true
        } else {
            dismiss()
        }
    }

    private var shouldDisableInteractiveDismiss: Bool {
        guard let editor, let original else { return false }
        return editor != original
    }

    private func performDelete() {
        let id = providerID
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            _ = appState.deleteProvider(providerID: id)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for provider: Provider, editor: Editor) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                RelayEditorHeroCard(
                    provider: provider,
                    displayName: editor.customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? provider.displayName
                        : editor.customName,
                    endpointText: editor.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : editor.endpoint,
                    relayKind: editor.relayKind,
                    onEditName: { showRenameSheet = true },
                    onChangeKind: { showRelayKindPicker = true }
                )

                RelayConnectionCard(
                    endpoint: endpointBinding,
                    apiKeyPreview: provider.apiKeyPreview,
                    authMode: editor.authMode,
                    securityMode: editor.securityMode,
                    hasStoredKey: RelayCredentialPolicy.hasStoredKey(provider.apiKey),
                    isSubmitting: isSaving,
                    isTestingConnection: isTestingConnection,
                    testResult: testConnectionResult.map(Self.toConnectionStatus),
                    endpointPlaceholder: "https://api.example.com/v1",
                    endpointNormalizationHighlightToken: endpointNormalizationHighlightToken,
                    onChangeSecurityMode: { showSecurityModePicker = true },
                    onEditAPIKey: { showEditAPIKey = true },
                    onRemoveStoredCredential: {
                        appState.providerManager.removeStoredRelayCredential(providerID: provider.id)
                    },
                    onTestConnection: {
                        Task { await runTestConnection(provider: provider) }
                    }
                )
                RelayFormIssueNotes(issues: formIssues(for: provider, editor: editor))

                if let suggested = suggestedRelayKindForCurrentModel(editor: editor) {
                    modelFamilyBanner(suggested: suggested, editor: editor)
                }

                let showsAdvanced = editor.relayKind == .custom
                defaultModelSection(for: provider, editor: editor)
                if showsAdvanced {
                    RelayAdvancedFieldsView(
                        transport: bindingForEditor(\.transport),
                        authMode: bindingForEditor(\.authMode),
                        reasoningEffort: bindingForEditor(\.reasoningEffort),
                        serviceTier: bindingForEditor(\.serviceTier),
                        stream: streamBinding,
                        disableResponseStorage: bindingForEditor(\.disableResponseStorage),
                        isSubmitting: isSaving
                    )

                    if editor.transport == .openaiResponses {
                        RelayWebSearchToolNameSection(
                            webSearchToolName: bindingForEditor(\.webSearchToolName),
                            isSubmitting: isSaving
                        )
                    }

                    RelayAdvancedHTTPSection(
                        customUserAgent: bindingForEditor(\.customUserAgent),
                        headers: bindingForEditor(\.headers),
                        queryParams: bindingForEditor(\.queryParams),
                        isSubmitting: isSaving
                    )
                } else {
                    presetModeInfoCard(editor: editor)
                }

                if let saveError {
                    OriveoErrorCard(error: saveError) {
                        if pendingUnverifiedSave != nil {
                            saveUnverifiedRelay()
                        } else {
                            self.saveError = nil
                        }
                    }
                }

                dangerZone(provider: provider)
            }
            .padding(.horizontal, OriveoTheme.Spacing.xl)
            .padding(.top, OriveoTheme.Spacing.sm)
            .padding(.bottom, OriveoTheme.Spacing.xxl + 72)
        }
        .safeAreaInset(edge: .bottom) {
            saveBar(for: provider)
        }
        .sheet(isPresented: $showRenameSheet) {
            RelayDraftNameSheet(
                name: bindingForEditor(\.customName),
                fallbackName: provider.displayName
            )
            .presentationDetents([.height(220)])
            .presentationDragIndicator(.visible)
        }
    }

    private static func toConnectionStatus(_ result: TestConnectionResult) -> RelayConnectionTestStatus {
        switch result {
        case .success(let message): return .success(message)
        case .failure(let message): return .failure(message)
        }
    }

    @ViewBuilder
    private func presetModeInfoCard(editor: Editor) -> some View {
        let meta = RelayKindMeta.meta(for: editor.relayKind)
        Button {
            showRelayKindPicker = true
        } label: {
            HStack(spacing: OriveoTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(meta.tint.opacity(0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(meta.tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("Preset configuration", table: .providers))
                        .font(OriveoTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Text(L10n.tr("Transport, auth, and behavior are managed by the preset. Switch to Fully Custom to override.", table: .providers))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            .padding(OriveoTheme.Spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .oriveoRoundedSurface(
            fill: OriveoTheme.Palette.surfaceChrome,
            border: meta.tint.opacity(0.16),
            radius: OriveoTheme.Radius.md,
            shadow: .none
        )
    }

    // MARK: - Model Family Banner(Phase G)

    private func suggestedRelayKindForCurrentModel(editor: Editor) -> RelayKind? {
        let family = RelayFamilyHeuristics.infer(modelID: editor.modelID)
        let compat = RelayFamilyHeuristics.compatibleRelayKinds(for: family)
        guard !compat.isEmpty else { return nil }
        if compat.contains(editor.relayKind) { return nil }
        return RelayFamilyHeuristics.suggestedRelayKind(for: family)
    }

    @ViewBuilder
    private func modelFamilyBanner(suggested: RelayKind, editor: Editor) -> some View {
        let suggestedMeta = RelayKindMeta.meta(for: suggested)
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(suggestedMeta.tint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: L10n.tr("Model “%@” looks like %@.", table: .providers),
                                editor.modelID,
                                suggestedMeta.title))
                        .font(OriveoTheme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Text(L10n.tr("Switching the relay type will reset transport, auth, and Codex identity to the recommended defaults.", table: .providers))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button {
                    pendingRelayKind = suggested
                } label: {
                    Text(L10n.tr("Apply suggestion", table: .providers))
                        .font(OriveoTheme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(suggestedMeta.tint))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(OriveoTheme.Spacing.md)
        .oriveoRoundedSurface(
            fill: suggestedMeta.tint.opacity(0.08),
            border: suggestedMeta.tint.opacity(0.3),
            radius: OriveoTheme.Radius.md,
            shadow: .none
        )
    }

    // MARK: - Test Connection Row(Phase C)

    enum TestConnectionResult: Equatable {
        case success(message: String)
        case failure(message: String)
    }

    @MainActor
    private func runTestConnection(provider: Provider) async {
        guard !isTestingConnection else { return }
        let trimmedEndpoint = (editor?.endpoint ?? provider.baseURLText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty else {
            testConnectionResult = .failure(message: L10n.tr("Enter a request URL.", table: .providers))
            return
        }
        let securityMode = editor?.securityMode ?? provider.relayRequested?.securityMode ?? .remoteHTTPS
        guard let writeback = RelaySecurityModeSelection.endpointWriteback(
            trimmedEndpoint,
            securityMode: securityMode
        ) else {
            testConnectionResult = .failure(message: L10n.tr(RelayEndpointPolicy.httpsRequiredMessageKey, table: .providers))
            return
        }
        if writeback.didChange {
            endpointBinding.wrappedValue = writeback.endpoint
            endpointNormalizationHighlightToken &+= 1
        }

        isTestingConnection = true
        testConnectionResult = nil
        defer { isTestingConnection = false }

        let requested = makeProbeRequested()
        var candidate = provider
        candidate.baseURLText = writeback.endpoint
        candidate.relayRequested = requested
        candidate.relayKind = editor?.relayKind ?? provider.relayKind
        let persistsResult = RelayConnectionPersistenceComparator.matches(
            provider: provider,
            candidateEndpoint: writeback.endpoint,
            candidateRequested: requested,
            candidateKind: candidate.relayKind
        )

        do {
            try await appState.providerManager.verifyRelayGeneration(candidate)
            if persistsResult {
                appState.providerManager.recordRelayGenerationVerification(providerID: provider.id, verified: true)
            }
            testConnectionResult = .success(message: L10n.tr("Connection verified.", table: .providers))
        } catch {
            if persistsResult {
                appState.providerManager.recordRelayGenerationVerification(
                    providerID: provider.id,
                    verified: false,
                    error: error
                )
            }
            let message = (error as? ProviderServiceError)?.message
                ?? L10n.tr("We couldn't verify the connection. You can retry from the provider details.")
            testConnectionResult = .failure(message: message)
        }
    }

    private func makeProbeRequested() -> RelayRequestedConfig {
        guard let editor else { return RelayRequestedConfig() }
        let trimmedUA = editor.customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedHeaders = editor.headers
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let cleanedQueries = editor.queryParams
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let existingRequested = provider?.relayRequested
        return RelayRequestedConfig(
            transport: editor.transport,
            authMode: editor.authMode,
            securityMode: editor.securityMode,
            modelID: editor.modelID.isEmpty ? nil : editor.modelID,
            reasoningEffort: editor.reasoningEffort == .automatic ? nil : editor.reasoningEffort,
            serviceTier: editor.serviceTier.isEmpty ? nil : editor.serviceTier,
            stream: false,
            disableResponseStorage: editor.disableResponseStorage ? true : nil,
            headers: cleanedHeaders.isEmpty ? nil : cleanedHeaders,
            queryParams: cleanedQueries.isEmpty ? nil : cleanedQueries,
            codexCompatIdentity: editor.relayKind == .codexStyle ? editor.codexCompatIdentity : nil,
            customUserAgent: trimmedUA.isEmpty ? nil : trimmedUA,
            imageSize: existingRequested?.imageSize,
            imageQuality: existingRequested?.imageQuality,
            imageStyle: existingRequested?.imageStyle,
            imageCount: existingRequested?.imageCount,
            imageResponseFormat: existingRequested?.imageResponseFormat,
            webSearchToolName: (editor.transport == .openaiResponses
                && editor.webSearchToolName != nil
                && editor.webSearchToolName != .webSearch)
                ? editor.webSearchToolName
                : nil,
            hasWebSearch: existingRequested?.hasWebSearch,
            webSearchProfile: existingRequested?.webSearchProfile,
            transportKind: existingRequested?.transportKind,
            resolvedAPIBaseURL: resolvedAPIBaseURL(
                for: editor.endpoint,
                provider: provider,
                securityMode: editor.securityMode
            ),
            engineProfile: existingRequested?.engineProfile,
            certificateFingerprint: existingRequested?.certificateFingerprint
        )
    }

    // MARK: - Connection type transition

    @MainActor
    private func applySecurityMode(
        _ nextMode: RelayConnectionSecurityMode,
        provider: Provider
    ) {
        guard RelaySecurityModeSelection.selectableModes.contains(nextMode),
              var nextEditor = editor,
              nextMode != nextEditor.securityMode else { return }

        let transition = RelaySecurityModeSelection.persistedTransition(
            savedRequested: provider.relayRequested,
            storedAPIKey: provider.apiKey,
            draftAuthMode: nextEditor.authMode,
            draftHeaders: nextEditor.headers,
            draftQueryParams: nextEditor.queryParams,
            nextMode: nextMode
        )
        if nextMode == .localHTTP || nextMode == .privateVPN {
            nextEditor.authMode = .none
            if transition.clearsCredentialTables {
                nextEditor.headers = []
                nextEditor.queryParams = []
            }
        }

        let endpointForNextMode: String
        if nextMode == .remoteHTTPS,
           nextEditor.endpoint.lowercased().hasPrefix("http://") {
            endpointForNextMode = "https://" + nextEditor.endpoint.dropFirst("http://".count)
        } else {
            endpointForNextMode = nextEditor.endpoint
        }
        guard let normalizedEndpoint = RelaySecurityModeSelection.normalizedEndpoint(
            endpointForNextMode,
            securityMode: nextMode
        ) else {
            saveError = OriveoError(
                id: UUID(),
                title: L10n.tr("Invalid request URL", table: .providers),
                message: L10n.tr(RelayEndpointPolicy.httpsRequiredMessageKey, table: .providers),
                actionTitle: L10n.tr("OK"),
                detail: nextEditor.endpoint,
                severity: .warning
            )
            return
        }

        nextEditor.endpoint = normalizedEndpoint
        nextEditor.securityMode = nextMode
        editor = nextEditor
        var persistedBaseline = original ?? Editor(from: provider)
        persistedBaseline = persistedBaseline.applyingPersistedSecurityBaseline(
            endpoint: normalizedEndpoint,
            securityMode: nextMode,
            clearsCredentialTables: transition.clearsCredentialTables
        )
        original = persistedBaseline
        endpointNormalizationHighlightToken &+= 1
        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        reconnectTask?.cancel()
        testConnectionResult = .failure(
            message: L10n.tr("Validating connection and syncing models...", table: .providers)
        )

        var transitioning = provider
        transitioning.baseURLText = normalizedEndpoint
        if transition.clearsStoredAPIKey {
            transitioning.apiKey = ""
            transitioning.apiKeyPreview = APIKeyMask.masked("")
        }
        transitioning.relayRequested = transition.requested
        transitioning.catalogModels = []
        transitioning.status = .issue(ProviderIssueMessage.unverifiedConnectionKey)
        transitioning.lastError = ProviderIssueMessage.unverifiedConnectionKey
        appState.providerManager.updateProvider(transitioning)

        reconnectTask = Task { @MainActor in
            await reconnectAfterSecurityModeChange(
                providerID: transitioning.id,
                generation: generation
            )
        }
    }

    @MainActor
    private func reconnectAfterSecurityModeChange(providerID: UUID, generation: Int) async {
        guard generation == reconnectGeneration,
              var current = appState.providerManager.provider(for: providerID),
              var requested = current.relayRequested,
              let endpoint = current.baseURLText else { return }
        let expectedMode = requested.securityMode
        isTestingConnection = true
        defer {
            if generation == reconnectGeneration {
                isTestingConnection = false
                reconnectTask = nil
            }
        }

        do {
            let discovery = try await RelayDiscoveryService().discover(
                endpoint: endpoint,
                apiKey: current.apiKey,
                modelHint: requested.modelID,
                securityMode: requested.securityMode
            )
            try Task.checkCancellation()
            guard canPersistReconnect(
                providerID: providerID,
                generation: generation,
                expectedMode: expectedMode
            ) else { return }
            if let detected = discovery.detections.first(where: { $0.transport == requested.transport })
                ?? discovery.detections.first {
                requested.resolvedAPIBaseURL = detected.apiBaseURL
                current.relayRequested = requested
                appState.providerManager.updateProvider(current)
            }

            try await appState.providerManager.reverifyRelayProvider(
                providerID: providerID,
                refreshCatalog: true,
                commitGuard: {
                    canPersistReconnect(
                    providerID: providerID,
                    generation: generation,
                    expectedMode: expectedMode
                    )
                }
            )
            try Task.checkCancellation()
            guard canPersistReconnect(
                providerID: providerID,
                generation: generation,
                expectedMode: expectedMode
            ) else {
                restoreIssueIfLatestReconnectIsStillPending(providerID: providerID, expectedGeneration: generation)
                return
            }
            verifiedReconnectGeneration = generation
            testConnectionResult = .success(
                message: L10n.tr("Connection verified.", table: .providers)
            )
        } catch is CancellationError {
            restoreIssueIfLatestReconnectIsStillPending(providerID: providerID, expectedGeneration: generation)
        } catch {
            guard generation == reconnectGeneration else {
                return
            }
            appState.providerManager.recordRelayGenerationVerification(
                providerID: providerID,
                verified: false,
                error: error
            )
            let message = (error as? ProviderServiceError)?.message
                ?? L10n.tr("We couldn't verify the connection. You can retry from the provider details.")
            testConnectionResult = .failure(message: message)
        }
    }

    @MainActor
    private func restoreIssueIfLatestReconnectIsStillPending(providerID: UUID, expectedGeneration: Int) {
        guard expectedGeneration == reconnectGeneration,
              verifiedReconnectGeneration != expectedGeneration else { return }
        appState.providerManager.recordRelayGenerationVerification(
            providerID: providerID,
            verified: false
        )
    }

    @MainActor
    private func canPersistReconnect(
        providerID: UUID,
        generation: Int,
        expectedMode: RelayConnectionSecurityMode
    ) -> Bool {
        RelaySecurityModeSelection.allowsReconnectPersistence(
            expectedGeneration: generation,
            currentGeneration: reconnectGeneration,
            expectedMode: expectedMode,
            currentRequested: appState.providerManager.provider(for: providerID)?.relayRequested
        )
    }

    // MARK: - Danger Zone

    private func dangerZone(provider: Provider) -> some View {
        Button {
            showDeleteAlert = true
        } label: {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                Text(L10n.tr("Delete Provider", table: .providers))
                    .font(OriveoTheme.Typography.body.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(OriveoTheme.Palette.danger)
            .padding(.horizontal, OriveoTheme.Spacing.md)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .oriveoRoundedSurface(
            fill: OriveoTheme.Palette.surfaceChrome,
            border: OriveoTheme.Palette.danger.opacity(0.22),
            radius: OriveoTheme.Radius.md,
            shadow: .none
        )
    }

    // MARK: - Save bar

    private func saveBar(for provider: Provider) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(height: 0.6)
            let action = RelayEditSavePolicy.primaryAction(from: provider, editor: editor ?? .empty)
            Button(isSaving ? L10n.tr("Saving...", table: .providers) : L10n.tr(action.titleKey, table: .providers)) {
                Task { await save(provider: provider) }
            }
            .buttonStyle(OriveoPrimaryButtonStyle())
            .disabled(!canSave || isSaving)
            .opacity(canSave && !isSaving ? 1 : 0.55)
            .padding(.horizontal, OriveoTheme.Spacing.xl)
            .padding(.top, OriveoTheme.Spacing.md)
            .padding(.bottom, OriveoTheme.Spacing.lg)
        }
        .background(OriveoTheme.Palette.surfaceChrome)
    }


    private func formDraft(for provider: Provider, editor: Editor) -> RelayFormDraft {
        var draft = RelayFormDraft(
            requested: provider.relayRequested,
            endpoint: editor.endpoint,
            hasSavedCredential: RelayCredentialPolicy.hasStoredKey(provider.apiKey)
        )
        draft.transport = editor.transport
        draft.authMode = editor.authMode
        draft.securityMode = editor.securityMode
        draft.modelID = editor.modelID
        draft.headers = editor.headers
        draft.queryParams = editor.queryParams
        return draft
    }

    private func formIssues(for provider: Provider, editor: Editor) -> [RelayFormValidation.FieldIssue] {
        RelayFormValidation.validate(formDraft(for: provider, editor: editor), mode: .edit)
    }

    private var canSave: Bool {
        guard let provider, let editor else { return false }
        return formIssues(for: provider, editor: editor).isEmpty
    }


    private func initializeEditorIfNeeded() {
        guard editor == nil, let provider else { return }
        let e = Editor(from: provider)
        editor = e
        original = e
    }

    private func bindingForEditor<Value>(_ keyPath: WritableKeyPath<Editor, Value>) -> Binding<Value> {
        Binding(
            get: { editor?[keyPath: keyPath] ?? Editor.empty[keyPath: keyPath] },
            set: {
                guard var cur = editor else { return }
                cur[keyPath: keyPath] = $0
                editor = cur
            }
        )
    }

    private var endpointBinding: Binding<String> {
        Binding(
            get: { editor?.endpoint ?? "" },
            set: { nextEndpoint in
                guard var current = editor, current.endpoint != nextEndpoint else { return }
                current.endpoint = nextEndpoint
                editor = current
                reconnectGeneration &+= 1
                reconnectTask?.cancel()
                reconnectTask = nil
                testConnectionResult = nil
            }
        )
    }

    private var streamBinding: Binding<Bool> {
        Binding(
            get: { editor?.stream ?? Editor.empty.stream },
            set: {
                guard var cur = editor else { return }
                cur.stream = $0
                cur.streamTouched = true
                editor = cur
            }
        )
    }


    private func applyKindReset(to newKind: RelayKind) {
        guard var cur = editor else { return }
        let preserved = RelayRequestedConfig(
            transport: cur.transport,
            authMode: cur.authMode,
            modelID: cur.modelID.isEmpty ? nil : cur.modelID,
            reasoningEffort: cur.reasoningEffort,
            serviceTier: cur.serviceTier.isEmpty ? nil : cur.serviceTier,
            stream: cur.stream,
            disableResponseStorage: cur.disableResponseStorage,
            headers: cur.headers.isEmpty ? nil : cur.headers,
            queryParams: cur.queryParams.isEmpty ? nil : cur.queryParams,
            codexCompatIdentity: cur.codexCompatIdentity,
            customUserAgent: cur.customUserAgent.isEmpty ? nil : cur.customUserAgent,
            imageSize: provider?.relayRequested?.imageSize,
            imageQuality: provider?.relayRequested?.imageQuality,
            imageStyle: provider?.relayRequested?.imageStyle,
            imageCount: provider?.relayRequested?.imageCount,
            imageResponseFormat: provider?.relayRequested?.imageResponseFormat,
            webSearchToolName: cur.webSearchToolName,
            hasWebSearch: provider?.relayRequested?.hasWebSearch,
            webSearchProfile: provider?.relayRequested?.webSearchProfile,
            transportKind: provider?.relayRequested?.transportKind,
            resolvedAPIBaseURL: provider?.relayRequested?.resolvedAPIBaseURL
        )
        let next = RelayKindDefaults.makeRequested(for: newKind, preserving: preserved)
        cur.relayKind = newKind
        cur.transport = next.transport
        cur.authMode = next.authMode
        cur.reasoningEffort = next.reasoningEffort ?? .automatic
        cur.stream = next.stream ?? true
        cur.streamTouched = true
        cur.disableResponseStorage = next.disableResponseStorage ?? false
        cur.codexCompatIdentity = next.codexCompatIdentity ?? false
        editor = cur
    }


    @MainActor
    private func save(provider: Provider) async {
        guard let editor else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        var updated = provider

        let trimmedName = editor.customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpoint = editor.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = editor.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedServiceTier = editor.serviceTier.trimmingCharacters(in: .whitespacesAndNewlines)

        updated.customName = appState.providerManager.normalizedProviderName(
            desiredName: trimmedName,
            for: provider
        )

        let existingRequested = provider.relayRequested
        let cleanedHeaders = editor.headers
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let cleanedQueries = editor.queryParams
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let securityMode = editor.securityMode
        let hasStoredKey = RelayCredentialPolicy.hasStoredKey(provider.apiKey)
        let normalizedEndpoint: String
        do {
            normalizedEndpoint = try RelayEndpointPolicy.requireConfigured(
                trimmedEndpoint,
                securityMode: securityMode,
                credentials: RelayCredentialPolicy.endpointCredentials(
                    for: RelayRequestedConfig(
                        transport: editor.transport,
                        authMode: editor.authMode,
                        securityMode: securityMode,
                        headers: cleanedHeaders.isEmpty ? nil : cleanedHeaders,
                        queryParams: cleanedQueries.isEmpty ? nil : cleanedQueries
                    ),
                    hasStoredKey: hasStoredKey
                )
            )
        } catch {
            saveError = OriveoError(
                id: UUID(),
                title: L10n.tr("Invalid request URL", table: .providers),
                message: relaySaveBlockMessage(for: error),
                actionTitle: L10n.tr("OK"),
                detail: trimmedEndpoint,
                severity: .warning
            )
            return
        }
        if normalizedEndpoint != editor.endpoint {
            endpointBinding.wrappedValue = normalizedEndpoint
            endpointNormalizationHighlightToken &+= 1
        }
        updated.baseURLText = normalizedEndpoint

        let resolvedStream: Bool? = editor.streamTouched ? editor.stream : existingRequested?.stream
        let resolvedCodexIdentity: Bool? = editor.relayKind == .codexStyle
            ? editor.codexCompatIdentity
            : nil
        let trimmedUA = editor.customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let newRequested = RelayRequestedConfig(
            transport: editor.transport,
            authMode: editor.authMode,
            securityMode: securityMode,
            modelID: trimmedModel.isEmpty ? nil : trimmedModel,
            reasoningEffort: editor.reasoningEffort == .automatic ? nil : editor.reasoningEffort,
            serviceTier: trimmedServiceTier.isEmpty ? nil : trimmedServiceTier,
            stream: resolvedStream,
            disableResponseStorage: editor.disableResponseStorage ? true : nil,
            headers: cleanedHeaders.isEmpty ? nil : cleanedHeaders,
            queryParams: cleanedQueries.isEmpty ? nil : cleanedQueries,
            codexCompatIdentity: resolvedCodexIdentity,
            customUserAgent: trimmedUA.isEmpty ? nil : trimmedUA,
            imageSize: existingRequested?.imageSize,
            imageQuality: existingRequested?.imageQuality,
            imageStyle: existingRequested?.imageStyle,
            imageCount: existingRequested?.imageCount,
            imageResponseFormat: existingRequested?.imageResponseFormat,
            webSearchToolName: (editor.transport == .openaiResponses
                && editor.webSearchToolName != nil
                && editor.webSearchToolName != .webSearch)
                ? editor.webSearchToolName
                : nil,
            hasWebSearch: existingRequested?.hasWebSearch,
            webSearchProfile: existingRequested?.webSearchProfile,
            transportKind: existingRequested?.transportKind,
            resolvedAPIBaseURL: resolvedAPIBaseURL(
                for: normalizedEndpoint,
                provider: provider,
                securityMode: securityMode
            ),
            engineProfile: existingRequested?.engineProfile,
            certificateFingerprint: existingRequested?.certificateFingerprint
        )
        updated.relayRequested = newRequested
        updated.relayKind = editor.relayKind
        let requiresReconnect = RelayEditSavePolicy.clearsCatalogBeforeVerification(from: provider, editor: editor)
        updated = RelayEditSavePolicy.invalidatingCatalogIfConnectionChanged(
            updated,
            from: provider,
            editor: editor
        )
        updated = ProviderManager.applyingRelayDefaultModelSelection(
            to: updated,
            modelID: editor.modelID
        )

        guard requiresReconnect else {
            // Name/default model/UA/headers/query and display-only fields are local
            // configuration.  They save without a probe or catalog refresh.
            appState.providerManager.updateProvider(updated)
            original = editor
            await Task.yield()
            dismiss()
            return
        }

        // Entity + configuration generation guard: an old probe may never commit
        // after the editor has changed again or the provider instance disappeared.
        saveGeneration &+= 1
        let generation = saveGeneration
        let capturedEditor = editor
        do {
            try await appState.providerManager.verifyRelayGeneration(updated)
            guard generation == saveGeneration,
                  editor == capturedEditor,
                  appState.provider(for: providerID)?.id == provider.id else { return }

            updated.status = .connected
            updated.lastCheckedAt = Date()
            updated.lastError = nil
            appState.providerManager.updateProvider(updated)
            original = editor
            dismiss()
            Task { @MainActor in
                _ = await appState.providerManager.refreshRelayCatalog(providerID: provider.id)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == saveGeneration, editor == capturedEditor else { return }
            // The user explicitly decides whether an unverified connection is saved.
            // Until they do, the last verified provider remains untouched.
            updated.status = .issue(ProviderIssueMessage.unverifiedConnectionKey)
            updated.lastCheckedAt = nil
            updated.lastError = ProviderIssueMessage.unverifiedConnectionKey
            pendingUnverifiedSave = PendingUnverifiedRelaySave(
                provider: updated,
                editorSnapshot: capturedEditor
            )
            saveError = RelayEditFailurePresentation.error(
                from: error,
                provider: updated
            )
            showsUnverifiedSaveConfirmation = true
        }
    }

    @MainActor
    private func saveUnverifiedRelay() {
        guard let pendingUnverifiedSave else { return }
        guard RelayEditUnverifiedSavePolicy.mayPersist(
            candidateProviderID: pendingUnverifiedSave.provider.id,
            editorSnapshot: pendingUnverifiedSave.editorSnapshot,
            currentEditor: editor,
            currentProviderID: provider?.id,
            targetProviderID: providerID
        ) else {
            clearPendingUnverifiedSave()
            return
        }
        appState.providerManager.updateProvider(pendingUnverifiedSave.provider)
        Task { @MainActor in
            _ = await appState.providerManager.refreshRelayCatalog(
                providerID: pendingUnverifiedSave.provider.id
            )
        }
        original = editor
        clearPendingUnverifiedSave()
        dismiss()
    }

    private func clearPendingUnverifiedSave() {
        pendingUnverifiedSave = nil
        showsUnverifiedSaveConfirmation = false
        saveError = nil
    }

    @ViewBuilder
    private func defaultModelSection(for provider: Provider, editor: Editor) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            RelayGroupHeader(
                title: L10n.tr("Default Model", table: .providers),
                systemImage: "cpu",
                tint: Color.dynamic(light: 0x2563EB, dark: 0x60A5FA)
            )
            RelayRowGroup {
                if RelayDefaultModelPresentation.usesCatalogPicker(
                    for: provider,
                    isCatalogRefreshing: appState.relayCatalogRefreshingProviderIDs.contains(provider.id)
                ) {
                    RelayMenuRow(
                        title: L10n.tr("Default Model", table: .providers),
                        value: editor.modelID,
                        isEnabled: !isSaving
                    ) {
                        Picker(L10n.tr("Default Model", table: .providers), selection: bindingForEditor(\.modelID)) {
                            if !editor.modelID.isEmpty,
                               !provider.catalogModels.contains(where: { $0.id == editor.modelID }) {
                                Text("\(editor.modelID) - \(L10n.tr("No longer in the catalog", table: .providers))")
                                    .tag(editor.modelID)
                            }
                            ForEach(provider.catalogModels.sorted(by: pickerModelSort), id: \.id) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                    }
                } else {
                    // Directory failure and a successful empty response both keep a real
                    // manual default-model exit; neither renders an empty catalog block.
                    RelayInlineTextRow(
                        title: L10n.tr("Default Model", table: .providers),
                        text: bindingForEditor(\.modelID),
                        placeholder: L10n.tr("optional", table: .providers),
                        isEnabled: !isSaving
                    )
                }
            }
        }
    }

    private func resolvedAPIBaseURL(
        for endpoint: String,
        provider: Provider?,
        securityMode: RelayConnectionSecurityMode
    ) -> String? {
        guard let provider,
              let normalizedNew = RelayEndpointPolicy.normalize(endpoint, securityMode: securityMode),
              let normalizedOld = RelayEndpointPolicy.normalize(
                  provider.baseURLText ?? "",
                  securityMode: securityMode
              ),
              normalizedNew == normalizedOld else {
            return nil
        }
        return provider.relayRequested?.resolvedAPIBaseURL
    }

    private func relaySaveBlockMessage(for error: Error) -> String {
        guard case ProviderServiceError.invalidConfiguration(let reason) = error,
              reason == "cleartext_credentials" else {
            return L10n.tr(RelayEndpointPolicy.httpsRequiredMessageKey, table: .providers)
        }
        return L10n.tr("An unencrypted connection can't carry a key.", table: .providers)
    }

    // MARK: - Editor state

    struct Editor: Equatable {
        var customName: String
        var endpoint: String
        var modelID: String
        var transport: RelayTransport
        var authMode: RelayAuthMode
        var securityMode: RelayConnectionSecurityMode
        var reasoningEffort: RelayReasoningEffort
        var serviceTier: String
        var stream: Bool
        var streamTouched: Bool
        var disableResponseStorage: Bool
        var relayKind: RelayKind
        var codexCompatIdentity: Bool
        var customUserAgent: String
        var headers: [RelayKeyValue]
        var queryParams: [RelayKeyValue]
        var webSearchToolName: RelayWebSearchToolName?

        static let empty = Editor(
            customName: "",
            endpoint: "",
            modelID: "",
            transport: .auto,
            authMode: .auto,
            securityMode: .remoteHTTPS,
            reasoningEffort: .automatic,
            serviceTier: "",
            stream: true,
            streamTouched: false,
            disableResponseStorage: false,
            relayKind: .custom,
            codexCompatIdentity: false,
            customUserAgent: "",
            headers: [],
            queryParams: [],
            webSearchToolName: nil
        )

        init(
            customName: String,
            endpoint: String,
            modelID: String,
            transport: RelayTransport,
            authMode: RelayAuthMode,
            securityMode: RelayConnectionSecurityMode,
            reasoningEffort: RelayReasoningEffort,
            serviceTier: String,
            stream: Bool,
            streamTouched: Bool,
            disableResponseStorage: Bool,
            relayKind: RelayKind,
            codexCompatIdentity: Bool,
            customUserAgent: String,
            headers: [RelayKeyValue],
            queryParams: [RelayKeyValue],
            webSearchToolName: RelayWebSearchToolName? = nil
        ) {
            self.customName = customName
            self.endpoint = endpoint
            self.modelID = modelID
            self.transport = transport
            self.authMode = authMode
            self.securityMode = securityMode
            self.reasoningEffort = reasoningEffort
            self.serviceTier = serviceTier
            self.stream = stream
            self.streamTouched = streamTouched
            self.disableResponseStorage = disableResponseStorage
            self.relayKind = relayKind
            self.codexCompatIdentity = codexCompatIdentity
            self.customUserAgent = customUserAgent
            self.headers = headers
            self.queryParams = queryParams
            self.webSearchToolName = webSearchToolName
        }

        init(from provider: Provider) {
            let req = provider.relayRequested
            self.customName = provider.customName ?? ""
            self.endpoint = provider.baseURLText ?? ""
            self.modelID = req?.modelID ?? provider.defaultModel?.id ?? provider.catalogModels.first?.id ?? ""
            self.transport = req?.transport ?? .auto
            self.authMode = req?.authMode ?? .auto
            self.securityMode = req?.securityMode ?? .remoteHTTPS
            self.reasoningEffort = req?.reasoningEffort ?? .automatic
            self.serviceTier = req?.serviceTier ?? ""
            self.stream = req?.stream ?? true
            self.streamTouched = req?.stream != nil
            self.disableResponseStorage = req?.disableResponseStorage ?? false
            let inferredKind = provider.relayKind
                ?? RelayKindDefaults.inferKind(from: req, baseURL: provider.baseURLText)
            self.relayKind = inferredKind
            self.codexCompatIdentity = req?.codexCompatIdentity ?? (inferredKind == .codexStyle)
            self.customUserAgent = req?.customUserAgent ?? ""
            self.headers = req?.headers ?? []
            self.queryParams = req?.queryParams ?? []
            self.webSearchToolName = req?.webSearchToolName
        }

        func applyingPersistedSecurityBaseline(
            endpoint: String,
            securityMode: RelayConnectionSecurityMode,
            clearsCredentialTables: Bool
        ) -> Editor {
            var baseline = self
            baseline.endpoint = endpoint
            baseline.securityMode = securityMode
            if securityMode == .localHTTP || securityMode == .privateVPN {
                baseline.authMode = .none
                if clearsCredentialTables {
                    baseline.headers = []
                    baseline.queryParams = []
                }
            }
            return baseline
        }
    }
}

enum RelayConnectionPersistenceComparator {
    static func matches(
        provider: Provider,
        candidateEndpoint: String,
        candidateRequested: RelayRequestedConfig,
        candidateKind: RelayKind?
    ) -> Bool {
        guard provider.kind == .relay,
              provider.relayKind == candidateKind,
              normalizedEndpoint(provider.baseURLText) == normalizedEndpoint(candidateEndpoint),
              let persisted = provider.relayRequested else { return false }
        return persisted.transport == candidateRequested.transport
            && persisted.authMode == candidateRequested.authMode
            && persisted.securityMode == candidateRequested.securityMode
            && persisted.modelID == candidateRequested.modelID
            && persisted.reasoningEffort == candidateRequested.reasoningEffort
            && persisted.serviceTier == candidateRequested.serviceTier
            && persisted.disableResponseStorage == candidateRequested.disableResponseStorage
            && (persisted.headers ?? []) == (candidateRequested.headers ?? [])
            && (persisted.queryParams ?? []) == (candidateRequested.queryParams ?? [])
            && persisted.customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
                == candidateRequested.customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
            && persisted.webSearchToolName == candidateRequested.webSearchToolName
            && canonicalCodexIdentity(persisted, kind: provider.relayKind)
                == canonicalCodexIdentity(candidateRequested, kind: candidateKind)
    }

    private static func normalizedEndpoint(_ endpoint: String?) -> String? {
        endpoint?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func canonicalCodexIdentity(_ requested: RelayRequestedConfig, kind: RelayKind?) -> Bool? {
        kind == .codexStyle ? requested.codexCompatIdentity != false : nil
    }
}

enum RelayEditSavePolicy {
    static func primaryAction(from provider: Provider, editor: RelayEditView.Editor) -> RelayEditPrimaryAction {
        provider.baseURLText?.trimmingCharacters(in: .whitespacesAndNewlines)
            != editor.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            || provider.relayKind != editor.relayKind
            || provider.relayRequested?.transport != editor.transport
            || provider.relayRequested?.authMode != editor.authMode
            ? .validateAndSave
            : .save
    }

    static func clearsCatalogBeforeVerification(from provider: Provider, editor: RelayEditView.Editor) -> Bool {
        primaryAction(from: provider, editor: editor) == .validateAndSave
    }

    static func invalidatingCatalogIfConnectionChanged(
        _ candidate: Provider,
        from provider: Provider,
        editor: RelayEditView.Editor
    ) -> Provider {
        guard clearsCatalogBeforeVerification(from: provider, editor: editor) else { return candidate }
        var invalidated = candidate
        invalidated.catalogModels = []
        return invalidated
    }
}

enum RelayDefaultModelPresentation {
    static func usesCatalogPicker(for provider: Provider, isCatalogRefreshing: Bool) -> Bool {
        provider.kind == .relay
            && !isCatalogRefreshing
            && provider.lastError != ProviderIssueMessage.catalogUnavailableKey
            && !provider.catalogModels.isEmpty
    }
}

enum RelayEditPrimaryAction: Equatable {
    case save
    case validateAndSave

    var titleKey: String {
        switch self {
        case .save: "Save"
        case .validateAndSave: "Validate and save"
        }
    }
}

struct PendingUnverifiedRelaySave {
    let provider: Provider
    let editorSnapshot: RelayEditView.Editor
}

enum RelayEditUnverifiedSavePolicy {
    static func mayPersist(
        candidateProviderID: UUID,
        editorSnapshot: RelayEditView.Editor,
        currentEditor: RelayEditView.Editor?,
        currentProviderID: UUID?,
        targetProviderID: UUID
    ) -> Bool {
        candidateProviderID == targetProviderID
            && currentProviderID == candidateProviderID
            && currentEditor == editorSnapshot
    }
}

/// The error card is a user-visible security boundary.  Provider errors often
/// echo the complete request URL or custom credentials; neither is safe to put
/// into expandable technical details.
enum RelayEditFailurePresentation {
    static func error(
        from error: Error,
        provider: Provider,
        actionTitle: String? = nil
    ) -> OriveoError {
        let providerError: ProviderServiceError
        if let typed = error as? ProviderServiceError {
            providerError = typed
        } else {
            providerError = .network(detail: error.localizedDescription)
        }
        let retryDetail = String(
            format: L10n.tr("Retried %d time(s) automatically.", table: .providers),
            0
        )
        let technicalDetail = redactedTechnicalDetail(
            providerError.technicalDetail,
            provider: provider
        )
        return OriveoError(
            id: UUID(),
            title: providerError.title,
            message: providerError.message,
            actionTitle: actionTitle ?? L10n.tr("Save anyway (unverified)", table: .providers),
            detail: technicalDetail.isEmpty ? retryDetail : "\(retryDetail)\n\(technicalDetail)",
            severity: .warning
        )
    }

    private static func redactedTechnicalDetail(_ detail: String, provider: Provider) -> String {
        let requested = provider.relayRequested
        var sensitiveMaterial: [String] = [provider.apiKey]
        // Endpoint host/path and parameter names are safe diagnostics.  The form
        // already rejects user-info and embedded queries; only credential values
        // may be hidden here, never the whole URL or field name.
        sensitiveMaterial += (requested?.headers ?? []).map(\.value)
        sensitiveMaterial += (requested?.queryParams ?? []).map(\.value)
        return sensitiveMaterial
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(detail) { partial, material in
                RelayRequestSecurity.redactingCredentials(partial, credentials: [material])
                    .replacingOccurrences(of: material, with: RelayRequestSecurity.redactedPlaceholder)
            }
    }
}

private struct RelayDraftNameSheet: View {
    @Binding var name: String
    let fallbackName: String

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                OriveoLabeledField(
                    title: L10n.tr("Name", table: .providers),
                    text: $draft,
                    placeholder: fallbackName,
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
                        name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                draft = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : name
            }
        }
    }
}
