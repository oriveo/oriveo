import SwiftUI

/// The "Edit connection" modal.
///
/// Entry: the detail page header "Edit connection" action, or the default protocol row (local engines: the channel row) -> this sheet
///
/// Editable: request address (local engines: engine address) / connection security / default protocol (local engines: channel) / auth mode /
/// headers and query parameters / compatibility (streaming, service tier, no cloud response retention).
/// There is no type layer: relayKind is derived from the default protocol on save; renaming, changing keys and deleting live only on the detail page.
/// The page renders strictly from `RelayEditBoardModel` (`RelayEditBoardView`); this file owns state, saving and connection-security switching.
struct RelayEditView: View {
    let providerID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    // Edit form state (initialized from the Provider plus local user edits; only Save persists)
    @State private var editor: Editor?
    /// `original` is compared against to detect unsaved edits; closing with changes shows the Discard confirmation
    @State private var original: Editor?
    @State private var isSaving = false
    @State private var showSecurityModePicker = false
    @State private var showDiscardAlert = false
    @State private var saveError: OriveoError?
    @State private var pendingUnverifiedSave: PendingUnverifiedRelaySave?
    @State private var saveGeneration = 0
    /// The single status entry at the end of the content, shared by connection tests and the reconnect after a security switch.
    @State private var status: RelayEditBoardModel.Status?
    @State private var reconnectGeneration = 0
    @State private var verifiedReconnectGeneration = -1
    @State private var reconnectTask: Task<Void, Never>?
    @State private var endpointNormalizationHighlightToken = 0
    /// Compatibility rows the draft opened during this editing session: a row that only appears while the draft enables it stays until the user leaves the page, even if they switch it off.
    @State private var shownCompatibilityRows: Set<RelayEditBoardModel.RowID> = []

    private var provider: Provider? {
        appState.provider(for: providerID)
    }

    private var runtimeConfig: MetadataClient.RelayRuntimeConfig {
        MetadataClient.shared.syncRelayRuntimeConfig()
    }

    /// A connection test or reconnect is in flight. Both occupy the same status row, so a second one must not start meanwhile.
    private var isTestingConnection: Bool {
        status == .testing || status == .reconnecting
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if let provider, let editor {
                    content(for: provider, editor: editor)
                } else {
                    ProgressView()
                        .tint(OriveoTheme.Palette.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .oriveoScreenBackground()
        .onChange(of: editor) { _, currentEditor in
            // After a failed validation the user may keep editing; once the draft changes, the old candidate must never
            // be written back from the failure card. Saving re-checks this guard too, to cover the race before the observer callback fires.
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
        .onAppear {
            initializeEditorIfNeeded()
            #if DEBUG
            // Preview-only: feed one validation failure to the existing failure card.
            RelayFamilyDebugShots.feedEditFailure(for: provider) { saveError = $0 }
            #endif
        }
        .sheet(isPresented: $showSecurityModePicker) {
            if let provider, let editor {
                RelaySecurityModePickerSheet(
                    endpoint: editor.endpoint,
                    currentMode: editor.securityMode,
                    hasCredentialMaterial: RelaySecurityModeSelection.hasCredentialMaterial(
                        savedRequested: provider.relayRequested,
                        storedAPIKey: provider.apiKey, // key-choke: stored-field loads the saved key into the edit form to judge credential material; it does not fetch a key for any model
                        draftAuthMode: editor.authMode,
                        draftHeaders: editor.headers,
                        draftQueryParams: editor.queryParams
                    ),
                    onSelect: { applySecurityMode($0, provider: provider) }
                )
            }
        }
        .alert(L10n.tr("Discard unsaved changes?", table: .providers), isPresented: $showDiscardAlert) {
            Button(L10n.tr("Discard"), role: .destructive) { abandonAndDismiss() }
            Button(L10n.tr("Keep editing", table: .providers), role: .cancel) {}
        } message: {
            Text(L10n.tr(RelayEditBoardModel.discardMessageKey, table: .providers))
        }
        .interactiveDismissDisabled(shouldDisableInteractiveDismiss)
    }

    // MARK: - Header

    /// A hand-drawn header instead of the system navigation bar: close at top-left, centered title, connection name as subtitle.
    /// A sheet without a navigation bar gets 24pt of top padding, otherwise the title would sit against the sheet's top edge.
    private var header: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(L10n.tr(RelayEditBoardModel.titleKey, table: .providers))
                    .font(OriveoTheme.Typography.title3)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                if let name = provider?.displayName, !name.isEmpty {
                    Text(name)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            // Leave room for the close button at the top-left so the title stays visually centered.
            .padding(.horizontal, 52)

            HStack {
                Button { attemptClose() } label: {
                    PhosphorIcon.x.image(.regular)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                                .fill(OriveoTheme.Palette.surfaceElevated)
                        )
                        // Drawn at 36pt; the tappable area is padded out to 44pt.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Close"))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.xl - 4)
        .padding(.top, 24)
        .padding(.bottom, OriveoTheme.Spacing.sm)
    }

    /// Try to close: with unsaved edits, show the Discard alert first; otherwise dismiss directly
    private func attemptClose() {
        if let editor, let original, editor != original {
            showDiscardAlert = true
        } else {
            abandonAndDismiss()
        }
    }

    /// Closing the page abandons any in-flight save validation: invalidate this generation so a late result neither persists nor shows a stale failure card.
    private func abandonAndDismiss() {
        saveGeneration &+= 1
        dismiss()
    }

    private var shouldDisableInteractiveDismiss: Bool {
        guard let editor, let original else { return false }
        return editor != original
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for provider: Provider, editor: Editor) -> some View {
        let issues = formIssues(for: provider, editor: editor)
        let board = RelayEditBoardModel.make(
            provider: provider,
            editor: editor,
            status: status,
            isSaving: isSaving,
            hasFormIssues: !issues.isEmpty,
            issues: issues,
            shownCompatibilityRows: shownCompatibilityRows,
            baseline: original
        )
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                RelayEditBoardView(
                    groups: board.groups,
                    endpoint: endpointBinding,
                    transport: bindingForEditor(\.transport),
                    authMode: bindingForEditor(\.authMode),
                    customUserAgent: bindingForEditor(\.customUserAgent),
                    headers: bindingForEditor(\.headers),
                    queryParams: bindingForEditor(\.queryParams),
                    serviceTier: bindingForEditor(\.serviceTier),
                    stream: streamBinding,
                    disableResponseStorage: bindingForEditor(\.disableResponseStorage),
                    securityMode: editor.securityMode,
                    // Local engines offer their channel set; every other connection offers the full protocol set.
                    transportOptions: LocalEngineChannelCandidates.transportOptions(
                        engineProfile: provider.relayRequested?.engineProfile
                    ),
                    // Shares one validation and one hint component with the add page, measured against this connection's own securityMode.
                    // The header and query-parameter rows already live inside the header group; only the ones under the connection card remain here.
                    issues: board.connectionIssues,
                    isBusy: isSaving,
                    endpointHighlightToken: endpointNormalizationHighlightToken,
                    onChangeSecurityMode: { showSecurityModePicker = true }
                )

                // In-flight and result states for connection tests and reconnects both sit at the end of the content, in the same status-row style.
                if let status {
                    let row = RelayEditBoardModel.statusRow(status)
                    RelaySetupStatusRow(
                        message: RelayEditBoardModel.string(row.message),
                        // This page does not use SF Symbols: the row model supplies Phosphor icons; the shared component's parameter stays empty.
                        systemImage: "",
                        phosphorIcon: row.icon,
                        tone: row.tone,
                        showsProgress: row.showsProgress
                    )
                    .id(RelayFailureCardReveal.statusAnchorID)
                }

                // A failed validation shows only this failure card: reason, technical details and "Save anyway (unverified)"; no separate confirmation dialog.
                if let saveError {
                    OriveoErrorCard(error: saveError) {
                        if pendingUnverifiedSave != nil {
                            saveUnverifiedRelay()
                        } else {
                            self.saveError = nil
                        }
                    }
                    .id(RelayFailureCardReveal.anchorID)
                }
            }
            .padding(.horizontal, OriveoTheme.Spacing.xl)
            .padding(.top, OriveoTheme.Spacing.sm)
            .padding(.bottom, OriveoTheme.Spacing.xxl)
        }
        .safeAreaInset(edge: .bottom) {
            actionBar(board.actionBar, provider: provider)
        }
        // The failure card sits at the end of the content: when it appears, dismiss the keyboard and scroll to it, otherwise it lands off-screen while the keyboard is open.
        .onChange(of: saveError?.id) { previous, current in
            RelayFailureCardReveal.revealIfNeeded(previous: previous, current: current, proxy: proxy)
        }
        .onChange(of: RelayEditBoardModel.draftCompatibilityRows(editor), initial: true) { _, shown in
            shownCompatibilityRows.formUnion(shown)
        }
        // The test/reconnect row also sits at the end of the content and follows the same approach when it first appears;
        // when an in-flight entry is replaced by its result in place, keep the keyboard, since the user may be typing in another field.
        .onChange(of: status) { previous, current in
            guard RelayEditBoardModel.revealsStatusRow(previous: previous, current: current) else { return }
            RelayFailureCardReveal.revealIfNeeded(
                previous: previous,
                current: current,
                anchor: RelayFailureCardReveal.statusAnchorID,
                proxy: proxy
            )
        }
        }
    }

    // MARK: - Test Connection Row

    @MainActor
    private func runTestConnection(provider: Provider) async {
        guard !isTestingConnection else { return }
        let trimmedEndpoint = (editor?.endpoint ?? provider.baseURLText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty else {
            status = .failed(L10n.tr("Enter a request URL.", table: .providers))
            return
        }
        // Validate against the connection's own securityMode: local engines use http://, and measuring them as remote_https would always report invalid
        let securityMode = editor?.securityMode ?? provider.relayRequested?.securityMode ?? .remoteHTTPS
        guard let writeback = RelaySecurityModeSelection.endpointWriteback(
            trimmedEndpoint,
            securityMode: securityMode
        ) else {
            status = .failed(L10n.tr(RelayEndpointPolicy.httpsRequiredMessageKey, table: .providers))
            return
        }
        if writeback.didChange {
            endpointBinding.wrappedValue = writeback.endpoint
            endpointNormalizationHighlightToken &+= 1
        }

        status = .testing

        // Pack the editor's current fields (transport / codexCompatIdentity / customUserAgent / headers)
        // into a temporary RelayRequestedConfig and send them together, so edits can be verified without saving first
        let requested = makeProbeRequested()
        var candidate = provider
        candidate.baseURLText = writeback.endpoint
        candidate.relayRequested = requested
        candidate.relayKind = editor.map { RelayEditSavePolicy.savedRelayKind(editor: $0) } ?? provider.relayKind
        let persistsResult = RelayConnectionPersistenceComparator.matches(
            provider: provider,
            candidateEndpoint: writeback.endpoint,
            candidateRequested: requested
        )

        do {
            // When the result is persisted, also record the status of the key that was actually sent.
            try await appState.providerManager.verifyRelayGenerationRecordingKeyStatus(
                candidate, providerID: provider.id, persists: persistsResult
            )
            if persistsResult {
                appState.providerManager.recordRelayGenerationVerification(providerID: provider.id, verified: true)
            }
            status = .verified
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
            status = .failed(message)
        }
    }

    /// Pack the editor's current fields into a RelayRequestedConfig so the connection test uses the latest (unsaved) settings.
    /// Fields this page does not edit (Codex identity, image parameters, local-engine markers, etc.) are taken as stored, the same way the save path does it.
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
            // The security boundary and the local-engine markers are not editor fields, but the probe must carry them unchanged;
            // without them a local engine's http address would be judged a plaintext violation by the security layer and could never connect.
            securityMode: editor.securityMode,
            modelID: editor.modelID.isEmpty ? nil : editor.modelID,
            // The connection-level reasoning effort has been retired: outbound requests do not read it, so the probe does not carry it either.
            reasoningEffort: nil,
            serviceTier: editor.serviceTier.isEmpty ? nil : editor.serviceTier,
            stream: false,
            disableResponseStorage: editor.disableResponseStorage ? true : nil,
            headers: cleanedHeaders.isEmpty ? nil : cleanedHeaders,
            queryParams: cleanedQueries.isEmpty ? nil : cleanedQueries,
            codexCompatIdentity: existingRequested?.codexCompatIdentity,
            customUserAgent: trimmedUA.isEmpty ? nil : trimmedUA,
            imageSize: existingRequested?.imageSize,
            imageQuality: existingRequested?.imageQuality,
            imageStyle: existingRequested?.imageStyle,
            imageCount: existingRequested?.imageCount,
            imageResponseFormat: existingRequested?.imageResponseFormat,
            // The UI no longer edits this: it is only used by the legacy-field read-time mapping, so it is passed through unchanged on save.
            webSearchToolName: existingRequested?.webSearchToolName,
            transportKind: existingRequested?.transportKind,
            resolvedAPIBaseURL: Self.resolvedAPIBaseURL(
                for: editor.endpoint,
                provider: provider,
                securityMode: editor.securityMode
            ),
            resolvedAPIBaseURLs: Self.resolvedAPIBaseURLs(
                for: editor.endpoint,
                provider: provider,
                securityMode: editor.securityMode
            ),
            engineProfile: existingRequested?.engineProfile,
            certificateFingerprint: existingRequested?.certificateFingerprint
        ).carryingLegacyWebSearch(from: existingRequested)
    }

    // MARK: - Connection type transition

    /// The connection mode is not a display-only field: once the user confirms, the old routing/catalog conclusions are invalidated immediately,
    /// and the connection is re-established in the order "resolve API root -> 1-token validation -> refresh catalog".
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
            storedAPIKey: provider.apiKey, // key-choke: stored-field loads the saved key into the edit form to judge credential material; it does not fetch a key for any model
            draftAuthMode: nextEditor.authMode,
            draftHeaders: nextEditor.headers,
            draftQueryParams: nextEditor.queryParams,
            nextMode: nextMode
        )
        if nextMode == .localHTTP || nextMode == .privateVPN {
            nextEditor.authMode = .none
            if transition.clearsCredentialTables {
                // The confirmation clears the whole custom table, so no separate "headers to keep" list is maintained here.
                nextEditor.headers = []
                nextEditor.queryParams = []
            }
        }

        let endpointForNextMode: String
        if nextMode == .remoteHTTPS,
           nextEditor.endpoint.lowercased().hasPrefix("http://") {
            // The user explicitly chose "Public HTTPS", so upgrading the scheme is a direct result of that deliberate action,
            // not an automatic rewrite by the classifier.
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
        var persistedBaseline = original ?? Editor(from: provider, lastUsedModelRef: appState.lastUsedModelRef)
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
        // A chosen connection security is persisted and reconnected immediately; a reconnect in flight is "in progress", not a failure.
        status = .reconnecting

        var transitioning = provider
        transitioning.baseURLText = normalizedEndpoint
        if transition.clearsStoredAPIKey {
            transitioning.apiKey = ""
            transitioning.apiKeyPreview = APIKeyMask.masked("")
        }
        transitioning.relayRequested = transition.requested
        // Switching the security mode changes the connection identity, so the old endpoint's catalog must not keep being shown.
        // Keep the enabled models; after success the generation + catalog-only flow fills in the new catalog.
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
              let current = appState.providerManager.provider(for: providerID),
              let requested = current.relayRequested,
              let endpoint = current.baseURLText else {
            // The connection is gone or has no address: this generation will never produce a result, so stop the progress indicator.
            if generation == reconnectGeneration, status == .reconnecting { status = nil }
            return
        }
        let expectedMode = requested.securityMode
        status = .reconnecting
        defer {
            if generation == reconnectGeneration {
                // A cancelled run, or one superseded by a newer generation, reaches neither the success nor the failure branch; stop the progress indicator.
                if status == .reconnecting { status = nil }
                reconnectTask = nil
            }
        }

        do {
            // Catalog probing also yields the measured API root. When the mode switches, the old resolvedAPIBaseURL is cleared right away,
            // and the old route must not be reused to prove that the new mode works.
            // The probe hint uses the validation sample; the stored relayRequested.modelID is not read.
            let reconnectModelHint = appState.providerManager.relayVerificationSampleModelID(for: current)
            let discovery = try await RelayDiscoveryService().discover(
                endpoint: endpoint,
                apiKey: ProviderCredentialResolver.apiKey(provider: current, modelID: reconnectModelHint),
                modelHint: reconnectModelHint,
                securityMode: requested.securityMode
            )
            try Task.checkCancellation()
            guard canPersistReconnect(
                providerID: providerID,
                generation: generation,
                expectedMode: expectedMode
            ) else { return }
            // Re-fetch the stored connection before writing back: `current` is a snapshot from before the probe, which crossed an await,
            // and writing it back wholesale would overwrite changes persisted in the meantime.
            if let latest = appState.providerManager.provider(for: providerID),
               let detected = discovery.detections.first(where: { $0.transport == latest.relayRequested?.transport })
                ?? discovery.detections.first,
               let written = RelayEditSavePolicy.recordingDiscoveredRoot(
                   detected.apiBaseURL,
                   discovered: detected.transport,
                   onto: latest
               ) {
                appState.providerManager.updateProvider(written)
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
            status = .verified
        } catch is CancellationError {
            restoreIssueIfLatestReconnectIsStillPending(providerID: providerID, expectedGeneration: generation)
        } catch {
            guard generation == reconnectGeneration else {
                return
            }
            // status/lastError persist only ProviderServiceError.messageKey; the upstream body, URL and
            // localizedDescription are for diagnostics only and must never be written into synced state.
            appState.providerManager.recordRelayGenerationVerification(
                providerID: providerID,
                verified: false,
                error: error
            )
            let message = (error as? ProviderServiceError)?.message
                ?? L10n.tr("We couldn't verify the connection. You can retry from the provider details.")
            status = .failed(message)
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

    // MARK: - Bottom action bar

    /// The secondary "Test connection" button acts in place (no arrow); the primary button switches between "Save" and "Verify and save" according to the save classification.
    /// Whether each button is tappable comes from the row model (save / test / reconnect in flight, form validation).
    private func actionBar(_ bar: RelayEditBoardModel.ActionBar, provider: Provider) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(height: 0.6)
            HStack(spacing: OriveoTheme.Spacing.md) {
                Button(L10n.tr(bar.secondaryKey, table: .providers)) {
                    Task { await runTestConnection(provider: provider) }
                }
                .buttonStyle(OriveoSecondaryButtonStyle())
                .disabled(!bar.isSecondaryEnabled)
                .opacity(bar.isSecondaryEnabled ? 1 : 0.55)

                Button(
                    isSaving
                        ? L10n.tr("Saving...", table: .providers)
                        : L10n.tr(bar.primary.titleKey, table: bar.primary.titleTable)
                ) {
                    Task { await save(provider: provider) }
                }
                .buttonStyle(OriveoPrimaryButtonStyle())
                .disabled(!bar.isPrimaryEnabled)
                .opacity(bar.isPrimaryEnabled ? 1 : 0.55)
            }
            .padding(.horizontal, OriveoTheme.Spacing.xl)
            .padding(.top, OriveoTheme.Spacing.md)
            .padding(.bottom, OriveoTheme.Spacing.lg)
        }
        // ultraThinMaterial puts extra GPU pressure on real devices while scrolling, so a solid color is steadier; surfaceChrome has alpha, so pad with the opaque page color to stop text showing through
        .background(OriveoTheme.Palette.surfaceChrome)
        .background(OriveoTheme.Palette.background)
    }

    // MARK: - Derived values

    /// The form validation outcome for this page (the page and the structure tests use the same function).
    static func formIssues(for provider: Provider, editor: Editor) -> [RelayFormValidation.FieldIssue] {
        RelayFormValidation.validate(formDraft(for: provider, editor: editor), mode: .edit)
    }

    /// The form draft the editor state condenses into. Validation must measure against this connection's own securityMode,
    /// otherwise a local engine's http:// address could never be saved.
    private static func formDraft(for provider: Provider, editor: Editor) -> RelayFormDraft {
        var draft = RelayFormDraft(
            requested: provider.relayRequested,
            endpoint: editor.endpoint,
            hasSavedCredential: RelayCredentialPolicy.hasStoredKey(ProviderCredentialResolver.apiKey(provider: provider, modelID: nil))
        )
        // The user may just have changed protocol/auth/headers on this page; the draft follows the editor and is validated against the new values before persisting.
        draft.transport = editor.transport
        draft.authMode = editor.authMode
        draft.securityMode = editor.securityMode
        draft.modelID = editor.modelID
        draft.headers = editor.headers
        draft.queryParams = editor.queryParams
        return draft
    }

    private func formIssues(for provider: Provider, editor: Editor) -> [RelayFormValidation.FieldIssue] {
        Self.formIssues(for: provider, editor: editor)
    }

    // MARK: - Initialization & bindings

    private func initializeEditorIfNeeded() {
        guard editor == nil, let provider else { return }
        let e = Editor(from: provider, lastUsedModelRef: appState.lastUsedModelRef)
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
                status = nil
            }
        )
    }

    /// Binding dedicated to stream: its setter also marks `streamTouched`, so a stream that was nil is not accidentally saved as true
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

    // MARK: - Save

    @MainActor
    private func save(provider: Provider) async {
        // The local is not named `editor`: that would shadow the state property, and the "did the draft change" check after validation returns would compare the value with itself.
        guard let draft = editor, status != .reconnecting else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let trimmedEndpoint = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)

        // KV tables: drop rows with an empty key so invalid entries are not persisted
        let cleanedHeaders = draft.headers
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let cleanedQueries = draft.queryParams
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Editing must validate the address against the connection's own securityMode: validating a local engine's http:// address as remote_https
        // would report "invalid request address", and the local engine could not save anything.
        let securityMode = draft.securityMode
        let hasStoredKey = RelayCredentialPolicy.hasStoredKey(ProviderCredentialResolver.apiKey(provider: provider, modelID: nil))
        // Interlock on save: plaintext mode combined with any credential material is rejected here, rather than saved and then hard-refused on every send.
        // This shares the credentials-aware requireConfigured overload of RelayEndpointPolicy with the send path.
        let normalizedEndpoint: String
        do {
            normalizedEndpoint = try RelayEndpointPolicy.requireConfigured(
                trimmedEndpoint,
                securityMode: securityMode,
                credentials: RelayCredentialPolicy.endpointCredentials(
                    for: RelayRequestedConfig(
                        transport: draft.transport,
                        authMode: draft.authMode,
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
        if normalizedEndpoint != draft.endpoint {
            endpointBinding.wrappedValue = normalizedEndpoint
            endpointNormalizationHighlightToken &+= 1
        }
        // The normalized address was written back to the UI above: from here on, "the draft of this save" always means the normalized one,
        // and both the snapshot and the unsaved baseline use it; otherwise "Save anyway" would fail to match the snapshot for a connection whose address had a scheme added.
        let normalizedDraft = RelayEditSavePolicy.normalizedDraft(draft, normalizedEndpoint: normalizedEndpoint)

        // Entity + configuration generation guard: an old probe may never commit
        // after the editor has changed again or the provider instance disappeared.
        saveGeneration &+= 1
        let generation = saveGeneration
        let capturedEditor = normalizedDraft
        // Baseline = the record as it was when the page opened (it moves forward after a connection-security switch persists); persisting uses the live record plus the fields changed on this page.
        let baseline = original ?? Editor(from: provider, lastUsedModelRef: appState.lastUsedModelRef)
        // The last validation's verdict for the key that was actually sent: written on persist (a pass is inside run; a failure waits for "Save anyway").
        var keyStatus: RelayKeyStatusObservation?
        let outcome = await RelayEditSaveCommit.run(
            draft: normalizedDraft,
            baseline: baseline,
            normalizedEndpoint: normalizedEndpoint,
            live: { appState.provider(for: providerID) },
            verify: { candidate in
                keyStatus = nil
                try await appState.providerManager.verifyRelayGeneration(candidate) { keyStatus = $0 }
            },
            isCurrent: { verificationResultIsCurrent(generation: generation, snapshot: capturedEditor) },
            persist: { appState.providerManager.updateProvider($0) },
            applyKeyStatus: { ProviderManager.applyRelayKeyStatusObservation(keyStatus, to: &$0) }
        )
        switch outcome {
        case .persisted(_, let refreshesCatalog):
            original = normalizedDraft
            // Name/UA/headers/query and display-only fields are local
            // configuration.  They save without a probe or catalog refresh.
            // Whether to refresh the catalog is decided at persist time, from the merged value against the live record.
            guard refreshesCatalog else {
                await Task.yield()
                dismiss()
                return
            }
            // The 1-token generation validation already succeeded; even if the later catalog refresh fails, this
            // verified connection must not be written back as "unverified". The catalog state is expressed separately by refreshRelayCatalog.
            dismiss()
            Task { @MainActor in
                _ = await appState.providerManager.refreshRelayCatalog(providerID: provider.id)
            }
        case .verificationFailed(let error, let candidate):
            // The user explicitly decides whether an unverified connection is saved.
            // Until they do, the last verified provider remains untouched.
            pendingUnverifiedSave = RelayEditSavePolicy.unverifiedCandidate(
                candidate, base: provider, draft: capturedEditor, baseline: baseline
            )
            pendingUnverifiedSave?.keyStatus = keyStatus
            // Show only the failure card (reason + technical details + "Save anyway (unverified)"); no separate confirmation dialog.
            saveError = RelayEditFailurePresentation.error(
                from: error,
                provider: candidate
            )
        case .discarded:
            return
        }
    }

    /// Whether an in-flight validation may still touch the UI and the store after it returns: it must be the latest save, the draft unchanged, and the connection still present.
    private func verificationResultIsCurrent(generation: Int, snapshot: Editor) -> Bool {
        RelayEditVerificationCommitPolicy.mayCommit(
            generation: generation,
            currentGeneration: saveGeneration,
            snapshot: snapshot,
            currentEditor: editor,
            currentProviderID: appState.provider(for: providerID)?.id,
            targetProviderID: providerID
        )
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
        // While the failure card stayed up, the connection may have been changed elsewhere: merge by field into the current record as well.
        var refreshesCatalog = true
        if let baseline = pendingUnverifiedSave.editorBaseline, let live = provider {
            let commit = RelayEditSaveCommit.unverified(
                draft: pendingUnverifiedSave.editorSnapshot,
                baseline: baseline,
                normalizedEndpoint: pendingUnverifiedSave.editorSnapshot.endpoint,
                onto: live
            )
            var written = commit.provider
            ProviderManager.applyRelayKeyStatusObservation(pendingUnverifiedSave.keyStatus, to: &written)
            appState.providerManager.updateProvider(written)
            refreshesCatalog = commit.refreshesCatalog
        } else {
            var written = RelayEditSavePolicy.mergingLiveSecrets(
                pendingUnverifiedSave.provider, base: pendingUnverifiedSave.secretBaseline, live: provider
            )
            ProviderManager.applyRelayKeyStatusObservation(pendingUnverifiedSave.keyStatus, to: &written)
            appState.providerManager.updateProvider(written)
        }
        // After the user explicitly saves a new connection unverified, the old catalog no longer belongs to this connection: refetch the catalog in the background,
        // and never run the generation validation, which would spend a key. Whether to clear and whether to fetch is decided at persist time, from the merged value against the live record.
        if refreshesCatalog {
            Task { @MainActor in
                _ = await appState.providerManager.refreshRelayCatalog(
                    providerID: pendingUnverifiedSave.provider.id
                )
            }
        }
        original = editor
        clearPendingUnverifiedSave()
        dismiss()
    }

    private func clearPendingUnverifiedSave() {
        pendingUnverifiedSave = nil
        saveError = nil
    }

    static func resolvedAPIBaseURL(
        for endpoint: String,
        provider: Provider?,
        securityMode: RelayConnectionSecurityMode
    ) -> String? {
        guard endpointUnchanged(endpoint, provider: provider, securityMode: securityMode) else { return nil }
        return provider?.relayRequested?.resolvedAPIBaseURL
    }

    /// The per-protocol root table follows the same retention rule as the single-value root: keep it only if the address is unchanged, otherwise invalidate it (probe results hold only for the old address).
    static func resolvedAPIBaseURLs(
        for endpoint: String,
        provider: Provider?,
        securityMode: RelayConnectionSecurityMode
    ) -> [String: String]? {
        guard endpointUnchanged(endpoint, provider: provider, securityMode: securityMode) else { return nil }
        return provider?.relayRequested?.resolvedAPIBaseURLs
    }

    /// Uses the same normalization as "did the address change" in the save classification (`RelayEditSavePolicy.normalizedEndpoint`). The structure-unaware
    /// `normalize` does not recognize host names in local mode (localhost / *.local), so every save would be judged "changed" and clear the root address.
    private static func endpointUnchanged(
        _ endpoint: String,
        provider: Provider?,
        securityMode: RelayConnectionSecurityMode
    ) -> Bool {
        guard let provider,
              let normalizedNew = RelayEditSavePolicy.normalizedEndpoint(endpoint, securityMode: securityMode),
              let normalizedOld = RelayEditSavePolicy.normalizedEndpoint(
                  provider.baseURLText ?? "",
                  securityMode: securityMode
              ) else { return false }
        return normalizedNew == normalizedOld
    }

    /// Gives a human-readable sentence when a save is rejected. `RelayEndpointPolicy` throws machine-readable reason slugs;
    /// only the plaintext-with-credentials case needs to point at "this connection is not encrypted", and everything else falls back to the HTTPS explanation.
    private func relaySaveBlockMessage(for error: Error) -> String {
        guard case ProviderServiceError.invalidConfiguration(let reason) = error,
              reason == "cleartext_credentials" else {
            return L10n.tr(RelayEndpointPolicy.httpsRequiredMessageKey, table: .providers)
        }
        return L10n.tr("An unencrypted connection can't carry a key.", table: .providers)
    }

    // MARK: - Editor state

    /// Fields editable on this page. Name, keys, Codex identity, web search, image parameters and the connection-level reasoning effort are not here:
    /// on save they are taken as stored (the reasoning effort is always cleared).
    struct Editor: Equatable {
        var endpoint: String
        /// The validation sample used by connection tests; not persisted.
        var modelID: String
        var transport: RelayTransport
        var authMode: RelayAuthMode
        var securityMode: RelayConnectionSecurityMode
        var serviceTier: String
        var stream: Bool
        /// Marks whether the user actively touched stream, which decides on save whether to write it back to the provider.
        /// This keeps a nil state from being pinned to the UI's default of true
        var streamTouched: Bool
        var disableResponseStorage: Bool
        var customUserAgent: String
        var headers: [RelayKeyValue]
        var queryParams: [RelayKeyValue]

        static let empty = Editor(
            endpoint: "",
            modelID: "",
            transport: .auto,
            authMode: .auto,
            securityMode: .remoteHTTPS,
            serviceTier: "",
            stream: true,
            streamTouched: false,
            disableResponseStorage: false,
            customUserAgent: "",
            headers: [],
            queryParams: []
        )

        init(
            endpoint: String,
            modelID: String,
            transport: RelayTransport,
            authMode: RelayAuthMode,
            securityMode: RelayConnectionSecurityMode,
            serviceTier: String,
            stream: Bool,
            streamTouched: Bool,
            disableResponseStorage: Bool,
            customUserAgent: String,
            headers: [RelayKeyValue],
            queryParams: [RelayKeyValue]
        ) {
            self.endpoint = endpoint
            self.modelID = modelID
            self.transport = transport
            self.authMode = authMode
            self.securityMode = securityMode
            self.serviceTier = serviceTier
            self.stream = stream
            self.streamTouched = streamTouched
            self.disableResponseStorage = disableResponseStorage
            self.customUserAgent = customUserAgent
            self.headers = headers
            self.queryParams = queryParams
        }

        init(from provider: Provider, lastUsedModelRef: LastUsedModelRef? = nil) {
            let req = provider.relayRequested
            self.endpoint = provider.baseURLText ?? ""
            // Relays have no default model: this is only the validation sample for connection tests and is not persisted; the stored relayRequested.modelID is not read.
            self.modelID = ProviderSelectionSnapshot.relayVerificationSampleModelID(
                in: provider,
                lastUsedModelRef: lastUsedModelRef
            ) ?? ""
            // Read the protocol as stored: auto stays auto, and it is written back only if the user changed it on this page.
            self.transport = req?.transport ?? .auto
            self.authMode = req?.authMode ?? .auto
            self.securityMode = req?.securityMode ?? .remoteHTTPS
            self.serviceTier = req?.serviceTier ?? ""
            self.stream = req?.stream ?? true
            // Only a stream that the provider already set explicitly counts as "touched"; nil means untouched and is not written back on save
            self.streamTouched = req?.stream != nil
            self.disableResponseStorage = req?.disableResponseStorage ?? false
            self.customUserAgent = req?.customUserAgent ?? ""
            self.headers = req?.headers ?? []
            self.queryParams = req?.queryParams ?? []
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

/// The 1-token result may be written back to provider.status only while the tested request config still equals the saved connection.
/// It compares the connection-semantic fields editable on this page; relayKind is a display value derived from the protocol and the connection-level reasoning effort is retired,
/// so neither counts as connection identity (otherwise an existing connection with no edits would be judged a "draft").
enum RelayConnectionPersistenceComparator {
    static func matches(
        provider: Provider,
        candidateEndpoint: String,
        candidateRequested: RelayRequestedConfig
    ) -> Bool {
        guard provider.kind == .relay,
              normalizedEndpoint(provider.baseURLText) == normalizedEndpoint(candidateEndpoint),
              let persisted = provider.relayRequested else { return false }
        // `makeProbeRequested()` fixes stream=false so the 1-token validation response can be read completely;
        // that is how the probe runs, not a saved user setting, so it must not block writing back the old connection's status.
        return persisted.transport == candidateRequested.transport
            && persisted.authMode == candidateRequested.authMode
            && persisted.securityMode == candidateRequested.securityMode
            && persisted.serviceTier == candidateRequested.serviceTier
            && persisted.disableResponseStorage == candidateRequested.disableResponseStorage
            && (persisted.headers ?? []) == (candidateRequested.headers ?? [])
            && (persisted.queryParams ?? []) == (candidateRequested.queryParams ?? [])
            && persisted.customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
                == candidateRequested.customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
            && persisted.webSearchToolName == candidateRequested.webSearchToolName
            && persisted.codexCompatIdentity == candidateRequested.codexCompatIdentity
    }

    private static func normalizedEndpoint(_ endpoint: String?) -> String? {
        endpoint?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// The single criterion for save classification. Only fields that change real connection semantics (address / default protocol / auth mode) spend
/// the 1-token validation; other edits only save local configuration. Connection security does not go through here: it persists and reconnects as soon as it is chosen.
enum RelayEditSavePolicy {
    /// Persist after validation crosses an await: key fields the editor did not change take the live stored value, and changed ones take the draft value.
    /// Otherwise a key replaced on the keys page during validation would be overwritten by the snapshot from the moment Save was tapped, and the write site would misread this write-back as a key change on this page.
    static func mergingLiveSecrets(_ candidate: Provider, base: Provider, live: Provider?) -> Provider {
        guard let live, live.id == candidate.id else { return candidate }
        var merged = candidate
        if candidate.apiKey == base.apiKey {
            merged.apiKey = live.apiKey
            merged.apiKeyPreview = live.apiKeyPreview
        }
        if candidate.relayKeys == base.relayKeys {
            merged.relayKeys = live.relayKeys
        } else if let keys = candidate.relayKeys {
            merged.relayKeys = keys.map { key in
                guard let baseKey = base.relayKeys?.first(where: { $0.id == key.id }), baseKey.apiKey == key.apiKey,
                      let liveKey = live.relayKeys?.first(where: { $0.id == key.id }) else { return key }
                var updated = key
                updated.apiKey = liveKey.apiKey
                return updated
            }
        }
        return merged
    }

    /// Validation-relevant fields: normalized address, protocol, auth mode, connection security, keys, headers, query parameters, User-Agent.
    struct VerificationInputs: Equatable {
        let endpoint: String
        let transport: RelayTransport?
        let authMode: RelayAuthMode?
        let securityMode: RelayConnectionSecurityMode?
        let apiKey: String
        let relayKeySecrets: [String: String]
        let headers: [RelayKeyValue]
        let queryParams: [RelayKeyValue]
        let customUserAgent: String
    }

    static func verificationInputs(of provider: Provider) -> VerificationInputs {
        let requested = provider.relayRequested
        let mode = requested?.securityMode ?? .remoteHTTPS
        return VerificationInputs(
            endpoint: comparableEndpoint(provider.baseURLText ?? "", securityMode: mode),
            transport: requested?.transport,
            authMode: requested?.authMode,
            securityMode: requested?.securityMode,
            apiKey: provider.apiKey,
            // Compare only the values of non-primary keys: the primary key's value is already in `apiKey`, and a status change or materializing a single key into a list does not count as a change.
            relayKeySecrets: Dictionary(
                (provider.relayKeys ?? []).dropFirst().map { ($0.id, $0.apiKey) },
                uniquingKeysWith: { first, _ in first }
            ),
            headers: requested?.headers ?? [],
            queryParams: requested?.queryParams ?? [],
            customUserAgent: requested?.customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    /// Persist candidate: start from the record as it is now, and overlay only the form fields the draft changed relative to the baseline from when the page opened;
    /// anything the user did not change takes the live value, and when both sides changed the same field the user wins. This page does not edit keys, so keys always take the live value.
    static func mergedCandidate(
        draft: RelayEditView.Editor,
        baseline: RelayEditView.Editor,
        normalizedEndpoint: String,
        onto live: Provider
    ) -> Provider {
        let editor = mergedEditor(draft: draft, baseline: baseline, endpoint: normalizedEndpoint, onto: live)
        let endpoint = endpointEdited(draft: draft, baseline: baseline) ? normalizedEndpoint : (live.baseURLText ?? "")
        var merged = live
        merged.baseURLText = endpoint
        merged.relayRequested = savedRequested(editor: editor, provider: live, normalizedEndpoint: endpoint)
        // There is no type layer: relayKind is only a display value derived from the default protocol.
        merged.relayKind = savedRelayKind(editor: editor)
        return invalidatingCatalogIfConnectionChanged(merged, from: live, editor: editor)
    }

    /// Primary button and save classification: judged against the live record using "live record + fields changed on this page";
    /// only a field the user changed and that differs from the live value counts; fields the user did not change but were changed elsewhere do not trigger validation.
    static func primaryAction(
        live: Provider,
        draft: RelayEditView.Editor,
        baseline: RelayEditView.Editor
    ) -> RelayEditPrimaryAction {
        primaryAction(from: live, editor: mergedEditor(draft: draft, baseline: baseline, endpoint: draft.endpoint, onto: live))
    }

    private static func endpointEdited(draft: RelayEditView.Editor, baseline: RelayEditView.Editor) -> Bool {
        comparableEndpoint(draft.endpoint, securityMode: draft.securityMode)
            != comparableEndpoint(baseline.endpoint, securityMode: draft.securityMode)
    }

    /// The editor view of the live record with this page's changed fields overlaid; `endpoint` is the value written in when the user changed the address.
    private static func mergedEditor(
        draft: RelayEditView.Editor,
        baseline: RelayEditView.Editor,
        endpoint: String,
        onto live: Provider
    ) -> RelayEditView.Editor {
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func cleaned(_ rows: [RelayKeyValue]) -> [RelayKeyValue] { rows.filter { !trimmed($0.key).isEmpty } }

        var editor = RelayEditView.Editor(from: live)
        if endpointEdited(draft: draft, baseline: baseline) { editor.endpoint = endpoint }
        if draft.transport != baseline.transport { editor.transport = draft.transport }
        if draft.authMode != baseline.authMode { editor.authMode = draft.authMode }
        if draft.securityMode != baseline.securityMode { editor.securityMode = draft.securityMode }
        if trimmed(draft.serviceTier) != trimmed(baseline.serviceTier) { editor.serviceTier = draft.serviceTier }
        if draft.stream != baseline.stream {
            editor.stream = draft.stream
            editor.streamTouched = true
        }
        if draft.disableResponseStorage != baseline.disableResponseStorage {
            editor.disableResponseStorage = draft.disableResponseStorage
        }
        if trimmed(draft.customUserAgent) != trimmed(baseline.customUserAgent) {
            editor.customUserAgent = draft.customUserAgent
        }
        if cleaned(draft.headers) != cleaned(baseline.headers) { editor.headers = draft.headers }
        if cleaned(draft.queryParams) != cleaned(baseline.queryParams) { editor.queryParams = draft.queryParams }
        return editor
    }

    static func primaryAction(from provider: Provider, editor: RelayEditView.Editor) -> RelayEditPrimaryAction {
        endpointChanged(from: provider, editor: editor)
            || provider.relayRequested?.transport != editor.transport
            || provider.relayRequested?.authMode != editor.authMode
            ? .validateAndSave
            : .save
    }

    /// Whether the address changed is compared on normalized values on both sides. The primary button asks with the raw text from the UI and the save path asks with the
    /// normalized draft, and the answers must agree: otherwise a missing scheme would make the button say "Verify and save" while no validation is sent,
    /// and a stored address with a trailing slash would make the button say "Save" while a validation is sent.
    static func endpointChanged(from provider: Provider, editor: RelayEditView.Editor) -> Bool {
        comparableEndpoint(provider.baseURLText ?? "", securityMode: editor.securityMode)
            != comparableEndpoint(editor.endpoint, securityMode: editor.securityMode)
    }

    /// The normalized address: the same function as the save path, without credentials (credentials decide only whether it can be stored, not the normalized result).
    /// nil when it cannot become a valid address.
    static func normalizedEndpoint(_ raw: String, securityMode: RelayConnectionSecurityMode) -> String? {
        try? RelayEndpointPolicy.requireConfigured(
            raw.trimmingCharacters(in: .whitespacesAndNewlines),
            securityMode: securityMode
        )
    }

    /// When it cannot become a valid address, fall back to the original text with surrounding whitespace trimmed; such a draft could not be saved anyway.
    private static func comparableEndpoint(_ raw: String, securityMode: RelayConnectionSecurityMode) -> String {
        normalizedEndpoint(raw, securityMode: securityMode) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The relayKind written back on save: no longer a user option, derived from the default protocol.
    /// auto -> `.custom`; transport stays auto and is not pinned to Chat.
    static func savedRelayKind(editor: RelayEditView.Editor) -> RelayKind {
        RelayKind(transport: editor.transport)
    }

    /// The request config written back when the edit page saves (the data side of the save path). Apart from the fields the user changed on this page,
    /// stored values are carried over unchanged (engineProfile / certificateFingerprint / Codex identity / image parameters, etc.);
    /// the only thing actively cleared is the connection-level reasoning effort.
    static func savedRequested(
        editor: RelayEditView.Editor,
        provider: Provider,
        normalizedEndpoint: String
    ) -> RelayRequestedConfig {
        let trimmedServiceTier = editor.serviceTier.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedHeaders = editor.headers
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let cleanedQueries = editor.queryParams
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Stream save policy: if the user touched it, write back the user's value; otherwise keep the provider's original stream (possibly nil)
        let resolvedStream: Bool? = editor.streamTouched ? editor.stream : provider.relayRequested?.stream
        let trimmedUA = editor.customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        return RelayRequestedConfig(
            transport: editor.transport,
            authMode: editor.authMode,
            securityMode: editor.securityMode,
            // Relays have no default model, so a newly persisted relayRequested.modelID is always empty.
            modelID: nil,
            // The connection-level reasoning effort is retired: a stored value is cleared by this save, and outbound requests honor only the current turn's reasoning effort.
            reasoningEffort: nil,
            serviceTier: trimmedServiceTier.isEmpty ? nil : trimmedServiceTier,
            stream: resolvedStream,
            disableResponseStorage: editor.disableResponseStorage ? true : nil,
            headers: cleanedHeaders.isEmpty ? nil : cleanedHeaders,
            queryParams: cleanedQueries.isEmpty ? nil : cleanedQueries,
            // This page does not edit the Codex identity: keep the stored value unchanged instead of setting nil / true by type.
            codexCompatIdentity: provider.relayRequested?.codexCompatIdentity,
            customUserAgent: trimmedUA.isEmpty ? nil : trimmedUA,
            imageSize: provider.relayRequested?.imageSize,
            imageQuality: provider.relayRequested?.imageQuality,
            imageStyle: provider.relayRequested?.imageStyle,
            imageCount: provider.relayRequested?.imageCount,
            imageResponseFormat: provider.relayRequested?.imageResponseFormat,
            // The UI no longer edits this: it is only used by the legacy-field read-time mapping, so it is passed through unchanged on save.
            webSearchToolName: provider.relayRequested?.webSearchToolName,
            transportKind: provider.relayRequested?.transportKind,
            resolvedAPIBaseURL: RelayEditView.resolvedAPIBaseURL(
                for: normalizedEndpoint,
                provider: provider,
                securityMode: editor.securityMode
            ),
            resolvedAPIBaseURLs: RelayEditView.resolvedAPIBaseURLs(
                for: normalizedEndpoint,
                provider: provider,
                securityMode: editor.securityMode
            ),
            // engineProfile / certificateFingerprint used not to be carried over at all: editing a local engine once
            // would downgrade it to a plain relay (losing the generation-parameter template and the TOFU fingerprint together), so they must be kept as stored.
            engineProfile: provider.relayRequested?.engineProfile,
            certificateFingerprint: provider.relayRequested?.certificateFingerprint
        ).carryingLegacyWebSearch(from: provider.relayRequested)
    }

    /// The root address found by a reconnect probe is recorded only on **the connection as it is now in the store**; no other field is touched, and nothing is written when the connection has no request config.
    /// Only the root address changes, not the connection protocol; when the discovered protocol is not the connection's actual default, it goes into the per-protocol table.
    static func recordingDiscoveredRoot(
        _ apiBaseURL: String,
        discovered: RelayTransport,
        onto latest: Provider
    ) -> Provider? {
        guard var requested = latest.relayRequested else { return nil }
        RelayEndpointResolver.recordDiscoveredRoot(apiBaseURL, discovered: discovered, into: &requested)
        var written = latest
        written.relayRequested = requested
        return written
    }

    /// The draft of this save: the address is replaced by the normalized one (the address slot in the UI has been written back to it too).
    static func normalizedDraft(_ editor: RelayEditView.Editor, normalizedEndpoint: String) -> RelayEditView.Editor {
        var draft = editor
        draft.endpoint = normalizedEndpoint
        return draft
    }

    /// The candidate that waits for the user to tap "Save anyway (unverified)" on the failure card after a failed validation: the connection is marked unverified,
    /// and the snapshot binds the normalized draft, since that is the editor currently on screen and the commit gate compares against it.
    static func unverifiedCandidate(
        _ candidate: Provider,
        base: Provider,
        draft: RelayEditView.Editor,
        baseline: RelayEditView.Editor? = nil
    ) -> PendingUnverifiedRelaySave {
        PendingUnverifiedRelaySave(
            provider: recordingVerification(candidate, verified: false),
            editorSnapshot: draft,
            secretBaseline: base,
            editorBaseline: baseline
        )
    }

    /// Apply the 1-token validation result to the candidate: pass = connected; failure = the existing "unverified" state (the candidate still holds the user's edited values).
    static func recordingVerification(_ candidate: Provider, verified: Bool) -> Provider {
        var out = candidate
        if verified {
            out.status = .connected
            out.lastCheckedAt = Date()
            out.lastError = nil
        } else {
            out.status = .issue(ProviderIssueMessage.unverifiedConnectionKey)
            out.lastCheckedAt = nil
            out.lastError = ProviderIssueMessage.unverifiedConnectionKey
        }
        return out
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
        // Catalog evidence belongs only to the endpoint/protocol/auth/type it actually probed. After the connection identity
        // changes, keep the enabled models that can still be sent, but never treat the old /models as the new connection's catalog.
        invalidated.catalogModels = []
        return invalidated
    }
}

/// Channels a local connection can choose (`engine-expectations.v1.json` `channels.byEngine`). A channel is connection-level;
/// with only one, no picker is shown. A connection without an engineProfile is not covered here and keeps the Relay protocol picker.
enum LocalEngineChannelCandidates {
    static func candidates(engineProfile: String?) -> [RelayTransport] {
        guard let engine = engineProfile.flatMap(LocalEngineKind.init(rawValue:)) else { return [] }
        switch engine {
        case .llamacpp: return [.openaiChatCompletions, .llamacppNative]
        case .ollama, .lmstudio, .vllm, .openwebui: return [.openaiChatCompletions]
        }
    }

    static func showsSelector(engineProfile: String?) -> Bool {
        candidates(engineProfile: engineProfile).count > 1
    }

    /// The "Channel" block of the edit page: looks only at engineProfile.
    /// nil = not a local connection (use the Relay protocol picker); several options are selectable, a single one is shown read-only.
    enum Section: Equatable {
        case selectable([RelayTransport])
        case readOnly(RelayTransport)
    }

    static func section(engineProfile: String?) -> Section? {
        let options = candidates(engineProfile: engineProfile)
        guard let first = options.first else { return nil }
        return options.count > 1 ? .selectable(options) : .readOnly(first)
    }

    /// Data source for the protocol menu on the edit page: local engines offer the channel set, and every other connection still offers the full Relay protocol set.
    static func transportOptions(engineProfile: String?) -> [RelayTransport] {
        let local = candidates(engineProfile: engineProfile)
        return local.isEmpty ? RelayTransport.allUICases : local
    }
}

/// The verdict shared by the edit page's primary action and its network side effects: if and only if the connection semantics changed, the UI
/// shows "Verify and save" and the save path runs the 1-token validation.
enum RelayEditPrimaryAction: Equatable {
    case save
    case validateAndSave

    var titleKey: String {
        switch self {
        case .save: "Save"
        case .validateAndSave: "Validate and save"
        }
    }

    /// The table the title key actually lives in: "Save" is a common word across the app and exists only in the default table; looking in the wrong table would fall back to the English key.
    var titleTable: L10n.Table {
        switch self {
        case .save: .localizable
        case .validateAndSave: .providers
        }
    }
}

/// The candidate that waits for the user's explicit confirmation on the failure card after a failed validation. The candidate must be bound to the editor snapshot of that moment,
/// so that after the user keeps editing, the failure card can no longer write the old config back.
struct PendingUnverifiedRelaySave {
    let provider: Provider
    let editorSnapshot: RelayEditView.Editor
    /// The connection at the moment Save was tapped: on persist it is used to judge whether a key field was changed on this page.
    let secretBaseline: Provider
    /// The editor baseline from when the page opened: when present, persisting merges by field into the live record.
    var editorBaseline: RelayEditView.Editor? = nil
    /// The verdict of that failed validation for the key actually sent: written when "Save anyway" persists.
    var keyStatus: RelayKeyStatusObservation? = nil
}

/// The result commit gate while a save validation is in flight (shared by successful persist and failure-card output): when the user taps save again,
/// keeps editing the draft, closes the page (invalidating the generation) or the connection was deleted / replaced, the old result is discarded.
enum RelayEditVerificationCommitPolicy {
    static func mayCommit(
        generation: Int,
        currentGeneration: Int,
        snapshot: RelayEditView.Editor,
        currentEditor: RelayEditView.Editor?,
        currentProviderID: UUID?,
        targetProviderID: UUID
    ) -> Bool {
        generation == currentGeneration
            && currentEditor == snapshot
            && currentProviderID == targetProviderID
    }
}

/// Persist coordination for edit-page saves: the zero-network save and "Verify and save" share it, and the view only closes the page or shows the failure card according to the result.
enum RelayEditSaveCommit {
    enum Outcome {
        /// Persisted; the page closes as usual. `refreshesCatalog` = at persist time the merged value changed the connection identity relative to the live record.
        case persisted(Provider, refreshesCatalog: Bool)
        /// Validation failed: the candidate goes to the failure card, which waits for the user to decide whether to "Save anyway (unverified)".
        case verificationFailed(Error, candidate: Provider)
        /// The result is void (draft changed again / generation invalidated / connection deleted); nothing is touched.
        case discarded
    }

    /// Persist for "Save anyway (unverified)": merge into the live record as it is now and mark it unverified.
    static func unverified(
        draft: RelayEditView.Editor,
        baseline: RelayEditView.Editor,
        normalizedEndpoint: String,
        onto live: Provider
    ) -> (provider: Provider, refreshesCatalog: Bool) {
        let merged = RelayEditSavePolicy.mergedCandidate(
            draft: draft, baseline: baseline, normalizedEndpoint: normalizedEndpoint, onto: live
        )
        return (
            RelayEditSavePolicy.recordingVerification(merged, verified: false),
            RelayEditSavePolicy.primaryAction(live: live, draft: draft, baseline: baseline) == .validateAndSave
        )
    }

    @MainActor
    static func run(
        draft: RelayEditView.Editor,
        baseline: RelayEditView.Editor,
        normalizedEndpoint: String,
        live: () -> Provider?,
        verify: (Provider) async throws -> Void,
        isCurrent: () -> Bool,
        persist: (Provider) -> Void,
        applyKeyStatus: (inout Provider) -> Void = { _ in }
    ) async -> Outcome {
        guard let opened = live() else { return .discarded }
        var candidate = RelayEditSavePolicy.mergedCandidate(
            draft: draft, baseline: baseline, normalizedEndpoint: normalizedEndpoint, onto: opened
        )
        // Whether to send a validation uses the same criterion as the UI's primary button: the merged value against the live record.
        guard RelayEditSavePolicy.primaryAction(live: opened, draft: draft, baseline: baseline) == .validateAndSave else {
            persist(candidate)
            return .persisted(candidate, refreshesCatalog: false)
        }
        var attempt = 0
        while true {
            attempt += 1
            var failure: Error?
            do {
                try await verify(candidate)
            } catch is CancellationError {
                return .discarded
            } catch {
                failure = error
            }
            guard isCurrent(), let latest = live() else { return .discarded }
            let merged = RelayEditSavePolicy.mergedCandidate(
                draft: draft, baseline: baseline, normalizedEndpoint: normalizedEndpoint, onto: latest
            )
            // The fields the user changed are the same on both sides, so any difference can only come from validation-relevant fields the user did not change being changed elsewhere during validation:
            // this result does not count, so validate once more against the merged value; if the second run collides again, persist the merge and keep the live status.
            let collided = RelayEditSavePolicy.verificationInputs(of: merged)
                != RelayEditSavePolicy.verificationInputs(of: candidate)
            if collided, attempt == 1 {
                candidate = merged
                continue
            }
            // Second collision: whether it passed or failed, the result does not count; persist the merge, write no validation status, and close the page as usual.
            if let failure, !collided {
                return .verificationFailed(failure, candidate: merged)
            }
            var written = collided ? merged : RelayEditSavePolicy.recordingVerification(merged, verified: true)
            // When the validation result counts, write its verdict for that key together with the persist.
            if !collided { applyKeyStatus(&written) }
            persist(written)
            return .persisted(
                written,
                refreshesCatalog: RelayEditSavePolicy.primaryAction(live: latest, draft: draft, baseline: baseline) == .validateAndSave
            )
        }
    }
}

/// The single commit gate for unverified saves. If the entity does not exist, its ID was replaced, or the editor has new edits,
/// the old candidate is always rejected, and the caller must clear the confirmation card instead of writing the old config.
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
        self.error(from: error, sensitiveMaterial: sensitiveMaterial(of: provider), actionTitle: actionTitle)
    }

    /// A connection that is not persisted yet (the add page's "Manual setup" failing validation) has no `Provider` to give: the caller hands over all credential values
    /// this request may have sent out, and the card construction and redaction stay the same code.
    static func error(
        from error: Error,
        sensitiveMaterial: [String],
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
            sensitiveMaterial: sensitiveMaterial
        )
        return OriveoError(
            id: UUID(),
            title: providerError.title,
            message: providerError.message,
            actionTitle: actionTitle ?? L10n.tr("Save anyway (unverified)", table: .providers),
            // The edit page's 1-token validation has no automatic retry; put the real count of 0 together with the redacted diagnostics
            // into the error card, so the user does not assume the system retried silently.
            detail: technicalDetail.isEmpty ? retryDetail : "\(retryDetail)\n\(technicalDetail)",
            severity: .warning
        )
    }

    private static func sensitiveMaterial(of provider: Provider) -> [String] {
        let requested = provider.relayRequested
        // The list assembled from the connection contains all of its keys: the failing one could be any of them.
        var sensitiveMaterial: [String] = ProviderCredentialResolver.allSecrets(provider: provider)
        // Endpoint host/path and parameter names are safe diagnostics.  The form
        // already rejects user-info and embedded queries; only credential values
        // may be hidden here, never the whole URL or field name.
        sensitiveMaterial += (requested?.headers ?? []).map(\.value)
        sensitiveMaterial += (requested?.queryParams ?? []).map(\.value)
        // A custom User-Agent is credential-like material as well: someone may put an internal identifier or token in it.
        sensitiveMaterial += [requested?.customUserAgent ?? ""]
        return sensitiveMaterial
    }

    private static func redactedTechnicalDetail(_ detail: String, sensitiveMaterial: [String]) -> String {
        sensitiveMaterial
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(detail) { partial, material in
                RelayRequestSecurity.redactingCredentials(partial, credentials: [material])
                    .replacingOccurrences(of: material, with: RelayRequestSecurity.redactedPlaceholder)
            }
    }
}
