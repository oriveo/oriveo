import SwiftUI

/// "Model options" on the chat page: the single entry for web search, thinking and advanced settings.
///
/// **One modal, with depth following frequency**: web search and thinking, used often, are one step away on the first screen; request parameters, used rarely, are pushed one level deeper,
/// and the additional request body one level below that (it lives in advanced settings). The panel is as tall as its content.
///
/// Structural rules (read before changing):
/// 1. **There is no such thing as a grayed-out option.** What can be chosen is drawn as a choice; what cannot is a status row or a note
///    that carries its own way forward (see which models can, open the additional request body, choose the protocol).
/// 2. **Pure functions decide what is drawn; the view only draws it.** One capability's shape is `ModelOptionCapabilityShape`,
///    the whole page is `ModelOptionsPanelModel`; the views in this file read no storage and decide no business condition.
/// 3. **Sub-pages are always pushed, never presented as another modal.** All of them live in the same NavigationStack,
///    so there is always a way back.
/// 4. **A preference taken over by custom request fields is visible right in the card** (staying silent about it would be the interface lying),
///    with a link to advanced settings.
/// 5. **Opening the panel never stores a value for the user.** Never chosen is shown as never chosen; storage is written only when the user acts.
/// The production container behind the composer's single entry: it must open even when the model is missing, rather than vanish at the entry.
struct ModelControlsEntrySheet: View {
    let provider: Provider
    let model: AIModel?
    let conversationID: UUID?
    let isExistingConversation: Bool
    let transportIdentity: String?
    let runtimeIsReadOnly: Bool
    let runtimeReadOnlyReason: String
    @Binding var webEnabled: Bool
    @Binding var reasoningMode: ReasoningMode
    @Binding var reasoningIntentSelection: String?
    let onChooseConnection: () -> Void
    /// The only way out when a relay's protocol is undecided. The panel does not push by itself (see `identityRecoveryAction`);
    /// the composer dismisses the modal and then routes to the provider detail page through appState.
    let onOpenConnectionSettings: () -> Void

    @ViewBuilder
    var body: some View {
        if let model {
            ModelControlsSheet(
                provider: provider,
                model: model,
                conversationID: conversationID,
                isExistingConversation: isExistingConversation,
                transportIdentity: transportIdentity,
                runtimeIsReadOnly: runtimeIsReadOnly,
                runtimeReadOnlyReason: runtimeReadOnlyReason,
                webEnabled: $webEnabled,
                reasoningMode: $reasoningMode,
                reasoningIntentSelection: $reasoningIntentSelection,
                onChooseConnection: onChooseConnection,
                onOpenConnectionSettings: onOpenConnectionSettings
            )
        } else {
            ModelControlsMissingModelSheet(provider: provider, onChooseConnection: onChooseConnection)
        }
    }
}

private struct ModelControlsMissingModelSheet: View {
    let provider: Provider
    let onChooseConnection: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var rows: [String] {
        [
            L10n.tr("Web Search", table: .chat),
            L10n.tr("Thinking Mode", table: .chat),
            L10n.tr("Advanced Settings"),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(provider.displayName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)

                    VStack(alignment: .leading, spacing: 12) {
                        ModelControlNote(
                            text: L10n.tr(
                                "The connection or model is not ready, so these settings are read-only. Choose a connection and model to continue.",
                                table: .chat
                            ),
                            systemImage: "lock.fill"
                        )
                        Button(action: onChooseConnection) {
                            ModelControlInlineActionLabel(
                                title: L10n.tr("Choose another model", table: .chat),
                                systemImage: "arrow.triangle.branch"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(16)
                    .modelControlSurface(cornerRadius: 20)

                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, title in
                            HStack(spacing: 8) {
                                Text(title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                Spacer(minLength: 8)
                                Text(L10n.tr("Not ready", table: .chat))
                                    .font(.subheadline)
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            }
                            .frame(minHeight: 52)
                            .padding(.horizontal, 16)
                            if index < rows.count - 1 { ModelControlHairline() }
                        }
                    }
                    .modelControlSurface(cornerRadius: 20)
                }
                .padding(16)
            }
            .background(OriveoTheme.Palette.background)
            .navigationTitle(L10n.tr("Model Options"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ModelControlsCloseBar { dismiss() } }
        // One detent only: with several, dragging up inside the content is swallowed by the detent gesture and fights scrolling.
        .presentationDetents([.large])
        .presentationCornerRadius(24)
    }
}

/// The bottom close bar of the missing-model state (the main panel's close button is in its header).
///
/// **Closing is a neutral action and should not be system blue**: on this page that blue belongs neither to the brand purple nor to any semantic color.
/// For the same reason it does not use the primary color, which would compete with the level selection.
/// The backing is `surfaceChrome` plus one hairline instead of `.bar`: `.bar` is a system material
/// tuned by the system in both themes, and it does not match this panel's own background (noticeably too bright in dark mode on a device).
private struct ModelControlsCloseBar: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The hairline is a separator, not a border: one line, not a frame.
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(height: 0.5)

            Button(L10n.tr("Close"), action: action)
                .font(.body.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(Rectangle())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .background(OriveoTheme.Palette.surfaceChrome)
    }
}

struct ModelControlsSheet: View {
    let provider: Provider
    let model: AIModel
    let conversationID: UUID?
    let isExistingConversation: Bool
    /// A complete runtime identity only decides whether writing is possible, not whether the entry appears.
    let transportIdentity: String?
    /// While sending, or while the conversation is read-only during backfill, the panel can still be viewed but must not rewrite that conversation's settings.
    let runtimeIsReadOnly: Bool
    let runtimeReadOnlyReason: String
    @Binding var webEnabled: Bool
    @Binding var reasoningMode: ReasoningMode
    /// What decides the composer chip's highlight. `ReasoningMode` cannot express catalog levels such as `off` or `low`;
    /// highlighting from it would show "Fast" as not set, so the real intent travels on its own channel.
    @Binding var reasoningIntentSelection: String?
    let onChooseConnection: () -> Void
    /// See `ModelControlsEntrySheet.onOpenConnectionSettings`.
    let onOpenConnectionSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var web: CapabilityWebPreference = .off
    @State private var reasoningIntent: String?
    @State private var customModes: [String: LocalCustomConfigurationMode] = [:]
    /// A setting was changed in this conversation: "Set as this model's default" appears at the end of the panel. **Kept only while this panel is open**,
    /// not a persistent nag.
    @State private var showsScopeUpgrade = false
    @State private var scopeUpgradeConfirmed = false
    @State private var path: [ModelControlsRoute] = []
    /// Generation parameters and the additional request body live in `UserDefaults`, which is not observable state. Incremented when the panel
    /// writes them or when returning from advanced settings, so the panel reads them again.
    @State private var storedSettingsRevision = 0
    /// The identity obtained after a successful refetch inside the panel. See `effectiveTransportIdentity`.
    @State private var refreshedIdentity: String?
    @State private var isRefreshingRuntime = false
    @State private var runtimeRefreshFailed = false

    /// The identity passed in was computed when the parent opened the panel, and the `MetadataClient` snapshot is not
    /// `@Observable`: after a successful refetch inside the panel the parent does not recompute, and the parameter stays nil. The refetched
    /// identity is therefore kept in local `@State` and takes precedence; otherwise the refetch button would be another dead end:
    /// the data has arrived, yet the interface stays locked.
    private var effectiveTransportIdentity: String? { transportIdentity ?? refreshedIdentity }

    private var editability: ModelControlsEditability {
        ModelControlsEditability.resolve(
            providerKind: provider.kind,
            transportIdentity: effectiveTransportIdentity,
            runtimeIsReadOnly: runtimeIsReadOnly
        )
    }

    private var relayTransportIsDecided: Bool {
        CapabilityPreferenceRuntimeIdentity.relayFinalTransport(
            provider: provider, resolvedFinalTransport: nil
        ) != nil
    }

    private var identityGap: ModelControlsIdentityGap {
        ModelControlsIdentityGap.resolve(
            providerKind: provider.kind,
            relayTransportIsDecided: relayTransportIsDecided,
            runtimeIsReady: MetadataClient.shared.syncCapabilityRecipeRuntime(
                modelID: model.id, providerKind: provider.kind
            ).runtime != nil
        )
    }

    private var capabilityModelID: String {
        CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)?.canonicalModelID ?? ""
    }
    /// The scope key of the additional request body, the same one the send path reads it with.
    private var additionalBodyModelID: String {
        CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model)
    }
    private var generationProfileFingerprint: String {
        GenerationParameterProfileFingerprint.make(provider: provider, model: model)
    }
    /// Reading custom fields also carries records from an older recipe version forward. The schema lookup uses the catalog model id,
    /// not the canonical id in storage (for a relay the two can differ).
    private var localCustomForwardPort: CapabilityLocalCustomForwardPortContext {
        .init(providerKind: provider.kind, schemaModelID: model.id)
    }

    var body: some View {
        ModelOptionsSheetScaffold(path: $path) {
            ModelOptionsPanel(model: ModelOptionsPanelModel.make(panelFacts), onAction: handle)
                .onAppear(perform: restore)
        } destination: { route in
            destination(for: route)
        }
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(for route: ModelControlsRoute) -> some View {
        switch route {
        case .modelBehavior:
            GenerationParameterDefaultsSheet(
                provider: provider,
                initialModelID: model.id,
                conversationID: conversationID,
                presentation: .embeddedPage,
                capabilityHeader: advancedSettingsHeader,
                isReadOnly: !editability.canPersist
            )
            .onDisappear { storedSettingsRevision += 1 }
        case .additionalRequestBody:
            AdditionalRequestBodyPage(
                provider: provider, model: model, conversationID: conversationID,
                transportIdentity: effectiveTransportIdentity ?? ""
            )
            .onDisappear { storedSettingsRevision += 1 }
        case let .supportedModels(capability):
            CapabilitySupportedModelsPage(
                provider: provider,
                capability: capability,
                candidates: supportedModelCandidates(for: capability),
                onSelect: selectCandidateModel
            )
        }
    }

    /// The sentence at the top of the advanced settings page while it is read-only. Returns nil when writable, not an empty view: that page only checks
    /// `if let`, and a zero-height view would leave a permanent blank card.
    private var advancedSettingsHeader: AnyView? {
        guard let reason = readOnlyReasonText else { return nil }
        return AnyView(
            ModelControlNote(text: reason, systemImage: "lock.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    private var readOnlyReasonText: String? {
        switch editability {
        case .runtimeReadOnly: return runtimeReadOnlyReason
        case .runtimeIdentityUnavailable: return identityGap.reasonText
        case .writable: return nil
        }
    }

    // MARK: - Facts the panel draws

    /// This only lays out the facts that can be looked up; what they are drawn as is decided by `ModelOptionsPanelModel.make` and
    /// `ModelOptionCapabilityCard.resolve`.
    private var panelFacts: ModelOptionsPanelFacts {
        _ = storedSettingsRevision
        let webStatus = presentation(for: "web")
        let reasoningStatus = presentation(for: "reasoning")
        let webOverridden = isCustomActive("web")
        let reasoningOverridden = isCustomActive("reasoning")
        let connection: ModelOptionCapabilityShape.Connection = provider.kind == .relay ? .custom : .official
        let protocolUndecided = provider.kind == .relay && !relayTransportIsDecided
        // The chat template's thinking switch only makes sense on a protocol that applies a chat template.
        let supportsChatTemplate = ChatTemplateThinkingSwitch.applies(
            toTransport: CapabilityPreferenceRuntimeIdentity.relayFinalTransport(
                provider: provider, resolvedFinalTransport: nil
            )
        )
        // A custom connection without an official configuration: thinking goes through the additional request body, and writing that needs no runtime identity.
        let thinkingUsesChatTemplate = connection == .custom && supportsChatTemplate
            && (reasoningStatus == .pending || reasoningStatus == .unknown)
        let rejectedKeys = rejectedCapabilityKeys
        let takenOver: [ModelOptionCapabilityShape.Capability] =
            (webOverridden ? [.web] : []) + (reasoningOverridden ? [.reasoning] : [])

        return .init(
            modelName: model.name,
            connectionName: provider.displayName,
            protocolLabel: customTransport.map(CapabilityTransportLabel.display),
            engineProfile: provider.relayRequested?.engineProfile,
            apiRoot: provider.relayRequested?.resolvedAPIBaseURL ?? provider.baseURLText,
            web: .init(
                capability: .web,
                presentation: webStatus,
                availableIntents: webIntents,
                selectedIntent: web.rawValue,
                connection: connection,
                isWritable: editability.canPersist && !webOverridden,
                protocolUndecided: protocolUndecided
            ),
            reasoning: .init(
                capability: .reasoning,
                presentation: reasoningStatus,
                availableIntents: reasoningIntents,
                selectedIntent: reasoningIntent,
                connection: connection,
                isWritable: thinkingUsesChatTemplate
                    ? !runtimeIsReadOnly
                    : editability.canPersist && !reasoningOverridden,
                protocolUndecided: protocolUndecided,
                // The negative cache is checked once per level: the rejected level is not necessarily the selected one.
                rejectedIntents: reasoningIntents.filter { intent in
                    !rejectedKeys.isDisjoint(with: CapabilityRecipeRequestCompiler.capabilityEvidenceKeys(
                        capability: .reasoning, selectedIntent: intent
                    ))
                },
                supportsChatTemplate: supportsChatTemplate
            ),
            chatTemplateThinking: ChatTemplateThinkingSwitch.state(
                of: GenerationParameterSettingsStore.shared.effectiveAdditionalRequestBody(
                    providerID: provider.id, modelID: additionalBodyModelID, conversationID: conversationID
                )
            ),
            hasWebCandidates: hasSupportedModelCandidates(for: "web", status: webStatus),
            hasReasoningCandidates: hasSupportedModelCandidates(for: "reasoning", status: reasoningStatus),
            takenOverByCustomFields: Set(takenOver),
            customFieldRiskTiers: takenOver.flatMap { customFieldRiskTiers(owner: $0.rawValue) },
            webRejectedUpstream: !rejectedKeys.isDisjoint(
                with: CapabilityRecipeRequestCompiler.capabilityEvidenceKeys(capability: .web, selectedIntent: nil)
            ),
            banner: banner,
            advancedRows: advancedRows,
            scopeUpgrade: showsScopeUpgrade ? (scopeUpgradeConfirmed ? .confirmed : .offer) : nil
        )
    }

    /// The read-only note at the top of the page. An undecided protocol is not mentioned here: the capability card says it, and saying it twice is repetition.
    private var banner: ModelOptionsPanelModel.Banner? {
        switch editability {
        case .runtimeReadOnly:
            return .init(text: runtimeReadOnlyReason)
        case .runtimeIdentityUnavailable:
            // Each reason is paired with the action that solves **it**; the test is whether the state really changes after the tap.
            switch identityGap.recoveryAction {
            case .openConnectionSettings:
                // Undecided protocol: the capability card collapses into "choose the protocol first", and that is the way out.
                return nil
            case .refetchRuntime:
                // Fetching again is the only thing that can change this state, so the button does exactly that. If it is still missing afterwards, that is
                // a real failure and must be said: otherwise tapping the button changes nothing on screen.
                return .init(
                    text: identityGap.reasonText, action: .refetch, isBusy: isRefreshingRuntime,
                    failureText: runtimeRefreshFailed
                        ? L10n.tr("Still no luck. Check your network and try again.", table: .chat)
                        : nil
                )
            case .chooseAnotherModel:
                return .init(text: identityGap.reasonText, action: .chooseAnotherModel)
            }
        case .writable:
            return nil
        }
    }

    /// The rows behind the "Advanced settings" summary. They come from the same parameter table and the same row factory as the advanced settings page,
    /// so the chips shown here and the "changed in this conversation" items seen after tapping through are always the same set.
    private var advancedRows: [GenerationParameterRowModel] {
        guard let conversationID else { return [] }
        let store = GenerationParameterSettingsStore.shared
        let catalog = AdvancedSettingsCatalog.production(
            provider: provider, model: model, scope: .session,
            identity: generationEvidenceIdentity,
            isReadOnly: !editability.canPersist
        )
        return catalog.rows(
            store: store, providerID: provider.id, modelID: model.id, conversationID: conversationID,
            layerValues: store.sessionOverrides(
                providerID: provider.id, modelID: model.id, conversationID: conversationID,
                profileFingerprint: generationProfileFingerprint
            ) ?? .init(),
            profileFingerprint: generationProfileFingerprint
        ).map(\.model)
    }

    /// The same criterion as the advanced settings page: a relay has one only when the resolver can determine the final route uniquely.
    private var generationEvidenceIdentity: CapabilityEvidenceRequestIdentity? {
        if provider.kind == .relay {
            return CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider: provider, model: model, partitionID: appState.sessionPartitionUID
            )
        }
        return CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: appState.sessionPartitionUID,
            hasExplicitValue: false
        )
    }

    // MARK: - Actions

    private func handle(_ action: ModelOptionsPanelAction) {
        switch action {
        case .close:
            dismiss()
        case let .setToggle(capability, target, isOn):
            setToggle(capability: capability, target: target, isOn: isOn)
        case let .selectReasoningTier(intent):
            // Automatic and a cleared selection are both stored as nil: no level is injected.
            reasoningIntent = intent == ModelOptionCapabilityShape.automaticIntent ? nil : intent
            persist()
        case let .selectWebTiming(raw):
            guard let next = CapabilityWebPreference(rawValue: raw) else { return }
            web = next
            persist()
        case let .open(destination, capability):
            open(destination, capability: capability)
        case .openAdvancedSettings:
            path.append(.modelBehavior)
        case .banner(.refetch):
            Task { await refreshRuntime() }
        case .banner(.chooseAnotherModel):
            onChooseConnection()
        case .promoteToModelDefault:
            promoteSelectionToModelDefault()
        }
    }

    private func setToggle(
        capability: ModelOptionCapabilityShape.Capability,
        target: ModelOptionCapabilityShape.ToggleTarget,
        isOn: Bool
    ) {
        switch target {
        case let .capabilityPreference(on, off):
            switch capability {
            case .web:
                // The toggle only expresses on and off; switching to "search every message" while on is the timing row's job.
                web = CapabilityWebPreference(rawValue: isOn ? on : off) ?? (isOn ? .automatic : .off)
            case .reasoning:
                reasoningIntent = isOn ? on : off
            }
            persist()
        case .chatTemplateThinking:
            guard !runtimeIsReadOnly else { return }
            ChatTemplateThinkingSwitch.write(
                isOn, providerID: provider.id, modelID: additionalBodyModelID, conversationID: conversationID
            )
            storedSettingsRevision += 1
        }
    }

    private func open(
        _ destination: ModelOptionCapabilityAction, capability: ModelOptionCapabilityShape.Capability
    ) {
        switch destination {
        case .openSupportedModels:
            path.append(.supportedModels(capability: capability.rawValue))
        case .openAdditionalRequestBody:
            // Goes straight to the editor without passing through the advanced settings page; back returns to the panel.
            path.append(.additionalRequestBody)
        case .openConnectionProtocol:
            // **Must not be pushed inside the panel**: the back button of `ProviderDetailView` calls `appState.pop()`, which pops
            // the root stack behind the sheet, not this modal's own `path`. The panel sets a flag and dismisses, and the composer
            // routes to the real detail page through appState in onDismiss.
            onOpenConnectionSettings()
        case .switchConnection:
            onChooseConnection()
        }
    }

    /// Refetches metadata and unlocks in place.
    ///
    /// `forceRefresh` requests the index conditionally and completes this provider's catalog (no request when the revision already matches).
    /// The identity is recomputed right after and stored in `@State`: the `MetadataClient` snapshot is not `@Observable`, and without this step the parameter passed in by the parent would stay nil.
    private func refreshRuntime() async {
        isRefreshingRuntime = true
        runtimeRefreshFailed = false
        await MetadataClient.shared.forceRefresh(providerKinds: [provider.kind])
        let resolved = CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)?.wireValue
        refreshedIdentity = resolved
        isRefreshingRuntime = false
        if resolved == nil {
            runtimeRefreshFailed = true
        } else {
            // After unlocking, the stored preferences must be read in; otherwise the panel becomes tappable but shows nothing but defaults.
            restore()
        }
    }

    // MARK: - Facts that can be looked up

    /// Whether this owner's custom fields are **rewriting the request right now**.
    ///
    /// The criterion must match the outbound gate exactly: the send path looks at `mode == .custom`
    /// (`activeLocalCustomFragments`) and at nothing else. Any extra condition here
    /// would diverge from what is actually sent: the interface would say "the preference above is not sent" while it is being sent.
    private func isCustomActive(_ owner: String) -> Bool {
        customModes[owner, default: .automatic] == .custom
    }

    private func customFieldRiskTiers(owner: String) -> [String] {
        CapabilityRecipeExecution.customControlRiskTiers(
            owner: owner, providerKind: provider.kind, modelID: model.id,
            transport: CapabilityRecipeExecution.finalTransport(
                owner: owner, provider: provider, model: model
            ) ?? ""
        )
    }

    /// Capability keys the upstream has rejected for this connection / model / generation, from the local negative cache. No request is made and no verdict changes.
    /// The keys have the same source as the outbound gate: `web_search` / `reasoning_level/<level>`.
    private var rejectedCapabilityKeys: Set<String> {
        guard let identity = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
            provider: provider, model: model, partitionID: appState.sessionPartitionUID
        ) ?? (provider.relayRequested == nil
            ? CapabilityEvidenceRequestIdentity.make(
                provider: provider, model: model, partitionID: appState.sessionPartitionUID,
                hasExplicitValue: true
            )
            : nil) else { return [] }
        return Set(UnsupportedParamCache.shared.capabilityRejectedCandidates(
            providerKind: provider.kind, modelID: model.id,
            endpointFingerprint: identity.query.endpointFingerprint, identity: identity
        ).map(\.key))
    }

    /// The criterion lives in `CapabilityControlPresentationResolver`: the composer and ChatView answer
    /// the same question (will this preference go out right now), and three separate copies would drift apart.
    private func presentation(for capability: String) -> CapabilityControlPresentation {
        CapabilityControlPresentationResolver.presentation(
            provider: provider, model: model, capability: capability
        )
    }

    private var controls: [String: MetadataClient.CapabilityControl]? {
        MetadataClient.shared.syncCapabilityRecipeRuntime(
            modelID: model.id, providerKind: provider.kind
        ).controls
    }

    private var reasoningIntents: [String] {
        CapabilityControlResolution.resolve(
            provider: provider, model: model, capability: "reasoning"
        ).intents
    }

    /// The available web search levels. `force` only counts when an official recipe declares it under `auto_available`;
    /// most models do not, and they should not see that level.
    private var webIntents: [String] {
        guard controls?["web"]?.state == RequestControlAvailability.autoAvailable.rawValue else { return [] }
        return controls?["web"]?.availableIntents ?? []
    }

    private var customTransport: String? {
        CapabilityRecipeExecution.displayTransport(provider: provider, model: model)
    }

    /// Whether the "see which models can be adjusted" link leads anywhere. The candidate list walks every model of the connection, so it is computed only
    /// when this row could really offer that link.
    private func hasSupportedModelCandidates(
        for capability: String, status: CapabilityControlPresentation
    ) -> Bool {
        switch status {
        case .unsupported, .externalConnectorOnly, .pending, .unknown:
            return !supportedModelCandidates(for: capability).isEmpty
        case .automaticAvailable, .forceUnsupported, .customOnly:
            return true
        }
    }

    private func supportedModelCandidates(for capability: String) -> [AIModel] {
        // Candidates are **enabled** models only. A catalog model has to be enabled before it can be chosen, so listing it
        // would be a second dead end.
        CapabilityControlActionCandidates.supportingModels(
            capability: capability, models: provider.models
        ) { candidate in
            let snapshot = MetadataClient.shared.syncCapabilityRecipeRuntime(
                modelID: candidate.id, providerKind: provider.kind
            )
            guard let control = snapshot.controls?[capability],
                  let recipeRef = control.recipeRef,
                  let runtime = snapshot.runtime,
                  let recipe = runtime.recipes[recipeRef]
            else {
                return .init(state: snapshot.controls?[capability]?.state, recipeTransport: nil, modelTransport: nil)
            }
            let modelTransport = MetadataClient.shared.syncResolveCatalogModel(
                modelID: candidate.id, providerKind: provider.kind
            )?.transport
            return .init(
                state: control.state,
                recipeTransport: recipe.transport.protocolName,
                modelTransport: modelTransport
            )
        }
    }

    private func selectCandidateModel(_ candidate: AIModel) {
        appState.selectModel(
            modelID: candidate.id,
            providerID: provider.id,
            for: isExistingConversation ? conversationID : nil
        )
        dismiss()
    }

    // MARK: - Persistence

    /// **Reading only requires the identity**: `canPersist` gates writing, and using it to block reading would make
    /// a read-only panel (while sending, or during backfill) show nothing but defaults. A user who set deep thinking
    /// would open it and see "never chosen", which is worse than not showing it. The write-side guard stays in `persist()`.
    ///
    /// This only reads: opening the panel stores no value for the user.
    ///
    /// Restoring is not a user action, so it must not animate. The first frame is drawn as
    /// "nothing chosen"; the restored tier then moves the highlight and adds a caption line that
    /// pushes the content below it. The segmented control carries `.animation(value: selection)`,
    /// which in the same transaction would also animate its own displacement, so that one row
    /// would slide up on its own after the panel appears.
    private func restore() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, restoreStoredSelection)
    }

    private func restoreStoredSelection() {
        // Reading and writing both use `effectiveTransportIdentity`: after an in-panel refetch unlocks the panel, the parameter passed in by the parent
        // is still nil, and using it would split "can tap" from "can store": the controls unlock, yet changes are silently lost.
        guard let transportIdentity = effectiveTransportIdentity else { return }
        // The read ladder has the same source as the send path (conversation → model default → connection): if the panel kept its own copy,
        // "Set as this model's default" would write a value that no screen could read back.
        let restored = GenerationParameterSettingsStore.shared.displayCapabilityPreferences(
            providerID: provider.id, modelID: capabilityModelID, conversationID: conversationID,
            skillID: nil, transportIdentity: transportIdentity
        )
        web = restored.web
        reasoningIntent = restored.reasoningIntent
        for owner in RequestPreferenceOwner.allCases.map(\.rawValue) {
            let configuration = GenerationParameterSettingsStore.shared.effectiveLocalCustomConfiguration(
                providerID: provider.id, modelID: capabilityModelID, conversationID: conversationID,
                transportIdentity: transportIdentity, namespace: namespace(for: owner),
                forwardPort: localCustomForwardPort
            )
            customModes[owner] = configuration.mode
        }
        publishSelection()
    }

    private func persist() {
        guard editability.canPersist, let transportIdentity = effectiveTransportIdentity else { return }
        // The confirmation from the previous "Set as this model's default" must not vouch for this new change: the user just moved a level,
        // and a lingering "Set as default" at the bottom would read as "this level is stored as the default too".
        scopeUpgradeConfirmed = false
        // A stored "search every message" that the current configuration no longer has is clamped back to "search when needed" before saving;
        // otherwise a value that can never compile stays in storage and is clamped again each time the panel opens.
        web = ModelOptionCapabilityShape.clampedWebPreference(
            web, presentation: presentation(for: "web"), availableIntents: webIntents
        )
        GenerationParameterSettingsStore.shared.setCapabilityPreferences(
            .init(web: web, reasoningIntent: reasoningIntent), providerID: provider.id,
            modelID: capabilityModelID, conversationID: conversationID, transportIdentity: transportIdentity
        )
        // Scope is only raised after a change: by then the user knows what was changed, and "should this also apply from now on" is a question
        // they can answer. **A draft conversation asks too**: its change also lands in the conversation scope (draft id)
        // and is gone once the conversation is closed. Gating this on an existing conversation would let a change in a new conversation
        // live exactly once, while the user believes the model's default was changed.
        if conversationID != nil, !showsScopeUpgrade {
            showsScopeUpgrade = true
        }
        publishSelection()
    }

    /// Promotes the current selection to **this model's default** (the conversationID = nil scope).
    ///
    /// The confirmation is an inline state, **not `ToastManager`**: its overlay sits below modals,
    /// so a toast raised from inside a sheet is never seen.
    private func promoteSelectionToModelDefault() {
        guard editability.canPersist, let transportIdentity = effectiveTransportIdentity else { return }
        GenerationParameterSettingsStore.shared.setCapabilityPreferences(
            .init(web: web, reasoningIntent: reasoningIntent), providerID: provider.id,
            modelID: capabilityModelID, conversationID: nil, transportIdentity: transportIdentity
        )
        scopeUpgradeConfirmed = true
        // Once read, the confirmation should make way; otherwise it stays at the bottom of the panel as permanent noise.
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard scopeUpgradeConfirmed else { return }
            showsScopeUpgrade = false
            scopeUpgradeConfirmed = false
        }
    }

    /// Passes the selection made in the panel back to the composer.
    ///
    /// **Each of the three writes must be compared before writing, never assigned unconditionally.** Writing a `@Binding` makes the parent's `@State`
    /// change → the parent's body is recomputed → the `.sheet` content closure is evaluated again → this panel's root view gets
    /// `onAppear` again → `restore()` → `publishSelection()` once more: a complete livelock loop.
    ///
    /// On a device it shows as CPU at 99% after one tap on a thinking level, memory climbing, the console repeating
    /// `NavigationRequestObserver tried to update multiple times per frame`, and a frozen interface;
    /// since it is not a crash, there is no stack trace either. The loop only stays dormant while the first guard of `persist()` and
    /// `restore()` returns early because `transportIdentity` is nil;
    /// as soon as an identity is available it is live.
    ///
    /// Comparing first makes the writes converge: the second round finds the values unchanged and writes nothing, the parent stops recomputing, and the loop ends by itself.
    /// Do not "simplify" this back to unconditional assignment.
    private func publishSelection() {
        // `web != .off` only means the user expressed it. The preference is stored per connection × model × transport, while whether it can
        // go out depends on the current metadata: after a model generation change, a removal or a transport change the storage is byte for byte the same, the globe on the chip
        // would stay lit, and the request would carry no web search field at all. Storage is not rewritten (switching back to a usable model restores it); the globe
        // just is not lit for a preference that will not go out.
        let nextWebEnabled = web != .off && CapabilityWebPreferenceLiveness.reachesTheWire(
            status: presentation(for: "web"), customIsActive: isCustomActive("web")
        )
        if webEnabled != nextWebEnabled { webEnabled = nextWebEnabled }
        // The intent vocabulary and the local level enum use different names (`low` ↔ `fast`), so the single reverse mapping is required;
        // a plain `ReasoningMode(rawValue:)` would silently turn "Fast" into automatic, that is, send nothing.
        // `off` has no legacy enum representation; it stays automatic and the real intent below is what counts.
        let nextMode = ReasoningMode.fromIntent(reasoningIntent) ?? .automatic
        if reasoningMode != nextMode { reasoningMode = nextMode }
        if reasoningIntentSelection != reasoningIntent { reasoningIntentSelection = reasoningIntent }
    }

    private func namespace(for owner: String) -> String { "\(owner)Patch" }
}

// MARK: - Panel shell

/// The panel's modal shell: one navigation stack whose root is the model options page, as tall as the root's content; it fills the screen once a second-level page is pushed.
///
/// The real panel and the debug samples share it, so the height seen in a sample is the height the user sees.
///
/// **How the height is decided**: the root content sits in a `ScrollView` and measures its own height in place (the view is in the hierarchy, at the user's
/// current text size), and that height is the detent; the system reserves the bottom safe area separately, so it is not added again. The content holds no lazy containers, which
/// cannot report a usable height under unbounded height; when measuring really fails it falls back to half the screen instead of letting the system clamp it to full height.
/// The root page has one detent only: with several, dragging up inside the content is swallowed by the detent gesture and fights scrolling.
///
/// **How the sheet grows for a second-level page**:
/// - It grows by changing the selected detent, not by swapping the only detent for another. Replacing a lone detent gets no
///   transition and the sheet jumps. So the full-height detent joins the set when a page is about to be pushed, and the
///   selection moves to it, which the system animates.
/// - The navigation stack follows its own path, one turn behind the caller's `path`. When growing and pushing land in the
///   same turn, the push positions the incoming page with the size from before the change, and the page stays clipped to the
///   old sheet height for the whole slide, leaving its lower half blank for about half a second.
struct ModelOptionsSheetScaffold<Root: View, Destination: View>: View {
    @Binding var path: [ModelControlsRoute]
    @ViewBuilder let root: () -> Root
    @ViewBuilder let destination: (ModelControlsRoute) -> Destination

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0
    @State private var selectedDetent: PresentationDetent = .medium
    /// The path the navigation stack actually uses; see the type's notes.
    @State private var stackPath: [ModelControlsRoute] = []

    var body: some View {
        NavigationStack(path: $stackPath) {
            ScrollView {
                root()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .background(OriveoTheme.Palette.background)
            // The root page draws its own title and close button (the model name is the title), so the system navigation bar does not take another line.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ModelControlsRoute.self, destination: destination)
        }
        .presentationDetents(
            stackPath.isEmpty && selectedDetent != .large ? [fittedDetent] : [fittedDetent, .large],
            selection: $selectedDetent
        )
        .onChange(of: fittedDetent, initial: true) { _, fitted in
            if path.isEmpty, stackPath.isEmpty { selectedDetent = fitted }
        }
        .onChange(of: path, initial: true) { _, next in follow(next) }
        .onChange(of: stackPath) { _, next in
            // The back gesture and the back button change the stack's own path; hand it back to the caller.
            if path != next { path = next }
            if next.isEmpty { selectedDetent = fittedDetent }
        }
        .presentationCornerRadius(30)
        // Push and pop animations of second-level pages are dropped under Reduce Motion. The push animation of `NavigationStack` is driven by a system
        // transaction; `.animation(nil)` alone does not turn it off, `disablesAnimations` has to be set on the transaction.
        .transaction { transaction in
            guard reduceMotion else { return }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func follow(_ next: [ModelControlsRoute]) {
        guard next != stackPath else { return }
        guard stackPath.isEmpty, !next.isEmpty else {
            stackPath = next
            return
        }
        selectedDetent = .large
        Task { @MainActor in
            // The caller may have changed its mind within this turn (closing right away, for example); use its path as of now.
            if stackPath != path { stackPath = path }
        }
    }

    private var fittedDetent: PresentationDetent {
        switch ModelOptionsSheetHeight.resolve(contentHeight: contentHeight, hasPushedPage: false) {
        case let .fitted(height): return .height(height)
        case .half: return .medium
        case .full: return .large
        }
    }
}

// MARK: - Panel

/// What can happen on the panel. The panel only reports; it changes no state itself.
enum ModelOptionsPanelAction: Equatable {
    case close
    case setToggle(
        capability: ModelOptionCapabilityShape.Capability,
        target: ModelOptionCapabilityShape.ToggleTarget,
        isOn: Bool
    )
    /// nil = selection cleared, back to never chosen.
    case selectReasoningTier(String?)
    case selectWebTiming(String)
    case open(ModelOptionCapabilityAction, capability: ModelOptionCapabilityShape.Capability)
    case openAdvancedSettings
    case banner(ModelOptionsPanelModel.Banner.Action)
    case promoteToModelDefault
}

/// Content of the model options panel: model name and close button → connection · protocol · seal → the capability card → the parameter card.
///
/// It only draws a `ModelOptionsPanelModel`. Each row of the capability card is drawn case by case from `ModelOptionCapabilityShape`,
/// reading no storage and deciding no business condition; so there is no grayed-out option on screen: what cannot be chosen
/// is already a status row or a note in the shape, with its own way forward.
struct ModelOptionsPanel: View {
    typealias Shape = ModelOptionCapabilityShape

    let model: ModelOptionsPanelModel
    let onAction: (ModelOptionsPanelAction) -> Void

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        VStack(spacing: 10) {
            header

            if let banner = model.banner {
                bannerCard(banner)
            }

            ModelOptionSectionLabel(text: L10n.tr("Capabilities", table: .providers))
            capabilityCard

            ModelOptionSectionLabel(text: L10n.tr("Parameters", table: .providers))
            advancedCard

            if let scopeUpgrade = model.scopeUpgrade {
                ModelControlScopeUpgradeRow(isConfirmed: scopeUpgrade == .confirmed) {
                    onAction(.promoteToModelDefault)
                }
            }
        }
        .padding(.horizontal, 16)
        // A modal without a navigation bar: the system grabber is drawn inside the top of the content area, and the title has to clear it.
        .padding(.top, 28)
        .padding(.bottom, 30)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                // When one line is not enough on a narrow screen or at a large text size it wraps instead of truncating the connection name.
                ModelControlWrappingLayout(spacing: 7, lineSpacing: 3, layoutDirection: layoutDirection) {
                    subjectText(model.connectionName)
                    if let protocolLabel = model.protocolLabel {
                        subjectDot
                        subjectText(protocolLabel)
                    }
                    if let seal = model.seal {
                        subjectDot
                        ModelOptionSealLabel(seal: seal)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ModelOptionCloseButton { onAction(.close) }
                .padding(.top, -8)
                .padding(.trailing, -8)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    private func subjectText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .lineLimit(1)
    }

    private var subjectDot: some View {
        Circle()
            .fill(OriveoTheme.Palette.textTertiary)
            .frame(width: 2.5, height: 2.5)
            .accessibilityHidden(true)
    }

    // MARK: Read-only note

    private func bannerCard(_ banner: ModelOptionsPanelModel.Banner) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ModelControlNote(text: banner.text, systemImage: "lock.fill")

            switch banner.action {
            case .refetch:
                Button {
                    onAction(.banner(.refetch))
                } label: {
                    ModelControlInlineActionLabel(
                        title: banner.isBusy
                            ? L10n.tr("Fetching…", table: .chat)
                            : L10n.tr("Fetch again", table: .chat),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.plain)
                .disabled(banner.isBusy)
            case .chooseAnotherModel:
                Button {
                    onAction(.banner(.chooseAnotherModel))
                } label: {
                    ModelControlInlineActionLabel(
                        title: L10n.tr("Choose another model", table: .chat),
                        systemImage: "arrow.triangle.branch"
                    )
                }
                .buttonStyle(.plain)
            case nil:
                EmptyView()
            }

            if let failure = banner.failureText {
                ModelControlNote(text: failure, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modelControlSurface()
    }

    // MARK: Capability card

    private var capabilityCard: some View {
        VStack(spacing: 0) {
            switch model.card {
            case let .callout(callout):
                calloutBlock(callout)
            case let .rows(rows):
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { ModelControlHairline() }
                    capabilityRow(row)
                }
            }

            if !model.notes.isEmpty {
                ModelControlHairline()
                notesBlock
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modelControlSurface()
    }

    @ViewBuilder
    private func capabilityRow(_ row: ModelOptionsPanelModel.Row) -> some View {
        let title = Self.title(row.capability)
        switch row.shape {
        case let .toggle(toggle):
            toggleRow(title: title, toggle: toggle, capability: row.capability)
        case let .tiers(tiers):
            tiersBlock(title: title, tiers: tiers)
        case let .toggleWithTiming(toggle, timing):
            toggleRow(title: title, toggle: toggle, capability: row.capability)
            ModelControlHairline()
            ModelOptionSegmentedControl(
                options: timing.options, selection: timing.selection, showsGlyphs: false,
                accessibilityTitle: title
            ) { selected in
                if let selected { onAction(.selectWebTiming(selected)) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        case let .notice(notice):
            noticeBlock(title: title, notice: notice, capability: row.capability)
        case let .disclosure(disclosure):
            disclosureRow(title: title, disclosure: disclosure, capability: row.capability)
        case let .protocolUndecided(callout):
            calloutBlock(callout)
        }
    }

    private static func title(_ capability: Shape.Capability) -> String {
        switch capability {
        case .web: return L10n.tr("Web Search", table: .chat)
        case .reasoning: return L10n.tr("Thinking Mode", table: .chat)
        }
    }

    /// Title and caption on the left, toggle on the right, on one horizontal line.
    private func toggleRow(title: String, toggle: Shape.Toggle, capability: Shape.Capability) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                ModelOptionRowTitle(text: title)
                if let caption = toggle.caption {
                    ModelOptionCaption(text: caption)
                }
                if let link = toggle.link {
                    linkButton(link, capability: capability)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(
                "",
                isOn: Binding(
                    get: { toggle.isOn },
                    set: { onAction(.setToggle(capability: capability, target: toggle.target, isOn: $0)) }
                )
            )
            .labelsHidden()
            .tint(OriveoTheme.Palette.primaryTextSafe)
            .accessibilityLabel(Text(title))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
    }

    /// Title and a note at the top right → a row of levels → a paragraph below.
    private func tiersBlock(title: String, tiers: Shape.Tiers) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ModelOptionRowTitle(text: title)
                Spacer(minLength: 8)
                if let note = tiers.headerNote {
                    ModelOptionCaption(
                        text: note,
                        color: tiers.headerTone == .warning
                            ? OriveoTheme.Palette.warningText
                            : OriveoTheme.Palette.textSecondary,
                        alignment: .trailing
                    )
                }
            }

            ModelOptionSegmentedControl(
                options: tiers.options, selection: tiers.selection,
                allowsClearing: tiers.allowsClearing,
                accessibilityTitle: title
            ) { selected in
                onAction(.selectReasoningTier(selected))
            }

            if !tiers.footnotes.isEmpty {
                ModelOptionCaption(text: ModelOptionsText.joined(tiers.footnotes))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 15)
    }

    /// Title and a status at the top right → a paragraph → a way forward.
    private func noticeBlock(title: String, notice: Shape.Notice, capability: Shape.Capability) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ModelOptionRowTitle(text: title)
                Spacer(minLength: 8)
                ModelOptionStatusText(text: notice.status)
            }
            ModelOptionCaption(text: notice.body)
            if let link = notice.link {
                linkButton(link, capability: capability)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, notice.link == nil ? 15 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One status row. With a destination the whole row is tappable and has a chevron; without one it is plain text and does not pretend to be tappable.
    @ViewBuilder
    private func disclosureRow(
        title: String, disclosure: Shape.Disclosure, capability: Shape.Capability
    ) -> some View {
        if let action = disclosure.action {
            Button {
                onAction(.open(action, capability: capability))
            } label: {
                statusRow(title: title, status: disclosure.status, showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            statusRow(title: title, status: disclosure.status, showsChevron: false)
        }
    }

    private func statusRow(title: String, status: String, showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            ModelOptionRowTitle(text: title)
            Spacer(minLength: 8)
            ModelOptionStatusText(text: status)
            if showsChevron { ModelOptionChevron() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    /// Undecided protocol: the whole card says just that one thing and offers one primary button.
    private func calloutBlock(_ callout: Shape.Callout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ModelOptionRowTitle(text: callout.title)
                ModelOptionCaption(text: callout.body)
            }
            Button {
                onAction(.open(callout.link.action, capability: .reasoning))
            } label: {
                ModelOptionCalloutButtonLabel(title: callout.link.title)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.notes) { note in
                ModelOptionCaption(
                    text: note.text,
                    color: note.tone == .warning
                        ? OriveoTheme.Palette.warningText
                        : OriveoTheme.Palette.textSecondary
                )
                if note.opensAdvancedSettings {
                    Button {
                        onAction(.openAdvancedSettings)
                    } label: {
                        ModelOptionLinkLabel(title: L10n.tr("Go to Advanced Settings", table: .chat))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func linkButton(_ link: Shape.Link, capability: Shape.Capability) -> some View {
        Button {
            onAction(.open(link.action, capability: capability))
        } label: {
            ModelOptionLinkLabel(title: link.title)
        }
        .buttonStyle(.plain)
    }

    // MARK: Parameter card

    /// "Advanced settings": items changed in this conversation appear as chips, two at most, the rest only counted. With nothing changed,
    /// one sentence says what tapping through leads to.
    private var advancedCard: some View {
        Button {
            onAction(.openAdvancedSettings)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    ModelOptionRowTitle(text: L10n.tr("Advanced Settings"))
                    if model.advanced.chips.isEmpty {
                        ModelOptionCaption(text: L10n.tr(
                            "Max tokens, temperature, and other request parameters", table: .chat
                        ))
                    } else {
                        HStack(spacing: 6) {
                            ForEach(model.advanced.chips) { chip in
                                ModelOptionSettingChip(title: chip.title, value: chip.value)
                            }
                            if model.advanced.moreCount > 0 {
                                ModelOptionMoreChip(count: model.advanced.moreCount)
                                    .layoutPriority(1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ModelOptionChevron()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 74)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .modelControlSurface()
    }
}

// MARK: - Route

/// Routes that need a page of their own: the full set of request parameters (advanced settings), the additional request body editor, the candidate model list.
/// Web search and thinking expand in place. The additional request body is normally reached from advanced settings; the capability card's "Open additional request body" goes straight to it.
enum ModelControlsRoute: Hashable {
    case modelBehavior
    case additionalRequestBody
    case supportedModels(capability: String)
}

// MARK: - Editability

/// The production projection of whether the panel is writable. Entry visibility does not consume it; only in-page controls and persistence do.
nonisolated enum ModelControlsEditability: Equatable, Sendable {
    case writable
    case runtimeIdentityUnavailable
    case runtimeReadOnly

    static func resolve(
        providerKind: ProviderKind,
        transportIdentity: String?,
        runtimeIsReadOnly: Bool
    ) -> Self {
        guard transportIdentity?.isEmpty == false else { return .runtimeIdentityUnavailable }
        guard !runtimeIsReadOnly else { return .runtimeReadOnly }
        return .writable
    }

    var canPersist: Bool { self == .writable }

    // There is deliberately no separate status text for the trailing side of the advanced settings row:
    // it would say the same thing as the read-only banner at the top in different words. The reason for being read-only
    // is said once, by `reasonText` through that banner; a second copy of the sentence
    // on a trailing label would only repeat it.

    @MainActor var reasonText: String? {
        switch self {
        case .writable:
            return nil
        case .runtimeIdentityUnavailable:
            // The wording for this state comes from `ModelControlsIdentityGap`, by the real reason: inside the panel a model is always selected
            // (the unselected case goes to `ModelControlsMissingModelSheet`), so "choose a connection and a model" would be a lie.
            return nil
        case .runtimeReadOnly:
            return L10n.tr("Not ready", table: .chat)
        }
    }
}

/// The three real reasons a `transportIdentity` can be missing.
///
/// They call for three **entirely different** user actions, and folding them into one sentence is a dead end: showing "choose a connection and
/// a model to continue" with a link to the provider detail page fails a user who chose a model long ago, while the real reason
/// (the snapshot was not fetched) cannot be touched on that page at all; the user is sent to fix something that is not broken, and nothing changes.
/// A tappable button says "tapping me fixes this"; when it does not point at the cause it is worse than no button, which is exactly what
/// the "no grayed-out option" rule at the top of this file is about.
///
/// The root is one nil carrying several meanings and
/// being collapsed into a single answer by a fallback rule. **Before adding a case, answer this: for this reason, after the user taps that action,
/// does the state really change?** If not, give no button and just say what is the case.
nonisolated enum ModelControlsIdentityGap: Equatable, Sendable {
    /// The runtime snapshot is not ready (first cold start / offline / the delivered data cannot be decoded). Unrelated to this connection; fetching again fixes it.
    case runtimeSnapshotMissing
    /// The relay's protocol is still on Auto: the final transport is only known when the builder dispatches, and neither the UI nor
    /// persistence may invent one. The user can pin the protocol in the connection's settings; **this** is the case where
    /// a "review connection" entry is the right one.
    case relayTransportUndecided
    /// The catalog does not have this model (added by hand / removed / id mismatch after a provider generation change). Only another model helps.
    case modelNotInCatalog

    /// The one action that makes sense for each reason.
    ///
    /// It is a type of its own so that it **can be asserted**: a guard test that only checks whether the source contains
    /// a `Review connection` string verifies that the button exists and says nothing about where it leads;
    /// those are two different things, and dead ends slip through that gap.
    enum RecoveryAction: Hashable, Sendable, CaseIterable {
        /// Refetch metadata right here. The user stays in the panel, which unlocks in place once the data arrives.
        case refetchRuntime
        /// Go to the connection's settings and decide the protocol. **Only** the undecided relay protocol is solved this way.
        case openConnectionSettings
        /// Choose another model.
        case chooseAnotherModel
    }

    var recoveryAction: RecoveryAction {
        switch self {
        case .runtimeSnapshotMissing: return .refetchRuntime
        case .relayTransportUndecided: return .openConnectionSettings
        case .modelNotInCatalog: return .chooseAnotherModel
        }
    }

    /// The order matches the failure order of `CapabilityPreferenceRuntimeIdentity.make` exactly:
    /// the runtime revision is the first guard, and while it is not ready the other two cannot be determined, so they must not come first.
    static func resolve(
        providerKind: ProviderKind,
        relayTransportIsDecided: Bool,
        runtimeIsReady: Bool
    ) -> Self {
        if !runtimeIsReady { return .runtimeSnapshotMissing }
        if providerKind == .relay, !relayTransportIsDecided { return .relayTransportUndecided }
        return .modelNotInCatalog
    }

    @MainActor var reasonText: String {
        switch self {
        case .runtimeSnapshotMissing:
            return L10n.tr("Model settings haven't loaded yet, so these are read-only.", table: .chat)
        case .relayTransportUndecided:
            return L10n.tr(
                "This connection's protocol is still Auto, so these settings can't be prepared yet.",
                table: .chat
            )
        case .modelNotInCatalog:
            return L10n.tr(
                "This model isn't in the catalog, so which settings it supports can't be determined.",
                table: .chat
            )
        }
    }
}

/// A transport identifier is shown in plain words: printing a wire name such as `openai_responses` to the user means nothing.
///
/// **Two vocabularies must be recognized here.** Its caller `displayTransport` takes the rawValue of the local `RelayTransport`
/// for a relay (`openai_chat_completions` / `llamacpp_native`…) and the catalog transport for an official provider
/// (`openai_chat` / `gemini_generate`…). The two are **not interchangeable**: the same
/// Chat Completions protocol is two different strings on the two sides (the comment in `ProviderProductionBuilderMatrixTests`
/// spells this out). Listing only the relay set would drop every official `openai_chat` model
/// into the default case, and the subtitle would show an uninformative "Protocol".
/// When adding a catalog-side value, go by the values that actually occur in `.providers[].models[].transport` of the metadata,
/// not by the `RelayTransport` enum.
enum CapabilityTransportLabel {
    static func display(_ transport: String) -> String {
        switch CapabilityRecipeRequestCompiler.canonicalTransport(transport) {
        case "openai_responses": return "Responses"
        // The catalog's `openai_chat` and the relay's `openai_chat_completions` are the same protocol
        case "openai_chat", "openai_chat_completions": return "Chat Completions"
        case "anthropic_messages": return "Messages"
        // `gemini_generate` is normalized to this by canonicalTransport
        case "gemini_generate_content": return "generateContent"
        case "dashscope_native": return "DashScope"
        // The image line uses this table as well: the panel does not filter by modality, and a user who picked an image model on the chat page can still open it.
        case "openai_images": return "Images"
        case "gemini_image": return "imageGen"
        case "qwen_image": return "DashScope Image"
        case "grok_image": return "xAI Image"
        case "zhipu_image": return "Zhipu Image"
        case "llamacpp_native": return "llama.cpp"
        default: return L10n.tr("Protocol", table: .providers)
        }
    }
}
