import Combine
import GRDB
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatScreenContext {
    let provider: Provider
    let model: AIModel?
    let needsConversationRepair: Bool
}

func resolveChatScreenContext(
    requestedProviderID: UUID?,
    requestedModelID: String?,
    providers: [Provider],
    activeModel: (provider: Provider, model: AIModel)?,
    primaryProvider: Provider?
) -> ChatScreenContext? {
    if let requestedProviderID,
       let provider = providers.first(where: { $0.id == requestedProviderID }) {
        let model = ProviderSelectionSnapshot.currentModel(
            storedModelID: requestedModelID,
            in: provider
        )
        let repairedModelID = requestedModelID.map {
            AppState.persistedConversationModelID(
                requestedModelID: $0,
                in: provider
            )
        }

        return ChatScreenContext(
            provider: provider,
            model: model,
            needsConversationRepair: repairedModelID != nil && repairedModelID != requestedModelID
        )
    }

    if let activeModel {
        return ChatScreenContext(
            provider: activeModel.provider,
            model: activeModel.model,
            needsConversationRepair: requestedProviderID != nil
        )
    }

    if let primaryProvider {
        return ChatScreenContext(
            provider: primaryProvider,
            model: ProviderSelectionSnapshot.defaultModel(in: primaryProvider),
            needsConversationRepair: requestedProviderID != nil
        )
    }

    return nil
}

/// The first send needs a user-owned key, a relay, or a local endpoint.
func shouldRequireBYOKKeyBeforeSend(
    providerKind: ProviderKind?,
    hasConfiguredKey: Bool
) -> Bool {
    // Require a user-owned key or local/relay endpoint before the first send.
    guard let providerKind else { return true }
    if providerKind == .relay {
        return !hasConfiguredKey
    }
    return !hasConfiguredKey
}


func attachmentByteLimitDisplayText(_ byteLimit: Int) -> String {
    let bytesPerMegabyte = 1024 * 1024
    guard byteLimit >= bytesPerMegabyte else {
        return "\(max(byteLimit, 0)) B"
    }
    let megabytes = Double(byteLimit) / Double(bytesPerMegabyte)
    if megabytes.rounded() == megabytes {
        return "\(Int(megabytes)) MB"
    }
    return String(format: "%.1f MB", megabytes)
}

func attachmentSizeLimitAlertMessage(byteLimit: Int) -> String {
    String(
        format: L10n.tr(
            "Files and images over %@ cannot be uploaded. Large uploads are slow on your network and are difficult for AI models to read reliably.",
            table: .chat
        ),
        attachmentByteLimitDisplayText(byteLimit)
    )
}

private func makeHistoricalProviderFallback(
    projection: ChatScreenProjection
) -> Provider? {
    guard let message = projection.messages.last else { return nil }

    return Provider(
        id: projection.providerID ?? message.providerID ?? UUID(),
        kind: message.providerKind,
        status: .issue(""),
        models: [],
        catalogModels: [],
        lastCheckedAt: nil,
        apiKey: "",
        apiKeyPreview: "",
        lastError: nil,
        baseURLText: nil,
        customName: message.providerKind == .relay ? message.providerName : nil
    )
}

struct ChatView: View {
    let conversationID: UUID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState

    @State private var composerText = ""
    @State private var modelPickerPresentation: ModelPickerPresentationSnapshot?
    @State private var pendingModelSelection: ModelPickerSelection?
    @State private var reasoningMode: ReasoningMode = .automatic
    @State private var reasoningIntentSelection: String?
    /// new-conversation default. Legacy persisted ON/OFF values are migrated by the
    /// model-control store when an existing conversation opens; a new draft starts closed.
    @State private var webEnabled = false
    @State private var isAtBottom = true
    @State private var autoScrollEnabled = true
    @State private var pendingAttachments: [Attachment] = []
    @State private var pendingQuoteContext: QuoteContext?
    @State private var pendingQuoteAttachedAt: Date?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var isProcessingAttachment = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showAttachmentSizeLimitAlert = false
    @State private var showDeleteConfirmation = false
    @State private var expensiveModelHint: ExpensiveModelHintData?
    @FocusState private var composerFocused: Bool
    @State private var bootstrapLoadFailed = false
    @State private var conversationObservation = CurrentConversationObservation()
    @State private var windowLoader = MessageWindowLoader()
    @State private var disclosureProvider: ProviderKind?
    @State private var pendingSendPayload: PendingSendPayload?
    @State private var showsMissingProviderKeyPrompt = false
    @State private var bootstrapWatchdogExpired = false
    @State private var historyRetryGeneration = 0
    @State private var generationParameterDraftSessionID = UUID()

    private static let bootstrapWatchdogSeconds: Double = 12

    private struct WatchdogKey: Equatable {
        let conversationID: UUID?
        let generation: Int
    }

    private struct PendingSendPayload: Equatable {
        let text: String
        let attachments: [Attachment]
        let quoteContext: QuoteContext?
        let capabilitySelection: ChatCapabilitySelection
    }

    private var projection: ChatScreenProjection {
        ChatScreenProjection(
            requestedConversationID: conversationID,
            summary: conversationObservation.summary,
            messages: windowLoader.messages,
            hasLoadedSummary: conversationObservation.hasLoadedInitialValue,
            messageRevision: windowLoader.revision,
            localLoadFailed: hasBootstrapFailure,
            bootstrapWatchdogExpired: bootstrapWatchdogExpired
        )
    }

    private var hasBootstrapFailure: Bool {
        bootstrapLoadFailed || conversationObservation.initialLoadFailed || windowLoader.initialLoadFailed
    }

    private var isComposerReadOnly: Bool {
        switch projection.loadState {
        case .stalled, .bootstrapping, .localFailure:
            return true
        case .content, .empty, .deleted:
            return false
        }
    }

    private var resolvedChatContext: ChatScreenContext? {
        resolveChatScreenContext(
            requestedProviderID: projection.providerID,
            requestedModelID: projection.modelID,
            providers: appState.providers,
            activeModel: appState.activeModel,
            primaryProvider: appState.primaryProvider ?? makeHistoricalProviderFallback(projection: projection)
        )
    }

    private var currentProviderKind: ProviderKind? {
        if let providerID = projection.providerID,
           let provider = appState.provider(for: providerID) {
            return provider.kind
        }
        return resolvedChatContext?.provider.kind
    }

    private var currentAttachmentImportContext: ChatAttachmentPicker.ImportContext {
        ChatAttachmentPicker.ImportContext(provider: resolvedChatContext?.provider)
    }

    private var currentAttachmentSupport: RelayRuntimeSupport.AttachmentSupport {
        currentAttachmentImportContext.attachmentSupport
    }

    private var currentFileExtractionLimits: FileExtractionLimits {
        FileExtractionLimits.resolve(model: resolvedChatContext?.model)
    }

    private var currentAttachmentByteLimit: Int {
        currentFileExtractionLimits.maxInputFileBytes
    }

    private func capabilityEvidenceIdentity(
        provider: Provider,
        model: AIModel
    ) -> CapabilityEvidenceRequestIdentity? {
        if let dispatch = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
            provider: provider,
            model: model,
            partitionID: appState.sessionPartitionUID
        ) {
            return dispatch
        }
        guard provider.relayRequested == nil else { return nil }
        return CapabilityEvidenceRequestIdentity.make(
            provider: provider,
            model: model,
            partitionID: appState.sessionPartitionUID,
            hasExplicitValue: false
        )
    }

    private func capabilityProjection(
        provider: Provider,
        model: AIModel,
        explicitKeys: Set<String> = []
    ) -> CapabilityEvidenceProjection {
        CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider,
            model: model,
            identity: capabilityEvidenceIdentity(provider: provider, model: model),
            keys: Set(["tool_call", "web_search", "vision_input"])
                .union(Set(ReasoningMode.allCases.filter { $0 != .automatic }
                    .map { "reasoning_level/\($0.rawValue)" })),
            explicitKeys: explicitKeys
        )
    }

    private func explicitGenerationParameterIDs(
        provider: Provider,
        model: AIModel
    ) -> Set<String> {
        let scopeID = conversationID ?? generationParameterDraftSessionID
        let resolved = GenerationParameterSettingsStore.shared.resolve(
            transient: nil,
            providerID: provider.id,
            modelID: model.id,
            conversationID: scopeID,
            reasoningMode: reasoningMode
        )
        return Set((resolved?.values ?? [:]).keys.map(UnsupportedParamClassifier.normalize))
    }

    private func generationProjection(
        provider: Provider,
        model: AIModel
    ) -> GenerationParameterEvidenceProjection {
        CapabilityEvidenceProductionAdapter.generationProjection(
            provider: provider,
            model: model,
            identity: capabilityEvidenceIdentity(provider: provider, model: model),
            explicitParameterIDs: explicitGenerationParameterIDs(provider: provider, model: model)
        )
    }

    private func capabilityControlVisible(
        _ resolution: CapabilityEvidenceFacade.Resolution?
    ) -> Bool {
        guard let resolution else { return false }
        if resolution.support == .supported { return true }
        return resolution.support == .unknown
            && resolution.source == .relayDeclaration
            && (resolution.grade == .acceptedUnverified || resolution.grade == .declared)
    }

    private func visibleCapabilityKeys(
        from projection: CapabilityEvidenceProjection
    ) -> Set<String> {
        Set(projection.resolutions.compactMap { key, resolution in
            capabilityControlVisible(resolution) ? key : nil
        })
    }

    private var currentSupportsImageAttachment: Bool {
        guard let context = resolvedChatContext, let model = context.model else { return false }
        return capabilityControlVisible(
            capabilityProjection(provider: context.provider, model: model)
                .resolution(for: "vision_input")
        )
            && currentAttachmentSupport.image
    }

    private var currentSupportsVideoAttachment: Bool {
        resolvedChatContext?.model?.capabilities.contains(.video) == true && currentAttachmentSupport.video
    }

    private var currentSupportsFileAttachment: Bool {
        currentAttachmentSupport.nativeFile || currentAttachmentSupport.textFileInline
    }

    private func performSend(
        text: String,
        attachments: [Attachment],
        quoteContext: QuoteContext?,
        capabilitySelection: ChatCapabilitySelection
    ) {
        autoScrollEnabled = true
        composerFocused = false
        if let resolvedChatContext {
            appState.prepareConversationSelectionForSend(
                conversationID: projection.activeConversationID,
                providerID: resolvedChatContext.provider.id,
                modelID: resolvedChatContext.model?.id,
                needsRepair: resolvedChatContext.needsConversationRepair
            )
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            composerText = ""
            pendingAttachments = []
            pendingQuoteContext = nil
        }
        withAnimation { expensiveModelHint = nil }
        Task {
            let sentConversationID = await appState.sendMessage(
                text,
                attachments: attachments,
                quoteContext: quoteContext,
                in: projection.activeConversationID,
                generationParameterDraftSessionID: generationParameterDraftSessionID,
                capabilitySelection: capabilitySelection
            )
            if sentConversationID == nil {
                composerText = text
                pendingAttachments = attachments
                pendingQuoteContext = quoteContext
            }
        }
    }

    private func handleComposerSend(
        text: String,
        attachments: [Attachment],
        capabilitySelection: ChatCapabilitySelection
    ) {
        let payload = PendingSendPayload(
            text: text,
            attachments: attachments,
            quoteContext: pendingQuoteContext,
            capabilitySelection: capabilitySelection
        )
        if shouldRequireBYOKKeyBeforeSend(
            providerKind: currentProviderKind,
            hasConfiguredKey: appState.hasConfiguredProviderKey
        ) {
            pendingSendPayload = payload
            showsMissingProviderKeyPrompt = true
            return
        }
        routeSendAfterDisclosure(payload)
    }

    private func routeSendAfterDisclosure(_ payload: PendingSendPayload) {
        if let kind = currentProviderKind,
           kind.requiresVendorDisclosure,
           !ProviderDisclosureStore.hasAccepted(kind) {
            pendingSendPayload = payload
            disclosureProvider = kind
            return
        }
        performSend(
            text: payload.text,
            attachments: payload.attachments,
            quoteContext: payload.quoteContext,
            capabilitySelection: payload.capabilitySelection
        )
    }

    private var preferredAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.38, dampingFraction: 0.82)
    }

    private func commitPendingModelSelection() {
        guard let selection = pendingModelSelection else { return }
        pendingModelSelection = nil
        guard case .chat(let conversationID) = selection.context else { return }
        appState.selectModel(
            modelID: selection.modelID,
            providerID: selection.providerID,
            for: conversationID
        )
    }

    private func presentModelPicker() {
        guard modelPickerPresentation == nil else { return }
        let pickerConversationID = projection.activeConversationID ?? conversationID
        let pickerConversation = pickerConversationID.flatMap { appState.conversation(for: $0) }
        let active = appState.activeModel
        modelPickerPresentation = ModelPickerPresentationSnapshot(
            context: .chat(conversationID: pickerConversationID),
            providers: appState.providers,
            providersVersion: appState.providersVersion,
            currentProviderID: pickerConversation?.providerID ?? active?.provider.id,
            currentModel: pickerConversation.flatMap { appState.currentModel(for: $0) } ?? active?.model
        )
    }

    private func syncCapabilitySelection(for model: AIModel?) {
        guard let context = resolvedChatContext, let model else { return }
        let explicitKeys: Set<String> = [
            webEnabled ? "web_search" : nil,
            reasoningMode == .automatic ? nil : "reasoning_level/\(reasoningMode.rawValue)",
        ].compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }
        let projection = capabilityProjection(
            provider: context.provider,
            model: model,
            explicitKeys: explicitKeys
        )
        let supportsReasoning = reasoningMode == .automatic
            || (capabilityControlVisible(
                projection.resolution(for: "reasoning_level/\(reasoningMode.rawValue)")
            ) && projection.permitsOutbound("reasoning_level/\(reasoningMode.rawValue)"))
        // unavailable/unknown affects only this send's automatic recipe. Never overwrite
        // the user's stored request intent merely because the current metadata cannot apply it.
        if !supportsReasoning { reasoningMode = .automatic }
    }

    /// Production lifecycle migration/restoration - intentionally runs when a conversation opens,
    /// model changes, or Relay transport changes, never only when the settings sheet is opened.
    /// The old composer switch was process-local and defaulted ON; a persisted existing conversation
    /// therefore migrates that legacy effective default to `automatic`, while a new draft stays off.
    private func restoreCapabilityPreferences(
        provider: Provider,
        model: AIModel?,
        conversationID: UUID?
    ) {
        guard let model else {
            return
        }
        let runtimeIdentity = CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model)
        let values = GenerationParameterSettingsStore.shared.displayCapabilityPreferences(
            providerID: provider.id,
            modelID: runtimeIdentity?.canonicalModelID ?? "",
            conversationID: conversationID ?? generationParameterDraftSessionID,
            skillID: nil,
            transportIdentity: runtimeIdentity?.wireValue ?? ""
        )
        webEnabled = values.web != .off
        reasoningIntentSelection = values.reasoningIntent
        reasoningMode = ReasoningMode.fromIntent(values.reasoningIntent) ?? .automatic
    }

    private func evaluateExpensiveModelHint(oldModelID: String, newModelID: String) {
        guard let provider = resolvedChatContext?.provider else {
            expensiveModelHint = nil
            return
        }

        let oldModel = resolveModelDetails(in: provider, modelID: oldModelID)
        let newModel = resolveModelDetails(in: provider, modelID: newModelID)

        if let multiplier = evaluateExpensiveModelMultiplier(
            oldPromptPrice: oldModel?.promptPrice,
            newPromptPrice: newModel?.promptPrice,
            threshold: expensiveModelRatioThreshold
        ) {
            expensiveModelHint = ExpensiveModelHintData(
                newModelName: newModel?.name ?? newModelID,
                oldModelName: oldModel?.name ?? oldModelID,
                multiplier: multiplier
            )
        } else {
            expensiveModelHint = nil
        }
    }

    var body: some View {
        Group {
            if projection.loadState == .localFailure {
                conversationBootstrapFailureState
            } else if projection.loadState == .stalled {
                conversationStalledState
            } else if projection.loadState == .deleted {
                Color.clear.onAppear {
                    if appState.navigation.path.last == .chat(conversationID: conversationID) {
                        appState.navigation.path.removeLast()
                    }
                }
            } else if let resolvedChatContext {
                chatContent(
                    projection: projection,
                    provider: resolvedChatContext.provider,
                    currentModel: resolvedChatContext.model,
                    isSendingMessage: projection.isSendingMessage
                )
            } else {
                VStack(spacing: OriveoTheme.Spacing.md) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    Text(L10n.tr("The provider for this conversation has been removed."))
                        .font(OriveoTheme.Typography.body)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .oriveoScreenBackground()
            }
        }
        .sheet(item: $modelPickerPresentation, onDismiss: commitPendingModelSelection) { presentation in
            let pickerConversationID = projection.activeConversationID ?? conversationID
            ModelPickerSheet(
                context: .chat(conversationID: pickerConversationID),
                presentation: presentation,
                onSelect: { pendingModelSelection = $0 }
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .environment(appState)
        }
        .sheet(item: $disclosureProvider) { kind in
            ProviderDisclosureSheet(
                provider: kind,
                onAccept: {
                    ProviderDisclosureStore.markAccepted(kind)
                    if let payload = pendingSendPayload {
                        performSend(
                            text: payload.text,
                            attachments: payload.attachments,
                            quoteContext: payload.quoteContext,
                            capabilitySelection: payload.capabilitySelection
                        )
                    }
                    pendingSendPayload = nil
                },
                onCancel: {
                    pendingSendPayload = nil
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
        .alert(
            L10n.tr("Add an API Key"),
            isPresented: $showsMissingProviderKeyPrompt
        ) {
            Button(L10n.tr("Cancel"), role: .cancel) {
                pendingSendPayload = nil
            }
            Button(L10n.tr("Add Provider")) {
                pendingSendPayload = nil
                appState.openProviderSetup(from: .providers)
            }
        } message: {
            Text(L10n.tr("Add a provider API key to send messages."))
        }
        .task(id: conversationID) {
            await bootstrapObservations(for: conversationID)
        }
        .task(id: WatchdogKey(
            conversationID: conversationID,
            generation: historyRetryGeneration
        )) {
            bootstrapWatchdogExpired = false
            guard conversationID != nil else { return }
            try? await Task.sleep(for: .seconds(Self.bootstrapWatchdogSeconds))
            guard !Task.isCancelled else { return }
            guard projection.loadState == .bootstrapping else { return }
            bootstrapWatchdogExpired = true
        }
    }

    private var conversationBootstrapFailureState: some View {
        VStack(spacing: OriveoTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)

            Button(L10n.tr("Retry")) {
                Task {
                    await bootstrapObservations(for: conversationID)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .oriveoScreenBackground()
    }

    private var conversationStalledState: some View {
        VStack(spacing: OriveoTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)

            Text(L10n.tr("Messages aren't available yet", table: .chat))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .multilineTextAlignment(.center)

            Text(L10n.tr(
                "We couldn't load this conversation's history. Check your connection and try again.",
                table: .chat
            ))
            .font(OriveoTheme.Typography.body)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, OriveoTheme.Spacing.lg)

            Button(L10n.tr("Retry")) {
                retryConversationHistory()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .oriveoScreenBackground()
    }

    private func retryConversationHistory() {
        bootstrapWatchdogExpired = false
        historyRetryGeneration &+= 1
        Task {
            await bootstrapObservations(for: conversationID)
        }
    }

    @ViewBuilder
    private func returnToNoteBar(noteID: UUID) -> some View {
        Button {
            appState.activeReturnToNoteID = nil
            appState.openNoteDetail(noteID: noteID)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.tr("Back to note", table: .notes))
                    .font(OriveoTheme.Typography.footnote)
                Spacer(minLength: 0)
            }
            .foregroundStyle(OriveoTheme.Palette.primary)
            .padding(.horizontal, OriveoTheme.Spacing.lg)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bootstrapObservations(for conversationID: UUID?) async {
        bootstrapLoadFailed = false

        guard let conversationID else {
            conversationObservation.stop()
            windowLoader.stop()
            return
        }

        do {
            let dbPool = try DatabaseManager.shared.openCurrent()
            var anchor: MessageWindowLoader.WindowAnchor = .latest
            if let searchTarget = appState.pendingSearchScrollTarget,
               searchTarget.conversationID == conversationID {
                let matchID = try? await dbPool.read { db in
                    try ConversationStore.fetchSearchMatchMessageID(
                        db: db,
                        conversationID: conversationID,
                        query: searchTarget.query
                    )
                }
                if let matchID {
                    anchor = .messageID(matchID)
                }
            }
            if let jump = appState.pendingNoteSourceJump,
               jump.conversationID == conversationID,
               let messageID = jump.messageID {
                anchor = .messageID(messageID)
            }
            conversationObservation.observe(conversationID: conversationID, in: dbPool)
            windowLoader.observe(
                conversationID: conversationID,
                anchor: anchor,
                in: dbPool,
                remoteAnchorHydrator: { _, _ in [] }
            )
            appState.seedPinnedNotes(for: conversationID)
        } catch {
            conversationObservation.stop()
            windowLoader.stop()
            bootstrapLoadFailed = true
        }
    }

    private func chatContent(
        projection: ChatScreenProjection,
        provider: Provider,
        currentModel: AIModel?,
        isSendingMessage: Bool
    ) -> some View {
        let _ = CapabilityEvidenceObservationBridge.shared.contentRevision
        let webIsExplicit = webEnabled && (currentModel.map {
            CapabilityWebPreferenceLiveness.reachesTheWire(
                provider: provider, model: $0,
                conversationID: projection.activeConversationID ?? generationParameterDraftSessionID
            )
        } ?? false)
        let explicitKeys: Set<String> = [
            webIsExplicit ? "web_search" : nil,
            reasoningMode == .automatic ? nil : "reasoning_level/\(reasoningMode.rawValue)",
        ].compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }
        let evidenceProjection = currentModel.map {
            capabilityProjection(provider: provider, model: $0, explicitKeys: explicitKeys)
        }
        let reasoningAllowed = reasoningMode == .automatic
            || (capabilityControlVisible(
                evidenceProjection?.resolution(for: "reasoning_level/\(reasoningMode.rawValue)")
            ) && evidenceProjection?.permitsOutbound("reasoning_level/\(reasoningMode.rawValue)") == true)
        let webAllowed = evidenceProjection?.permitsOutbound("web_search") == true
        let reasoningVerdict = currentModel.map {
            CapabilityControlResolution.resolve(provider: provider, model: $0, capability: "reasoning")
        }
        let reasoningIntentAllowed = reasoningIntentSelection.map { intent in
            reasoningVerdict?.isAvailable == true && reasoningVerdict?.intents.contains(intent) == true
        } ?? false
        let capabilityDecision = ChatCapabilityOutboundDecision.resolve(
            webRequested: webEnabled,
            webPermitted: webAllowed,
            reasoningModeRequested: reasoningMode,
            reasoningModePermitted: reasoningAllowed,
            reasoningIntentRequested: reasoningIntentSelection,
            reasoningIntentPermitted: reasoningIntentAllowed
        )
        let composerVisibleCapabilityKeys = evidenceProjection.map(visibleCapabilityKeys(from:)) ?? []
        let capabilitySelection = ChatCapabilitySelection(
            reasoningMode: capabilityDecision.reasoningMode,
            webSearchEnabled: capabilityDecision.webSearchEnabled
        )

        let content = VStack(spacing: 0) {
            ChatToolbar(
                projection: projection,
                provider: provider,
                currentModel: currentModel,
                isSendingMessage: isSendingMessage,
                transparentChrome: projection.messages.isEmpty,
                showModelSwitcher: Binding(
                    get: { modelPickerPresentation != nil },
                    set: { if $0 { presentModelPicker() } else { modelPickerPresentation = nil } }
                ),
                showDeleteConfirmation: $showDeleteConfirmation
            )

            if let noteID = appState.activeReturnToNoteID {
                returnToNoteBar(noteID: noteID)
            }

            chatMessageList(
                projection: projection,
                conversationID: projection.activeConversationID,
                isSendingMessage: isSendingMessage,
                capabilitySelection: capabilitySelection,
                bottomOverlayInset: 0,
                scrollButtonBottomInset: OriveoTheme.Spacing.md
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                chatBottomInset(
                    projection: projection,
                    provider: provider,
                    currentModel: currentModel,
                    visibleCapabilityKeys: composerVisibleCapabilityKeys,
                    capabilityEvidenceIdentity: evidenceProjection?.identity,
                    isSendingMessage: isSendingMessage,
                    capabilitySelection: capabilitySelection,
                    capabilityDecision: capabilityDecision
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        let styledContent = content
        .background(ChatEmptyStateAurora(prominent: projection.messages.isEmpty))
        .oriveoScreenBackground()
        .animation(preferredAnimation, value: expensiveModelHint)

        let modelObservedContent = styledContent
        .onChange(of: currentModel?.id) { oldModelID, newModelID in
            guard let oldID = oldModelID, let newID = newModelID, oldID != newID else { return }
            evaluateExpensiveModelHint(oldModelID: oldID, newModelID: newID)
            restoreCapabilityPreferences(provider: provider, model: currentModel, conversationID: projection.activeConversationID)
            syncCapabilitySelection(for: currentModel)
            pruneUnsupportedPendingAttachments()
        }
        .onChange(of: currentModel?.reasoningProfile) { _, _ in
            syncCapabilitySelection(for: currentModel)
        }
        .onChange(of: currentModel?.reasoningModeAvailable) { _, _ in
            syncCapabilitySelection(for: currentModel)
        }
        .onChange(of: currentModel?.capabilities) { _, _ in
            syncCapabilitySelection(for: currentModel)
            pruneUnsupportedPendingAttachments()
        }
        let lifecycleContent = modelObservedContent
        .onChange(of: resolvedChatContext?.provider.id) { _, _ in
            restoreCapabilityPreferences(provider: provider, model: currentModel, conversationID: projection.activeConversationID)
            pruneUnsupportedPendingAttachments()
        }
        .onChange(of: resolvedChatContext?.provider.relayRequested?.transport) { _, _ in
            restoreCapabilityPreferences(provider: provider, model: currentModel, conversationID: projection.activeConversationID)
            pruneUnsupportedPendingAttachments()
        }
        .onChange(of: isSendingMessage) { oldValue, newValue in
            if !oldValue && newValue && isAtBottom {
                autoScrollEnabled = true
            }
        }
        .onAppear {
            restoreCapabilityPreferences(provider: provider, model: currentModel, conversationID: projection.activeConversationID)
            handleAppear(currentModel: currentModel)
        }
        .onChange(of: projection.draftText) { _, draftText in
            guard !composerFocused else { return }
            let shouldApplyDraft = composerText != draftText
            guard shouldApplyDraft else { return }
            composerText = draftText
        }
        .onChange(of: composerText) { _, newValue in
            guard let conversationID = projection.activeConversationID else { return }
            guard !composerFocused else { return }
            syncDraftIfNeeded(newValue, in: conversationID)
        }
        .onChange(of: composerFocused) { _, focused in
            guard !focused else { return }
            if let conversationID = projection.activeConversationID {
                syncDraftIfNeeded(composerText, in: conversationID)
            }
        }
        .onChange(of: pendingQuoteContext) { oldValue, newValue in
            guard oldValue != newValue else { return }
            pendingQuoteAttachedAt = newValue == nil ? nil : Date()
        }
        .onDisappear(perform: handleDisappear)

        return lifecycleContent
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItems, matching: .images)
        .onChange(of: selectedPhotoItems) { _, items in
            handleSelectedPhotoItems(items)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCapture { image in
                showCamera = false
                if let image {
                    handleCapturedImage(image)
                }
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: ChatAttachmentImportPolicy.supportedFileContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImportedFiles(result)
        }
        .alert(
            L10n.tr("Delete this conversation?"),
            isPresented: $showDeleteConfirmation
        ) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Delete"), role: .destructive) {
                if let conversationID = projection.activeConversationID {
                    withAnimation {
                        appState.deleteConversation(id: conversationID)
                    }
                }
            }
        } message: {
            let refCount = projection.activeConversationID.map { appState.noteManager.referenceCount(conversationID: $0) } ?? 0
            if refCount > 0 {
                Text(L10n.tr("This conversation and all its messages will be permanently deleted.")
                    + "\n\n" + String(format: L10n.tr("This conversation is referenced by %d notes.", table: .notes), refCount))
            } else {
                Text(L10n.tr("This conversation and all its messages will be permanently deleted."))
            }
        }
        .alert(
            L10n.tr("File too large", table: .chat),
            isPresented: $showAttachmentSizeLimitAlert
        ) {
            Button(L10n.tr("OK"), role: .cancel) {}
        } message: {
            Text(attachmentSizeLimitAlertMessage(byteLimit: currentAttachmentByteLimit))
        }
    }

    @ViewBuilder
    private func chatBottomInset(
        projection: ChatScreenProjection,
        provider: Provider,
        currentModel: AIModel?,
        visibleCapabilityKeys: Set<String>,
        capabilityEvidenceIdentity: CapabilityEvidenceRequestIdentity?,
        isSendingMessage: Bool,
        capabilitySelection: ChatCapabilitySelection,
        capabilityDecision: ChatCapabilityOutboundDecision
    ) -> some View {
        VStack(spacing: 0) {
            if let hint = expensiveModelHint {
                HStack(spacing: OriveoTheme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.warning)

                    Text(String(format: L10n.tr("%1$@ costs ~%2$ldx more than %3$@", table: .chat), hint.newModelName, hint.multiplier, hint.oldModelName))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(2)

                    Spacer()

                    Button {
                        withAnimation { expensiveModelHint = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, OriveoTheme.Spacing.lg)
                .padding(.vertical, OriveoTheme.Spacing.sm)
                .background(OriveoTheme.Palette.warning.opacity(0.08))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ChatComposerBar(
                provider: provider,
                currentModel: currentModel,
                visibleCapabilityKeys: visibleCapabilityKeys,
                capabilityEvidenceIdentity: capabilityEvidenceIdentity,
                generationProjection: currentModel.map {
                    generationProjection(provider: provider, model: $0)
                },
                capabilityDecision: capabilityDecision,
                isSendingMessage: isSendingMessage,
                conversationID: projection.activeConversationID,
                generationParameterScopeID: projection.activeConversationID ?? generationParameterDraftSessionID,
                isReadOnly: isComposerReadOnly,
                transparentChrome: projection.messages.isEmpty,
                composerText: $composerText,
                pendingAttachments: $pendingAttachments,
                pendingQuoteContext: $pendingQuoteContext,
                reasoningMode: $reasoningMode,
                reasoningIntentSelection: $reasoningIntentSelection,
                webEnabled: $webEnabled,
                composerFocused: $composerFocused,
                onSend: { text, attachments in
                    handleComposerSend(
                        text: text,
                        attachments: attachments,
                        capabilitySelection: capabilitySelection
                    )
                },
                onChooseModel: presentModelPicker,
                onCancel: {
                    guard let conversationID = projection.activeConversationID else { return }
                    appState.cancelGeneration(in: conversationID)
                },
                onShowPhotoPicker: { showPhotoPicker = true },
                onShowCamera: { showCamera = true },
                onShowFileImporter: { showFileImporter = true }
            )
        }
    }

    @ViewBuilder
    private func chatMessageList(
        projection: ChatScreenProjection,
        conversationID: UUID?,
        isSendingMessage: Bool,
        capabilitySelection: ChatCapabilitySelection,
        bottomOverlayInset: CGFloat,
        scrollButtonBottomInset: CGFloat
    ) -> some View {
        ChatMessageList(
            projection: projection,
            conversationID: conversationID,
            isSendingMessage: isSendingMessage,
            capabilitySelection: capabilitySelection,
            bottomOverlayInset: bottomOverlayInset,
            scrollButtonBottomInset: scrollButtonBottomInset,
            windowLoader: windowLoader,
            isAtBottom: $isAtBottom,
            autoScrollEnabled: $autoScrollEnabled,
            composerText: $composerText,
            pendingQuoteContext: $pendingQuoteContext,
            showModelSwitcher: Binding(
                get: { modelPickerPresentation != nil },
                set: { if $0 { presentModelPicker() } else { modelPickerPresentation = nil } }
            ),
            composerFocused: $composerFocused
        )
        .id(conversationID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleSelectedPhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }

        let snapshot = items
        selectedPhotoItems = []
        isProcessingAttachment = true
        let byteLimit = currentAttachmentByteLimit
        let partitionUID = appState.sessionPartitionUID

        Task(priority: .userInitiated) {
            let (attachments, oversizedCount) = await Self.processPhotoItems(
                snapshot,
                byteLimit: byteLimit,
                partitionUID: partitionUID
            )
            guard appState.sessionPartitionUID == partitionUID else { return }
            applyImportedAttachments(attachments, source: "photo_library")
            if oversizedCount > 0 {
                await MainActor.run {
                    showAttachmentSizeLimitAlert = true
                }
            }
        }
    }

    private func handleCapturedImage(_ image: UIImage) {
        isProcessingAttachment = true
        let byteLimit = currentAttachmentByteLimit
        let partitionUID = appState.sessionPartitionUID

        Task(priority: .userInitiated) {
            let result = await Task.detached(priority: .userInitiated) {
                ChatAttachmentPicker.processCapturedImage(
                    image,
                    byteLimit: byteLimit,
                    partitionUID: partitionUID
                )
            }.value
            guard appState.sessionPartitionUID == partitionUID else { return }
            switch result {
            case .imported(let attachment):
                applyImportedAttachments([attachment], source: "camera")
            case .oversized:
                await MainActor.run {
                    isProcessingAttachment = false
                    showAttachmentSizeLimitAlert = true
                }
            case .unsupported, .extractionFailed:
                await MainActor.run { isProcessingAttachment = false }
            }
        }
    }

    private func handleImportedFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }

        let importContext = currentAttachmentImportContext
        let extractionLimits = currentFileExtractionLimits
        isProcessingAttachment = true
        let byteLimit = currentAttachmentByteLimit

        Task(priority: .userInitiated) {
            let (attachments, rejectedCount, oversizedCount) = await Self.processFileURLs(
                urls,
                importContext: importContext,
                byteLimit: byteLimit,
                extractionLimits: extractionLimits
            )
            applyImportedAttachments(attachments, source: "file")
            if oversizedCount > 0 {
                await MainActor.run {
                    showAttachmentSizeLimitAlert = true
                }
            }
            if rejectedCount > 0 {
                await MainActor.run {
                    ToastManager.shared.show(L10n.tr("Unsupported file format"))
                }
            }
        }
    }

    nonisolated
    private static func processPhotoItems(
        _ items: [PhotosPickerItem],
        byteLimit: Int,
        partitionUID: String
    ) async -> (attachments: [Attachment], oversizedCount: Int) {
        var results: [Attachment] = []
        var oversized = 0
        for item in items {
            switch await ChatAttachmentPicker.processPhotoItem(
                item,
                byteLimit: byteLimit,
                partitionUID: partitionUID
            ) {
            case .imported(let attachment):
                results.append(attachment)
            case .oversized:
                oversized += 1
            case .unsupported:
                break
            case .extractionFailed:
                break
            }
        }
        return (results, oversized)
    }

    nonisolated
    private static func processFileURLs(
        _ urls: [URL],
        importContext: ChatAttachmentPicker.ImportContext,
        byteLimit: Int,
        extractionLimits: FileExtractionLimits
    ) async -> (attachments: [Attachment], rejectedCount: Int, oversizedCount: Int) {
        var results: [Attachment] = []
        var rejected = 0
        var oversized = 0
        for url in urls {
            switch await ChatAttachmentPicker.processFileURL(
                url,
                importContext: importContext,
                byteLimit: byteLimit,
                extractionLimits: extractionLimits
            ) {
            case .imported(let attachment):
                results.append(attachment)
            case .oversized:
                oversized += 1
            case .unsupported:
                rejected += 1
            case .extractionFailed(let code, let fileName):
                rejected += 1
                let _fileName = fileName
                Task { @MainActor in
                    ToastManager.shared.show(
                        String(format: L10n.tr("file_extraction_error_generic", table: .chat), _fileName)
                    )
                }
                _ = code
            }
        }
        return (results, rejected, oversized)
    }

    private func pruneUnsupportedPendingAttachments() {
        guard !pendingAttachments.isEmpty else { return }
        let supportsImage = currentSupportsImageAttachment
        let supportsVideo = currentSupportsVideoAttachment
        let supportsFile = currentSupportsFileAttachment
        pendingAttachments.removeAll { attachment in
            switch attachment.kind {
            case .image:
                return !supportsImage
            case .video:
                return !supportsVideo
            case .file:
                return !supportsFile
            }
        }
    }

    @MainActor
    private func applyImportedAttachments(_ attachments: [Attachment], source: String = "unknown") {
        let limited = AttachmentImportLimiter.limit(
            existing: pendingAttachments,
            incoming: attachments,
            maxAttachments: currentFileExtractionLimits.maxFiles
        )

        if !limited.accepted.isEmpty {
            pendingAttachments += limited.accepted
            pruneUnsupportedPendingAttachments()
        }
        if limited.rejectedCount > 0 {
            ToastManager.shared.show(
                String(
                    format: L10n.tr("file_attachment_count_limit_reached", table: .chat),
                    currentFileExtractionLimits.maxFiles
                )
            )
        }
        isProcessingAttachment = false
    }

    private func resolveModelDetails(in provider: Provider, modelID: String) -> (name: String, promptPrice: Double?)? {
        if let localModel = ProviderSelectionSnapshot.currentModel(storedModelID: modelID, in: provider)
            ?? ModelResolver.matchingModel(
                modelID: modelID,
                in: provider.catalogModels,
                providerKind: provider.kind
            ) {
            return (localModel.name, localModel.promptPrice)
        }

        guard provider.kind != .relay,
              let metadata = MetadataClient.shared.resolveCatalogModel(
                  modelID: modelID,
                  providerKind: provider.kind
              ) else {
            return nil
        }

        return (metadata.displayName ?? modelID, metadata.promptPerToken)
    }

    private func syncDraftIfNeeded(_ text: String, in conversationID: UUID) {
        guard projection.draftText != text else { return }
        appState.updateDraftText(text, in: conversationID)
    }

    private func handleDisappear() {
        flushDraftIfNeeded()
        conversationObservation.stop()
        windowLoader.stop()
        appState.activeReturnToNoteID = nil
    }

    private func handleAppear(currentModel: AIModel?) {
        composerText = projection.draftText
        syncCapabilitySelection(for: currentModel)
        pruneUnsupportedPendingAttachments()
    }

    private func flushDraftIfNeeded() {
        guard let conversationID = projection.activeConversationID else { return }
        syncDraftIfNeeded(composerText, in: conversationID)
    }
}
struct ExpensiveModelHintData: Equatable {
    let newModelName: String
    let oldModelName: String
    let multiplier: Int
}

private let expensiveModelRatioThreshold: Double = 5

func evaluateExpensiveModelMultiplier(
    oldPromptPrice: Double?,
    newPromptPrice: Double?,
    threshold: Double = 5
) -> Int? {
    guard let oldPrice = oldPromptPrice, let newPrice = newPromptPrice,
          oldPrice > 0 else { return nil }
    let ratio = newPrice / oldPrice
    return ratio > threshold ? Int(ratio) : nil
}

#Preview {
    ChatView(conversationID: AppState.preview.recentConversations.first!.id)
        .environment(AppState.preview)
}
