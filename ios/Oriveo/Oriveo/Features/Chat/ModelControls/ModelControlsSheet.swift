import SwiftUI

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
        .presentationDetents([.large])
        .presentationCornerRadius(24)
    }
}

private struct ModelControlsCloseBar: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
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
    let transportIdentity: String?
    let runtimeIsReadOnly: Bool
    let runtimeReadOnlyReason: String
    @Binding var webEnabled: Bool
    @Binding var reasoningMode: ReasoningMode
    @Binding var reasoningIntentSelection: String?
    let onChooseConnection: () -> Void
    let onOpenConnectionSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState

    @State private var web: CapabilityWebPreference = .off
    @State private var reasoningIntent: String?
    @State private var customModes: [String: LocalCustomConfigurationMode] = [:]
    @State private var explanation: CapabilityExplanation?
    @State private var showsScopeUpgrade = false
    @State private var scopeUpgradeConfirmed = false
    @State private var path: [ModelControlsRoute] = []
    @State private var behaviorRevision = 0
    @State private var refreshedIdentity: String?
    @State private var isRefreshingRuntime = false
    @State private var runtimeRefreshFailed = false


    private var effectiveTransportIdentity: String? { transportIdentity ?? refreshedIdentity }

    private var editability: ModelControlsEditability {
        ModelControlsEditability.resolve(
            providerKind: provider.kind,
            transportIdentity: effectiveTransportIdentity,
            runtimeIsReadOnly: runtimeIsReadOnly
        )
    }

    private var identityGap: ModelControlsIdentityGap {
        ModelControlsIdentityGap.resolve(
            providerKind: provider.kind,
            relayTransportIsDecided: CapabilityPreferenceRuntimeIdentity.relayFinalTransport(
                provider: provider, resolvedFinalTransport: nil
            ) != nil,
            runtimeIsReady: MetadataClient.shared.syncCapabilityRecipeRuntime(
                modelID: model.id, providerKind: provider.kind
            ).runtime != nil
        )
    }

    private var readOnlyReasonText: String? {
        switch editability {
        case .runtimeReadOnly: return runtimeReadOnlyReason
        case .runtimeIdentityUnavailable: return identityGap.reasonText
        case .writable: return editability.reasonText
        }
    }
    private var capabilityModelID: String {
        CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)?.canonicalModelID ?? ""
    }
    private var generationProfileFingerprint: String {
        GenerationParameterProfileFingerprint.make(provider: provider, model: model)
    }
    private var localCustomForwardPort: CapabilityLocalCustomForwardPortContext {
        .init(providerKind: provider.kind, schemaModelID: model.id)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 24) {
                    subjectHeader

                    if let reason = readOnlyReasonText {
                        readOnlySummary(reason: reason)
                    }

                    capabilityList
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(OriveoTheme.Palette.background)
            .navigationTitle(model.name)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ModelControlsRoute.self, destination: destination)
            .onAppear(perform: restore)
            .alert(
                explanation?.title ?? "",
                isPresented: Binding(
                    get: { explanation != nil },
                    set: { if !$0 { explanation = nil } }
                ),
                presenting: explanation
            ) { detail in
                explanationActions(detail)
                Button(L10n.tr("OK"), role: .cancel) {}
            } message: { detail in
                Text(detail.message)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .presentationDetents([.large])
        .presentationCornerRadius(24)
        .transaction { transaction in
            guard reduceMotion else { return }
            transaction.animation = nil
            transaction.disablesAnimations = true
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
                capabilityHeader: generationCapabilityHeader,
                isReadOnly: !editability.canPersist
            )
            .onDisappear { behaviorRevision += 1 }
        case let .supportedModels(capability):
            CapabilitySupportedModelsPage(
                provider: provider,
                capability: capability,
                candidates: supportedModelCandidates(for: capability),
                onSelect: selectCandidateModel
            )
        }
    }

    // MARK: - Subject

    private var subjectHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProviderBadgeIcon(kind: provider.kind, size: 20, relayKind: provider.relayKind)
                Text(model.name)
                    .font(.headline)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(subjectSubtitle)
                .font(.caption)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private var subjectSubtitle: String {
        var parts = [provider.displayName]
        if let transport = customTransport, !transport.isEmpty {
            parts.append(CapabilityTransportLabel.display(transport))
        }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private func readOnlySummary(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ModelControlNote(text: reason, systemImage: "lock.fill")

            switch editability {
            case .runtimeIdentityUnavailable:
                identityRecoveryAction
            case .runtimeReadOnly, .writable:
                EmptyView()
            }
        }
        .padding(16)
        .modelControlSurface(cornerRadius: 20)
    }

    @ViewBuilder
    private var identityRecoveryAction: some View {
        switch identityGap.recoveryAction {
        case .refetchRuntime:
            Button {
                Task { await refreshRuntime() }
            } label: {
                ModelControlInlineActionLabel(
                    title: isRefreshingRuntime
                        ? L10n.tr("Fetching…", table: .chat)
                        : L10n.tr("Fetch again", table: .chat),
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.plain)
            .disabled(isRefreshingRuntime)

            if runtimeRefreshFailed {
                ModelControlNote(
                    text: L10n.tr("Still no luck. Check your network and try again.", table: .chat),
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                )
            }
        case .openConnectionSettings:
            Button(action: onOpenConnectionSettings) {
                ModelControlInlineActionLabel(
                    title: L10n.tr("Set the protocol", table: .chat),
                    systemImage: "gearshape"
                )
            }
            .buttonStyle(.plain)
        case .chooseAnotherModel:
            Button(action: onChooseConnection) {
                ModelControlInlineActionLabel(
                    title: L10n.tr("Choose another model", table: .chat),
                    systemImage: "arrow.triangle.branch"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func refreshRuntime() async {
        isRefreshingRuntime = true
        runtimeRefreshFailed = false
        await MetadataClient.shared.forceRefresh()
        let resolved = CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)?.wireValue
        refreshedIdentity = resolved
        isRefreshingRuntime = false
        if resolved == nil {
            runtimeRefreshFailed = true
        } else {
            restore()
        }
    }


    private var capabilityList: some View {
        VStack(spacing: 12) {
            webCard
            reasoningCard
            modelBehaviorCard
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 0) {
            if showsScopeUpgrade, path.isEmpty {
                ModelControlScopeUpgradeRow(isConfirmed: scopeUpgradeConfirmed) {
                    promoteSelectionToModelDefault()
                }
                .transition(.opacity)
            }
            ModelControlsCloseBar { dismiss() }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: showsScopeUpgrade)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: path.isEmpty)
    }

    private var modelBehaviorCard: some View {
        NavigationLink(value: ModelControlsRoute.modelBehavior) {
            ModelControlNavigationRow(
                icon: "slider.horizontal.3",
                accent: .generation,
                title: L10n.tr("Advanced Settings"),
                subtitle: L10n.tr(
                    "Max tokens, temperature, and other request parameters", table: .chat
                ),
                trailingText: modelBehaviorStatusText.isEmpty ? nil : modelBehaviorStatusText,
                badge: advancedSettingsBadge(
                    for: presentation(for: "generation"), overridden: isCustomActive("generation")
                )
            )
        }
        .buttonStyle(.plain)
        .id(behaviorRevision)
    }

    private var modelBehaviorStatusText: String {
        activeOverrideCount > 0
            ? String(format: L10n.tr("%d adjusted", table: .chat), activeOverrideCount)
            : ""
    }

    // MARK: - Web search

    private var webCard: some View {
        let status = presentation(for: "web")
        let overridden = isCustomActive("web")
        let layout = ModelControlWebLayout.layout(
            status: status,
            availableIntents: webIntents,
            selection: web,
            isEditable: editability.canPersist && !overridden,
            hasCustomSchema: hasSafeCustomSchema
        )

        return ModelControlCard(
            icon: "globe",
            accent: .web,
            title: L10n.tr("Web Search", table: .chat),
            subtitle: "",
            badge: capabilityCardBadge(for: status, overridden: overridden),
            toggle: layout.form == .toggle
                ? Binding(
                    get: { layout.isOn },
                    set: { enabled in
                        web = enabled ? .automatic : .off
                        persist()
                    }
                )
                : nil
        ) {
            switch layout.form {
            case .toggle:
                if let caption = layout.caption {
                    ModelControlNote(text: caption)
                }

                if !layout.timingOptions.isEmpty {
                    ModelControlIntentPicker(
                        options: layout.timingOptions, selection: layout.timingSelection
                    ) { raw in
                        guard let next = CapabilityWebPreference(rawValue: raw) else { return }
                        web = next
                        persist()
                    }
                }
            case .statusRow:
                statusRow(layout.statusText, capability: "web", detail: layout.explanation, escape: layout.escape)
            }

            footerEntries(
                capabilityFooterEntries(
                    capability: "web", status: status, overridden: overridden, context: .panelCard,
                    statusRowEscape: layout.form == .statusRow ? layout.escape : .none
                ),
                capability: "web"
            )
        }
    }


    private var reasoningCard: some View {
        let status = presentation(for: "reasoning")
        let overridden = isCustomActive("reasoning")
        let layout = ModelControlReasoningLayout.layout(
            status: status,
            intents: reasoningIntents,
            selectedIntent: reasoningIntent,
            isEditable: editability.canPersist && !overridden,
            hasCustomSchema: hasSafeCustomSchema
        )

        return ModelControlCard(
            icon: "sparkles",
            accent: .reasoning,
            title: L10n.tr("Thinking Mode", table: .chat),
            subtitle: "",
            badge: capabilityCardBadge(for: status, overridden: overridden)
        ) {
            switch layout.form {
            case .pillRow:
                VStack(alignment: .leading, spacing: 8) {
                    ModelControlIntentPicker(
                        options: layout.options, selection: layout.selection
                    ) { intent in
                        reasoningIntent = intent == ModelControlReasoningLayout.automaticIntent
                            ? nil
                            : intent
                        persist()
                    }
                    ModelControlNote(text: layout.selectedAnnotation)
                }
            case .statusRow:
                statusRow(
                    layout.statusText, capability: "reasoning",
                    detail: layout.explanation, escape: layout.escape
                )
            }

            if let footnote = layout.footnote {
                ModelControlNote(text: footnote)
            }

            footerEntries(
                capabilityFooterEntries(
                    capability: "reasoning", status: status, overridden: overridden, context: .panelCard,
                    statusRowEscape: layout.form == .statusRow ? layout.escape : .none
                ),
                capability: "reasoning"
            )
        }
    }


    private func statusRow(
        _ text: String,
        capability: String,
        detail: String?,
        escape: ModelControlCapabilityEscape
    ) -> some View {
        ModelControlStatusRow(
            text: text,
            action: detail.map { message in
                { presentExplanation(capability: capability, message: message, escape: escape) }
            }
        )
    }

    private func presentExplanation(
        capability: String, message: String, escape: ModelControlCapabilityEscape
    ) {
        var body = message
        var resolved = escape
        if escape == .supportedModels, supportedModelCandidates(for: capability).isEmpty {
            body += "\n\n" + L10n.tr("No models in this connection support this capability yet.", table: .chat)
            resolved = .none
        }
        explanation = CapabilityExplanation(
            title: capabilityTitle(capability), message: body, escape: resolved, capability: capability
        )
    }

    @ViewBuilder
    private func explanationActions(_ detail: CapabilityExplanation) -> some View {
        switch detail.escape {
        case .supportedModels:
            Button(L10n.tr("View supported models", table: .chat)) {
                path.append(.supportedModels(capability: detail.capability))
            }
        case .advancedSettings:
            Button(L10n.tr("Go to Advanced Settings", table: .chat)) {
                path.append(.modelBehavior)
            }
        case .none:
            EmptyView()
        }
    }

    private func capabilityTitle(_ capability: String) -> String {
        switch capability {
        case "web": return L10n.tr("Web Search", table: .chat)
        case "reasoning": return L10n.tr("Thinking Mode", table: .chat)
        default: return L10n.tr("Advanced Settings")
        }
    }


    private var generationCapabilityHeader: AnyView? {
        let status = presentation(for: "generation")
        let overridden = isCustomActive("generation")
        let entries = capabilityFooterEntries(
            capability: "generation", status: status, overridden: overridden,
            context: .behaviorPageHeader
        )
        guard !entries.isEmpty else { return nil }
        return AnyView(
            footerEntries(entries, capability: "generation")
                .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    private var activeOverrideCount: Int {
        GenerationParameterSettingsStore.shared.activeOverrideParameterIDs(
            providerID: provider.id,
            modelID: model.id,
            conversationID: conversationID,
            profileFingerprint: generationProfileFingerprint,
            activeParameterIDs: GenerationParameterLifecycle.activeParameterIDs(
                provider: provider, model: model, identity: nil
            )
        ).count
    }

    // MARK: - Shared footer

    private func capabilityFooterEntries(
        capability: String,
        status: CapabilityControlPresentation,
        overridden: Bool,
        context: ModelControlCapabilityFooter.Context,
        statusRowEscape: ModelControlCapabilityEscape = .none
    ) -> [ModelControlCapabilityFooter.Entry] {
        let showsSupportedModels = showsSupportedModelsAction(for: status, capability: capability)
        return ModelControlCapabilityFooter.entries(.init(
            context: context,
            overridden: overridden,
            readOnlyReason: readOnlyReasonText,
            isConfigurable: status.isConfigurable,
            statusText: statusText(status),
            upstreamRejected: upstreamRejected(capability: capability),
            riskTiers: CapabilityRecipeExecution.customControlRiskTiers(
                owner: capability, providerKind: provider.kind, modelID: model.id,
                transport: CapabilityRecipeExecution.finalTransport(
                    owner: capability, provider: provider, model: model
                ) ?? ""
            ),
            showsSupportedModelsAction: showsSupportedModels,
            hasSupportedModelCandidates: showsSupportedModels
                && !supportedModelCandidates(for: capability).isEmpty,
            showsAdvancedSettingsAction: overridden,
            statusRowEscape: statusRowEscape
        ))
    }

    @ViewBuilder
    private func footerEntries(
        _ entries: [ModelControlCapabilityFooter.Entry], capability: String
    ) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    switch entry {
                    case let .note(text, systemImage, tone):
                        ModelControlNote(text: text, systemImage: systemImage, tone: noteTone(tone))
                    case .supportedModelsLink:
                        NavigationLink(value: ModelControlsRoute.supportedModels(capability: capability)) {
                            ModelControlInlineActionLabel(
                                title: L10n.tr("View supported models", table: .chat),
                                systemImage: "arrow.triangle.swap"
                            )
                        }
                        .buttonStyle(.plain)
                    case .advancedSettingsLink:
                        NavigationLink(value: ModelControlsRoute.modelBehavior) {
                            ModelControlInlineActionLabel(
                                title: L10n.tr("Go to Advanced Settings", table: .chat),
                                systemImage: "curlybraces",
                                tint: OriveoTheme.Palette.textSecondary
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func noteTone(_ tone: ModelControlCapabilityFooter.Tone) -> Color {
        switch tone {
        case .tertiary: return OriveoTheme.Palette.textTertiary
        case .warning: return OriveoTheme.Palette.warningText
        }
    }

    private func isCustomActive(_ owner: String) -> Bool {
        customModes[owner, default: .automatic] == .custom
    }

    // MARK: - Status

    private func upstreamRejected(capability: String) -> Bool {
        guard let owner = RequestPreferenceOwner(rawValue: capability), owner != .generation else {
            return false
        }
        let keys = CapabilityRecipeRequestCompiler.capabilityEvidenceKeys(
            capability: owner,
            selectedIntent: owner == .reasoning ? reasoningIntent : nil
        )
        guard !keys.isEmpty,
              let identity = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider: provider, model: model, partitionID: appState.sessionPartitionUID
              ) ?? (provider.relayRequested == nil
                    ? CapabilityEvidenceRequestIdentity.make(
                        provider: provider, model: model, partitionID: appState.sessionPartitionUID,
                        hasExplicitValue: true
                      )
                    : nil) else { return false }
        let rejected = Set(UnsupportedParamCache.shared.capabilityRejectedCandidates(
            providerKind: provider.kind, modelID: model.id,
            endpointFingerprint: identity.query.endpointFingerprint, identity: identity
        ).map(\.key))
        return !rejected.isDisjoint(with: keys)
    }

    private func presentation(for capability: String) -> CapabilityControlPresentation {
        CapabilityControlPresentationResolver.presentation(
            provider: provider, model: model, capability: capability
        )
    }

    /// `ModelControlBadgeClassification.advancedSettingsCard`).
    private func advancedSettingsBadge(
        for status: CapabilityControlPresentation, overridden: Bool
    ) -> (tone: ModelControlStatusTone, text: String)? {
        badge(ModelControlBadgeClassification.advancedSettingsCard(status), overridden: overridden)
    }

    private func capabilityCardBadge(
        for status: CapabilityControlPresentation, overridden: Bool
    ) -> (tone: ModelControlStatusTone, text: String)? {
        badge(ModelControlBadgeClassification.capabilityCard(status), overridden: overridden)
    }

    private func badge(
        _ classification: ModelControlBadgeClassification, overridden: Bool
    ) -> (tone: ModelControlStatusTone, text: String)? {
        if overridden { return (.manual, L10n.tr("Custom", table: .chat)) }
        switch classification {
        case .none:
            return nil
        case .manual:
            return (.manual, L10n.tr("Manual", table: .chat))
        case .notReady:
            return (.manual, L10n.tr("Not ready", table: .chat))
        case .unavailable:
            return (.unavailable, L10n.tr("Unavailable", table: .chat))
        }
    }

    private func statusText(_ status: CapabilityControlPresentation) -> String {
        switch status {
        case .automaticAvailable: return L10n.tr("Automatic configuration available")
        case .forceUnsupported: return L10n.tr("Search every message requires an official recipe for this connection.")
        case .customOnly: return L10n.tr("This connection supports custom configuration only.", table: .chat)
        case .pending: return L10n.tr("Automatic configuration is not ready for this connection yet.", table: .chat)
        case .externalConnectorOnly:
            return L10n.tr(
                "This capability is provided by a separate external service, outside this connection's chat request.",
                table: .chat
            )
        case .unsupported: return L10n.tr("This capability is unavailable for this connection.", table: .chat)
        case .unknown: return L10n.tr("Automatic configuration is unavailable for the current model route.", table: .chat)
        }
    }

    private func showsSupportedModelsAction(
        for status: CapabilityControlPresentation, capability: String
    ) -> Bool {
        switch status {
        case .unsupported, .unknown, .pending, .externalConnectorOnly, .customOnly: return true
        case .automaticAvailable, .forceUnsupported: return false
        }
    }

    // MARK: - Resolution helpers

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

    private var webIntents: [String] {
        guard controls?["web"]?.state == RequestControlAvailability.autoAvailable.rawValue else { return [] }
        return controls?["web"]?.availableIntents ?? []
    }

    private var customTransport: String? {
        CapabilityRecipeExecution.displayTransport(provider: provider, model: model)
    }

    private var hasSafeCustomSchema: Bool {
        RequestPreferenceOwner.allCases.map(\.rawValue).contains { owner in
            CapabilityRecipeExecution.hasSafeCustomSchema(
                owner: owner, providerKind: provider.kind, modelID: model.id,
                transport: CapabilityRecipeExecution.finalTransport(
                    owner: owner, provider: provider, model: model
                ) ?? ""
            )
        }
    }

    private func supportedModelCandidates(for capability: String) -> [AIModel] {
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

    private func restore() {
        guard let transportIdentity = effectiveTransportIdentity else { return }
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
        scopeUpgradeConfirmed = false
        web = ModelControlWebLayout.clamp(
            web, status: presentation(for: "web"), availableIntents: webIntents
        )
        GenerationParameterSettingsStore.shared.setCapabilityPreferences(
            .init(web: web, reasoningIntent: reasoningIntent), providerID: provider.id,
            modelID: capabilityModelID, conversationID: conversationID, transportIdentity: transportIdentity
        )
        if conversationID != nil, !showsScopeUpgrade {
            showsScopeUpgrade = true
        }
        publishSelection()
    }

    private func promoteSelectionToModelDefault() {
        guard editability.canPersist, let transportIdentity = effectiveTransportIdentity else { return }
        GenerationParameterSettingsStore.shared.setCapabilityPreferences(
            .init(web: web, reasoningIntent: reasoningIntent), providerID: provider.id,
            modelID: capabilityModelID, conversationID: nil, transportIdentity: transportIdentity
        )
        scopeUpgradeConfirmed = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard scopeUpgradeConfirmed else { return }
            showsScopeUpgrade = false
            scopeUpgradeConfirmed = false
        }
    }

    private func publishSelection() {
        let nextWebEnabled = web != .off && CapabilityWebPreferenceLiveness.reachesTheWire(
            status: presentation(for: "web"), customIsActive: isCustomActive("web")
        )
        if webEnabled != nextWebEnabled { webEnabled = nextWebEnabled }
        let nextMode = ReasoningMode.fromIntent(reasoningIntent) ?? .automatic
        if reasoningMode != nextMode { reasoningMode = nextMode }
        if reasoningIntentSelection != reasoningIntent { reasoningIntentSelection = reasoningIntent }
    }

    private func namespace(for owner: String) -> String { "\(owner)Patch" }
}

// MARK: - Explanation

private struct CapabilityExplanation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let escape: ModelControlCapabilityEscape
    let capability: String
}

// MARK: - Route

enum ModelControlsRoute: Hashable {
    case modelBehavior
    case supportedModels(capability: String)
}

// MARK: - Presentation helpers

extension CapabilityControlPresentation {
    var isConfigurable: Bool {
        switch self {
        case .automaticAvailable, .forceUnsupported, .unknown: return true
        case .customOnly, .pending, .externalConnectorOnly, .unsupported:
            return false
        }
    }
}

nonisolated enum ModelControlBadgeClassification: Equatable, Sendable {
    case none
    case manual
    case notReady
    case unavailable

    static func resolve(_ status: CapabilityControlPresentation) -> Self {
        switch status {
        case .automaticAvailable, .forceUnsupported: return .none
        case .customOnly: return .manual
        case .pending, .unknown: return .notReady
        case .externalConnectorOnly, .unsupported: return .unavailable
        }
    }

    static func capabilityCard(_ status: CapabilityControlPresentation) -> Self {
        let classification = resolve(status)
        return classification == .unavailable ? .none : classification
    }

    static func advancedSettingsCard(_ status: CapabilityControlPresentation) -> Self {
        let classification = resolve(status)
        return classification == .notReady ? .none : classification
    }
}

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


    @MainActor var reasonText: String? {
        switch self {
        case .writable:
            return nil
        case .runtimeIdentityUnavailable:
            return nil
        case .runtimeReadOnly:
            return L10n.tr("Not ready", table: .chat)
        }
    }
}

nonisolated enum ModelControlsIdentityGap: Equatable, Sendable {
    case runtimeSnapshotMissing
    case relayTransportUndecided
    case modelNotInCatalog

    enum RecoveryAction: Hashable, Sendable, CaseIterable {
        case refetchRuntime
        case openConnectionSettings
        case chooseAnotherModel
    }

    var recoveryAction: RecoveryAction {
        switch self {
        case .runtimeSnapshotMissing: return .refetchRuntime
        case .relayTransportUndecided: return .openConnectionSettings
        case .modelNotInCatalog: return .chooseAnotherModel
        }
    }

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

enum CapabilityTransportLabel {
    static func display(_ transport: String) -> String {
        switch CapabilityRecipeRequestCompiler.canonicalTransport(transport) {
        case "openai_responses": return "Responses"
        case "openai_chat", "openai_chat_completions": return "Chat Completions"
        case "anthropic_messages": return "Messages"
        case "gemini_generate_content": return "generateContent"
        case "dashscope_native": return "DashScope"
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
