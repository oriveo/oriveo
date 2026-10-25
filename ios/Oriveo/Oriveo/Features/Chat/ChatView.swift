import Combine
import GRDB
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The availability of a conversation's connection: when the connection id stored on the conversation is not in the list, it does not fall back to another connection.
enum ChatConversationConnectionState: Equatable {
    /// The connection is in the list; sending proceeds as usual.
    case available
    /// The connection list has not finished loading: no banner is shown, the top bar shows the model name stored on the conversation,
    /// the composer stays writable, and a tap on send is refused by ChatManager with the reason.
    case pending
    /// The list has finished loading and the connection is really gone: a "connection removed" banner + Choose model is shown and sending is disabled.
    case removed
}

struct ChatScreenContext {
    /// When `connectionState != .available` this is a placeholder connection built from the conversation id (no model), not another connection.
    let provider: Provider
    let model: AIModel?
    var connectionState: ChatConversationConnectionState = .available
    /// Set when the relay conversation's model has been removed: the connection's display name, and the composer shows a banner and sending is disabled.
    var removedModelConnectionName: String? = nil
    /// Set when the official conversation model has been retired or is missing: the composer shows a retired banner and sending is disabled.
    var retiredModel: ChatRetiredConversationModel? = nil
    /// The model name the top bar shows when `connectionState == .pending`: the catalog display name, or the stored id when it cannot be found.
    var pendingModelName: String? = nil
}

/// A retired / missing conversation model: the name comes from the catalog or the tombstone; the successor is given only if it is among the connection's enabled models right now.
struct ChatRetiredConversationModel: Equatable {
    let displayName: String
    var successorModelID: String? = nil
    var successorModelName: String? = nil
}

/// The banner for a removed conversation model: one sentence plus a "Choose model" button, no title.
/// A retired / missing official model uses the same banner: "X has been retired." + "Switch to Y" (when there is a successor) or "Choose model".
/// Control state is derived only here; structure tests assert on this, not on screenshots.
struct ChatModelRemovedBanner: Equatable {
    static let messageKey = "This chat’s model is no longer in %@."
    static let retiredMessageKey = "%@ has been retired."
    static let switchToKey = "Switch to %@"
    static let actionKey = "Choose model"
    static let connectionRemovedMessageKey = "The provider for this conversation has been removed."

    let connectionName: String
    /// Non-nil = the retired state of an official model: the banner names the model rather than the connection.
    var retiredModelName: String? = nil
    var successorModelID: String? = nil
    var successorModelName: String? = nil
    var providerID: UUID? = nil
    /// true = the conversation's connection was deleted: the banner says the connection is gone, and the button is "Choose model".
    var connectionRemoved: Bool = false

    var message: String {
        if connectionRemoved {
            return L10n.tr(Self.connectionRemovedMessageKey)
        }
        if let retiredModelName {
            return String(format: L10n.tr(Self.retiredMessageKey, table: .chat), retiredModelName)
        }
        return String(format: L10n.tr(Self.messageKey, table: .chat), connectionName)
    }

    var actionTitle: String {
        if successorModelID != nil, let successorModelName {
            return String(format: L10n.tr(Self.switchToKey, table: .chat), successorModelName)
        }
        return L10n.tr(Self.actionKey, table: .chat)
    }

    static func resolve(_ context: ChatScreenContext?) -> ChatModelRemovedBanner? {
        guard let context else { return nil }
        if context.connectionState == .removed {
            return ChatModelRemovedBanner(connectionName: "", connectionRemoved: true)
        }
        if let connectionName = context.removedModelConnectionName {
            return ChatModelRemovedBanner(connectionName: connectionName)
        }
        if let retired = context.retiredModel {
            return ChatModelRemovedBanner(
                connectionName: context.provider.displayName,
                retiredModelName: retired.displayName,
                successorModelID: retired.successorModelID,
                successorModelName: retired.successorModelName,
                providerID: context.provider.id
            )
        }
        return nil
    }

    /// Where the banner's "Choose model" goes.
    enum ActionTarget: Equatable {
        case modelPicker
        /// The conversation's connection was deleted and none is left: the picker would have nothing to choose, so this goes to adding a connection.
        case connectionSetup
    }

    static func actionTarget(_ context: ChatScreenContext?, providers: [Provider]) -> ActionTarget {
        context?.connectionState == .removed && providers.isEmpty ? .connectionSetup : .modelPicker
    }

    /// Whether the send button is tappable: never while a banner is showing (including a deleted connection).
    static func isSendEnabled(
        hasComposerContent: Bool,
        controlsDisabled: Bool,
        banner: ChatModelRemovedBanner?
    ) -> Bool {
        hasComposerContent && !controlsDisabled && banner == nil
    }
}

func resolveChatScreenContext(
    requestedProviderID: UUID?,
    requestedModelID: String?,
    providers: [Provider],
    activeModel: (provider: Provider, model: AIModel)?,
    primaryProvider: Provider?,
    lastUsedModelRef: LastUsedModelRef? = nil,
    providersLoaded: Bool,
    requestedProviderKind: ProviderKind? = nil,
    modelDisplayName: (_ modelID: String, _ kind: ProviderKind) -> String? = { _, _ in nil }
) -> ChatScreenContext? {
    if let requestedProviderID,
       providers.first(where: { $0.id == requestedProviderID }) == nil {
        // The conversation's connection is not in the list: no fallback to activeModel / primaryProvider and no rewriting of the conversation; only a user choice writes to it.
        let placeholder = missingConnectionPlaceholder(id: requestedProviderID, kind: requestedProviderKind)
        // The connection can be judged deleted once the local load has finished; until then it stays pending.
        let connectionState: ChatConversationConnectionState = providersLoaded ? .removed : .pending
        let storedModelID = requestedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ChatScreenContext(
            provider: placeholder,
            model: nil,
            connectionState: connectionState,
            pendingModelName: connectionState == .pending && !storedModelID.isEmpty
                // Display name: official metadata, then the original id.
                ? modelDisplayName(storedModelID, placeholder.kind) ?? storedModelID
                : nil
        )
    }
    if let requestedProviderID,
       let provider = providers.first(where: { $0.id == requestedProviderID }) {
        if provider.kind == .relay {
            // A relay neither silently replaces nor repairs the conversation's model; an empty conversation model falls back to the default path.
            if case .removed(let connectionName) = ProviderSelectionSnapshot.conversationModelState(
                storedModelID: requestedModelID,
                in: provider
            ) {
                return ChatScreenContext(
                    provider: provider,
                    model: nil,
                    removedModelConnectionName: connectionName
                )
            }
            if requestedModelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                return ChatScreenContext(
                    provider: provider,
                    model: ProviderSelectionSnapshot.relayFallbackModel(in: provider, lastUsedModelRef: lastUsedModelRef)
                )
            }
        } else if let retired = retiredConversationModel(storedModelID: requestedModelID, in: provider) {
            // An official model that was retired or is missing: no silent replacement and no repair of the conversation model; wait for the user to switch to the successor or choose again.
            return ChatScreenContext(
                provider: provider,
                model: nil,
                retiredModel: retired
            )
        }
        // An empty conversation model follows the new-chat chain restricted to this connection (including the last-used tier that points at it), the same source as sending.
        let model = (requestedModelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            ? ProviderSelectionSnapshot.newChatModel(in: provider, lastUsedModelRef: lastUsedModelRef)
            : ProviderSelectionSnapshot.currentModel(storedModelID: requestedModelID, in: provider)

        return ChatScreenContext(provider: provider, model: model)
    }

    // Only a new conversation (no stored providerID) gets here: the default model rules apply.
    if let activeModel {
        return ChatScreenContext(provider: activeModel.provider, model: activeModel.model)
    }

    // An empty new-chat chain no longer falls back to the primary connection; the caller opens the model picker.
    return nil
}

extension ChatLoadState {
    /// Only the states where the body is not in place disable writing; an unavailable connection (pending) stays writable, and a tap on send is refused by ChatManager with the reason while the draft is kept.
    var blocksComposer: Bool {
        switch self {
        case .stalled, .bootstrapping, .localFailure:
            return true
        case .content, .empty, .deleted:
            return false
        }
    }
}

/// Placeholder for a conversation connection that is not in the list: it keeps the conversation's own id and kind, has no model, and does not pose as any existing connection.
private func missingConnectionPlaceholder(id: UUID, kind: ProviderKind?) -> Provider {
    Provider(
        id: id,
        kind: kind ?? .relay,
        status: .issue(""),
        models: [],
        catalogModels: [],
        lastCheckedAt: nil,
        apiKey: "",
        apiKeyPreview: "",
        lastError: nil,
        baseURLText: nil,
        customName: nil
    )
}

/// Projection of the retired state of a conversation model: relay and a pending catalog count as resolved, and this returns nil.
private func retiredConversationModel(storedModelID: String?, in provider: Provider) -> ChatRetiredConversationModel? {
    switch ProviderSelectionSnapshot.conversationModelState(storedModelID: storedModelID, in: provider) {
    case .retired(let displayName, let successorId):
        let successor = successorId.flatMap {
            ModelResolver.resolveStoredModel(
                $0,
                in: ProviderSelectionSnapshot.enabledModels(in: provider),
                providerKind: provider.kind
            )
        }
        return ChatRetiredConversationModel(
            displayName: displayName,
            successorModelID: successor?.id,
            successorModelName: successor?.name
        )
    case .missing(let displayName):
        return ChatRetiredConversationModel(displayName: displayName)
    case .resolved, .removed:
        return nil
    }
}

/// The one-time hint after the preferred model of a new chat was retired and the chat fell back: the key is the connection holding the retired model x the retired model, and the name is the model it fell back to (possibly on another connection).
struct NewChatRetiredFallbackHint: Equatable {
    let providerID: UUID
    let retiredModelID: String
    let fallbackModelName: String

    static func resolve(
        requestedProviderID: UUID?,
        providers: [Provider],
        lastUsedModelRef: LastUsedModelRef?
    ) -> NewChatRetiredFallbackHint? {
        guard requestedProviderID == nil,
              let ref = lastUsedModelRef,
              let fallback = ProviderSelectionSnapshot.newChatRetiredFallback(
                in: providers,
                lastUsedModelRef: lastUsedModelRef
              ) else { return nil }
        return NewChatRetiredFallbackHint(
            providerID: ref.providerID,
            retiredModelID: fallback.retiredModelID,
            fallbackModelName: fallback.model.name
        )
    }

    /// The first call returns the text to show and records it in the history; afterwards the same connection x model always gives nil.
    func consumeMessage(history: ModelRetiredHintHistory = .shared) -> String? {
        guard history.consumeFirstHint(providerID: providerID, modelID: retiredModelID) else { return nil }
        return ModelRetiredHintHistory.lastUsedRetiredMessage(fallbackModelName: fallbackModelName)
    }
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

@MainActor
func resolveChatScreenContext(
    projection: ChatScreenProjection,
    appState: AppState,
    modelDisplayName: (_ modelID: String, _ kind: ProviderKind) -> String? = { _, _ in nil }
) -> ChatScreenContext? {
    let requestedModelID = projection.modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let requestedProviderID = projection.providerID
        ?? (requestedModelID.isEmpty ? appState.pendingNewChatProviderID : nil)
    return resolveChatScreenContext(
        requestedProviderID: requestedProviderID,
        requestedModelID: projection.modelID,
        providers: appState.providers,
        activeModel: appState.activeModel,
        primaryProvider: appState.primaryProvider ?? makeHistoricalProviderFallback(projection: projection),
        lastUsedModelRef: appState.lastUsedModelRef,
        providersLoaded: appState.providersLoaded,
        requestedProviderKind: projection.summary?.providerKind,
        modelDisplayName: modelDisplayName
    )
}

/// Looking up the catalog every time is too expensive; one entry is kept per (conversation, model, kind) and cleared when the metadata snapshot turns over.
/// A reference type held in @State: reads and writes do not refresh the view, so it is safe to use inside body.
@MainActor
final class ChatPendingModelNameCache {
    private struct Key: Hashable {
        let conversationID: UUID?
        let modelID: String
        let kind: ProviderKind
    }

    private var entries: [Key: String?] = [:]

    func displayName(
        conversationID: UUID?,
        modelID: String,
        kind: ProviderKind,
        resolve: (_ modelID: String, _ kind: ProviderKind) -> String?
    ) -> String? {
        let key = Key(conversationID: conversationID, modelID: modelID, kind: kind)
        if let cached = entries[key] { return cached }
        let resolved = resolve(modelID, kind)
        entries[key] = .some(resolved)
        return resolved
    }

    func removeAll() {
        entries.removeAll()
    }
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

/// A pending quote follows the conversation: it is cleared when the conversation id changes; a draft being promoted to a conversation on send (nil to id) is the same draft and is not cleared.
nonisolated enum ChatPendingQuoteReset {
    static func shouldClear(from oldID: UUID?, to newID: UUID?) -> Bool {
        guard let oldID else { return false }
        return oldID != newID
    }
}

struct ChatView: View {
    let conversationID: UUID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    @Environment(\.windowNavigation) private var windowNavigation
    /// This window's navigation state (one per window); a host without one injected (tests) falls back to the active window.
    private var navigation: NavigationManager { windowNavigation ?? appState.navigation }

    /// Input text is not ChatView `@State`: each keystroke would rebuild the page
    /// (list, toolbar, capability strip). The live text and draft persistence live in
    /// ChatComposerBar; this only pushes on send-clear / fail-restore / edit-restore.
    @State private var composerTextPush = ChatComposerTextPush()
    @State private var composerSendGate = ComposerSendGate()
    @State private var modelPickerPresentation: ModelPickerPresentationSnapshot?
    /// Model display names of a pending connection are cached per conversation (see ChatPendingModelNameCache).
    @State private var pendingModelNameCache = ChatPendingModelNameCache()
    @State private var compactionDetailPresentation: ContextCompactionDetailPresentation?
    /// Usage summary for the ring; tagged with the conversation it was computed for.
    @State private var contextUsage: (conversationID: UUID, summary: ContextUsageSummary)?
    /// Bumped when the active conversation's checkpoint rows change, so the usage summary recomputes.
    @State private var contextUsageCheckpointToken: UInt = 0
    @State private var conversationSettingsPresentation: ConversationSettingsPresentation?
    @State private var contextUsagePanelPresentation: ContextUsagePanelPresentation?
    /// Usage row tapped in the settings sheet: open the panel once that sheet has dismissed.
    @State private var pendingContextUsagePanelID: UUID?
    /// Composer capability selection when the settings sheet opened; the panel reached from it reads the same B as send.
    @State private var conversationSettingsCapabilitySelection = ChatCapabilitySelection()
    /// In-flight precompaction; cancelled when the page disappears or the conversation switches.
    @State private var precompactionTask: Task<Void, Never>?
    @State private var pendingModelSelection: ModelPickerSelection?
    @State private var reasoningMode: ReasoningMode = .automatic
    @State private var reasoningIntentSelection: String?
    /// new-conversation default. Legacy persisted ON/OFF values are migrated by the
    /// model-control store when an existing conversation opens; a new draft starts closed.
    @State private var webEnabled = false
    /// Remote MCP: the tool panel data of this conversation (the number on the chip comes from it too) and
    /// whether the panel is open.
    @State private var mcpPanelState: McpToolPanelState = .empty
    @State private var showsMcpToolPanel = false
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
    /// Something is being dragged over the chat page: the composer area gets a primary-colour outline.
    @State private var isDropTargeted = false
    @State private var showDeleteConfirmation = false
    @State private var expensiveModelHint: ExpensiveModelHintData?
    /// The input is a UIKit view (ComposerTextView) that bridges focus to first responder by hand, not through FocusState.
    @State private var composerFocused = false
    @State private var bootstrapLoadFailed = false
    @State private var conversationObservation = CurrentConversationObservation()
    @State private var windowLoader = MessageWindowLoader()
    @State private var disclosureProvider: ProviderKind?
    @State private var pendingSendPayload: PendingSendPayload?
    @State private var showsMissingProviderKeyPrompt = false
    /// The voice conversation entry held back by the disclosure gate: continues after the user accepts.
    @State private var pendingVoiceConversationStart: ChatCapabilitySelection?
    @State private var bootstrapWatchdogExpired = false
    @State private var historyRetryGeneration = 0
    @State private var generationParameterDraftSessionID = UUID()
    /// The token registered with this window's carrier handoff (on disappear only this registration is removed).
    @State private var carrierHandoffToken: ChatCarrierHandoff.Token?
    /// Makes the composer reopen the model options panel after a carrier change.
    @State private var composerModelControlsReopenToken: UInt = 0
    /// This page's identity in the window's command target (see `ChatCommandTarget.owner`).
    @State private var commandTargetOwner = UUID()

    /// Delay before reopening a sheet after a carrier change: wait for the new view to mount and the old view's sheet to go away.
    private static let carrierSheetReopenDelay: Duration = .milliseconds(350)

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

    /// Context precompaction (U4 item 10): on composer focus or first input. The chat manager
    /// skips non-AI mode, Free, small contexts and conversations already compacting.
    private func precompactConversationIfNeeded() {
        guard let conversationID = projection.activeConversationID else { return }
        let chatManager = appState.chatManager
        precompactionTask?.cancel()
        precompactionTask = Task { await chatManager.precompactIfNeeded(conversationId: conversationID) }
    }

    /// Summary for the active conversation only; nil for drafts and while a switched-to conversation loads.
    private var activeContextUsage: ContextUsageSummary? {
        guard let contextUsage, contextUsage.conversationID == projection.activeConversationID else { return nil }
        return contextUsage.summary
    }

    /// Store reads run off the main actor inside `ContextUsageSummary.current`; drafts without an id read nothing.
    private func refreshContextUsage() async {
        guard let conversationID = projection.activeConversationID else {
            contextUsage = nil
            return
        }
        guard let next = await ContextUsageSummary.current(in: appState, conversationID: conversationID),
              !Task.isCancelled, conversationID == projection.activeConversationID
        else { return }
        contextUsage = (conversationID, next)
    }

    /// Context panel entry from the composer ring. The composer's capability selection
    /// goes along so the panel's cap rows resolve generation parameters like the send path.
    private func openContextUsage(capabilitySelection: ChatCapabilitySelection) {
        guard let conversationID = projection.activeConversationID else { return }
        contextUsagePanelPresentation = ContextUsagePanelPresentation(
            conversationID: conversationID,
            capabilitySelection: capabilitySelection
        )
    }

    private func cancelPrecompaction() {
        precompactionTask?.cancel()
        precompactionTask = nil
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

    private var chatCommandTarget: ChatCommandTarget {
        let projection = projection
        return ChatCommandTarget(
            owner: commandTargetOwner,
            conversationID: projection.activeConversationID,
            lastResponseText: ChatCommandTarget.lastCopyableResponse(in: projection.messages)
        )
    }

    private var hasBootstrapFailure: Bool {
        bootstrapLoadFailed || conversationObservation.initialLoadFailed || windowLoader.initialLoadFailed
    }

    private var isComposerReadOnly: Bool {
        projection.loadState.blocksComposer
    }

    /// The relay protocol the current model actually uses: when the connection default or the model's own protocol changes, capability preferences and pending attachments must be recomputed.
    private var relayDispatchTransport: RelayTransport? {
        guard let context = resolvedChatContext, context.provider.kind == .relay else { return nil }
        guard let model = context.model else { return RelayEndpointResolver.connectionTransport(of: context.provider) }
        return RelayFirstSendTransport.current(provider: context.provider, model: model)
    }

    private var resolvedChatContext: ChatScreenContext? {
        let projection = projection
        let cache = pendingModelNameCache
        return resolveChatScreenContext(projection: projection, appState: appState) { modelID, kind in
            cache.displayName(conversationID: projection.activeConversationID, modelID: modelID, kind: kind) { modelID, kind in
                MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: kind)?.displayName
            }
        }
    }

    private var newChatRetiredFallbackHint: NewChatRetiredFallbackHint? {
        NewChatRetiredFallbackHint.resolve(
            requestedProviderID: projection.providerID,
            providers: appState.providers,
            lastUsedModelRef: appState.lastUsedModelRef
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
        ChatAttachmentPicker.ImportContext(
            provider: resolvedChatContext?.provider,
            model: resolvedChatContext?.model,
            partitionID: appState.sessionPartitionUID
        )
    }

    /// The composer's attachment entries: enabled / disabled reason / first-attach hint, read only from the facade entry (the same identity as ImportContext).
    private var currentAttachmentEntries: ComposerAttachmentEntries {
        ComposerAttachmentEntries.resolve(
            provider: resolvedChatContext?.provider,
            model: resolvedChatContext?.model,
            partitionID: appState.sessionPartitionUID
        )
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
        Self.capabilityEvidenceIdentity(provider: provider, model: model, partitionID: appState.sessionPartitionUID)
    }

    /// Shared by the model options panel and the composer: the same identity, the same projection, the same photo-picker criterion.
    static func capabilityEvidenceIdentity(
        provider: Provider,
        model: AIModel,
        partitionID: String
    ) -> CapabilityEvidenceRequestIdentity? {
        if let dispatch = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
            provider: provider,
            model: model,
            partitionID: partitionID
        ) {
            return dispatch
        }
        guard provider.relayRequested == nil else { return nil }
        return CapabilityEvidenceRequestIdentity.make(
            provider: provider,
            model: model,
            partitionID: partitionID,
            hasExplicitValue: false
        )
    }

    private func capabilityProjection(
        provider: Provider,
        model: AIModel,
        explicitKeys: Set<String> = []
    ) -> CapabilityEvidenceProjection {
        Self.capabilityProjection(
            provider: provider, model: model, partitionID: appState.sessionPartitionUID, explicitKeys: explicitKeys
        )
    }

    static func capabilityProjection(
        provider: Provider,
        model: AIModel,
        partitionID: String,
        explicitKeys: Set<String> = []
    ) -> CapabilityEvidenceProjection {
        CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider,
            model: model,
            identity: capabilityEvidenceIdentity(provider: provider, model: model, partitionID: partitionID),
            keys: Set(["tool_call", "web_search", CapabilityEvidenceFacade.visionInputKey])
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
        Self.capabilityControlVisible(resolution)
    }

    /// The single criterion for whether a capability entry is shown; internal so contract tests can call the production criterion directly.
    static func capabilityControlVisible(
        _ resolution: CapabilityEvidenceFacade.Resolution?
    ) -> Bool {
        guard let resolution else { return false }
        if resolution.support == .supported { return true }
        return resolution.support == .unknown
            && resolution.source == .relayDeclaration
            && (resolution.grade == .acceptedUnverified || resolution.grade == .declared)
    }

    /// The set of visible capability entries; internal so contract tests can call the production criterion directly. The vision key goes through `visionControlVisible` instead.
    static func visibleCapabilityKeys(
        provider: Provider,
        model: AIModel,
        projection: CapabilityEvidenceProjection
    ) -> Set<String> {
        var keys = Set(projection.resolutions.compactMap { key, resolution in
            key != CapabilityEvidenceFacade.visionInputKey && capabilityControlVisible(resolution) ? key : nil
        })
        // The vision key does not depend on whether the resolution has an entry for it: a relay reads the input projection, which exists even when the UI identity is incomplete.
        if visionControlVisible(provider: provider, model: model, projection: projection) {
            keys.insert(CapabilityEvidenceFacade.visionInputKey)
        }
        return keys
    }

    /// Vision entry = the editable flag of the vision_input input projection (unknown still opens the entry;
    /// hard block / user removal / negative cache v2 / an entry that does not accept it close it). A relay with no projection has no connection identity, so the entry is closed;
    /// the other forms with no projection (incomplete identity) still use the general criterion.
    static func visionControlVisible(
        provider: Provider,
        model: AIModel,
        projection: CapabilityEvidenceProjection
    ) -> Bool {
        if let input = projection.inputProjection(for: CapabilityEvidenceFacade.visionInputKey) {
            return input.editable
        }
        guard ProviderForm.of(provider) != .relay else { return false }
        return capabilityControlVisible(projection.resolution(for: CapabilityEvidenceFacade.visionInputKey))
    }

    private func visibleCapabilityKeys(
        provider: Provider,
        model: AIModel,
        from projection: CapabilityEvidenceProjection
    ) -> Set<String> {
        Self.visibleCapabilityKeys(provider: provider, model: model, projection: projection)
    }

    private var currentSupportsImageAttachment: Bool {
        guard let context = resolvedChatContext, let model = context.model else { return false }
        return Self.photoPickerVisible(provider: context.provider, model: model, partitionID: appState.sessionPartitionUID)
    }

    /// Whether the composer's photo entry is shown: the vision entry criterion times whether this wire accepts images. The vision card of the model options panel calls it too.
    static func photoPickerVisible(provider: Provider, model: AIModel, partitionID: String) -> Bool {
        visionControlVisible(
            provider: provider,
            model: model,
            projection: capabilityProjection(provider: provider, model: model, partitionID: partitionID)
        )
            && ChatAttachmentPicker.ImportContext(provider: provider, model: model, partitionID: partitionID).entry.image
    }

    private var currentSupportsVideoAttachment: Bool {
        currentAttachmentEntries.video.isEnabled
    }

    /// The same entry result as ChatComposerBar, so a button is never tappable while the picked file would be pruned away.
    private var currentSupportsFileAttachment: Bool {
        currentAttachmentEntries.file.isEnabled
    }

    private func performSend(
        text: String,
        attachments: [Attachment],
        quoteContext: QuoteContext?,
        capabilitySelection: ChatCapabilitySelection
    ) {
        // This turn's attachments do not fit on the route about to be used: do not send, and leave the composer text and attachments as they are.
        if let overLimit = appState.composerAttachmentOverLimit(
            text: text,
            attachments: attachments,
            in: projection.activeConversationID,
            generationParameterDraftSessionID: generationParameterDraftSessionID,
            capabilitySelection: capabilitySelection
        ) {
            ToastManager.shared.show(overLimit.message)
            return
        }
        autoScrollEnabled = true
        composerFocused = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            composerTextPush.push("")
            pendingAttachments = []
            pendingQuoteContext = nil
        }
        withAnimation { expensiveModelHint = nil }
        Task {
            let outcome = await composerSendGate.send {
                await appState.sendMessageOutcome(
                    text,
                    attachments: attachments,
                    quoteContext: quoteContext,
                    in: projection.activeConversationID,
                    generationParameterDraftSessionID: generationParameterDraftSessionID,
                    capabilitySelection: capabilitySelection
                )
            }
            switch outcome {
            case .blockedWhileSending:
                // A send is already in flight (hardware Return and the send button in the same frame; a new conversation is judged the same way): the content went out with that one, so do not refill.
                break
            case .refused:
                composerTextPush.push(text)
                pendingAttachments = attachments
                pendingQuoteContext = quoteContext
            case .sent:
                break
            }
        }
    }

    /// A send cancelled at the confirmation gate comes back to this conversation's composer, only when
    /// the composer is empty (otherwise the rolled-back payload is dropped).
    private func restoreComposerAfterContextCapRollback(_ rollback: ContextCapSendRollback) {
        guard rollback.conversationID == (projection.activeConversationID ?? conversationID) else { return }
        let current = navigation.chatHandoff.liveComposerText() ?? composerTextPush.text
        guard let restored = ContextCapComposerRestore.restoration(
            for: rollback,
            composerText: current,
            composerAttachments: pendingAttachments
        ) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            composerTextPush.push(restored.text)
            pendingAttachments = restored.attachments
            pendingQuoteContext = restored.quoteContext
        }
    }

    private func handleComposerSend(
        text: String,
        attachments: [Attachment],
        capabilitySelection: ChatCapabilitySelection
    ) {
        pendingVoiceConversationStart = nil
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

    // MARK: - Voice conversation entry

    /// Empty-draft ≋: the provider's first-use disclosure on the send path comes first;
    /// then the session prepares the microphone and recognition and starts listening.
    private func handleVoiceConversationStart(capabilitySelection: ChatCapabilitySelection) {
        pendingSendPayload = nil
        pendingVoiceConversationStart = nil
        switch ChatVoiceConversationGate.evaluate(
            providerKind: currentProviderKind,
            providerDisclosureAccepted: { ProviderDisclosureStore.hasAccepted($0) }
        ) {
        case .providerDisclosure(let kind):
            pendingVoiceConversationStart = capabilitySelection
            disclosureProvider = kind
        case .open:
            startVoiceConversation(capabilitySelection: capabilitySelection)
        }
    }

    private func startVoiceConversation(capabilitySelection: ChatCapabilitySelection) {
        pendingVoiceConversationStart = nil
        composerFocused = false
        let draftSessionID = generationParameterDraftSessionID
        Task {
            await VoiceConversationSession.shared.start(
                origin: .chat,
                conversationID: projection.activeConversationID,
                host: appState
            ) { [appState] text, conversationID in
                return await appState.sendMessageOutcome(
                    text,
                    in: conversationID,
                    generationParameterDraftSessionID: draftSessionID,
                    capabilitySelection: capabilitySelection,
                    delivery: .voice
                )
            }
        }
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

    // MARK: - Remote MCP tool panel

    /// Switches are stored per conversation. A new conversation has no id until its first message is sent,
    /// so they are kept under the draft id and moved over on send.
    private var mcpConversationScopeID: UUID {
        projection.activeConversationID ?? generationParameterDraftSessionID
    }

    /// The panel data is re-read whenever one of these changes: the conversation, the connection or model,
    /// or an answer finishing (the connection state may have changed).
    private var mcpPanelReloadKey: String {
        [
            mcpConversationScopeID.uuidString,
            resolvedChatContext?.provider.id.uuidString ?? "",
            resolvedChatContext?.model?.id ?? "",
            projection.isSendingMessage ? "1" : "0",
        ].joined(separator: "|")
    }

    private func reloadMcpPanelState() {
        let uid = appState.sessionPartitionUID
        let availability: McpToolAvailability
        if let context = resolvedChatContext, let model = context.model {
            availability = appState.chatManager.mcpToolAvailability(provider: context.provider, model: model)
        } else {
            availability = .available
        }
        // When local storage cannot be read the panel is drawn as "no servers"; chat is not blocked.
        let loaded = try? McpToolPanelModel.load(
            conversationId: mcpConversationScopeID,
            store: appState.mcpServerDirectory.store(for: uid),
            credentialStore: appState.mcpServerDirectory.credentialStore,
            uid: uid,
            runtimeConfig: MetadataClient.shared.syncMcpRuntimeConfig(),
            availability: availability
        )
        var fallback = McpToolPanelState.empty
        fallback.availability = availability
        mcpPanelState = loaded ?? fallback
    }

    private func setMcpServer(_ serverId: UUID, enabled: Bool) {
        let uid = appState.sessionPartitionUID
        try? appState.mcpServerDirectory.store(for: uid).setServerEnabled(
            enabled, conversationId: mcpConversationScopeID, serverId: serverId
        )
        reloadMcpPanelState()
    }

    private func openMcpServers() {
        showsMcpToolPanel = false
        navigation.path.append(.mcpServers)
    }

    /// "Add MCP server" in the empty tool panel: goes straight to the add page and comes back to this
    /// conversation afterwards.
    private func openMcpAddServer() {
        showsMcpToolPanel = false
        navigation.path.append(.mcpAddServer)
    }

    /// "Re-authorize" on a row of the tool panel: opens that server's details and starts re-authorizing.
    private func openMcpReauthorization(_ serverId: UUID) {
        showsMcpToolPanel = false
        navigation.path.append(.mcpServerDetail(serverID: serverId, intent: .reauthorize))
    }

    private func presentModelPicker() {
        guard modelPickerPresentation == nil else { return }
        if ChatModelRemovedBanner.actionTarget(resolvedChatContext, providers: appState.providers) == .connectionSetup {
            appState.openProviderSetup(from: .providers)
            return
        }
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
        // The relay web switch reads through its own addressing (default layer included: a saved fragment means on); it stays off only when the advanced page overrides it off, and a rejected model still shows on.
        if provider.kind == .relay {
            let preference = RelayWebSwitch.isOn(
                provider: provider, model: model, conversationID: conversationID ?? generationParameterDraftSessionID
            )
            webEnabled = RelayWebProbe.fact(provider: provider, model: model, preference: preference)?.isOn ?? false
        }
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

    #if DEBUG
    nonisolated(unsafe) static var bodyEvaluationCount = 0
    /// When non-nil, only this conversation's body evaluations are counted: the counter is a process-wide static, so instances mounted by other tests
    /// (indirectly through AppRootView and the like, or late renders) must not be counted.
    nonisolated(unsafe) static var bodyCountConversationID: UUID?
    static func resetBodyEvaluationCount(countingOnly conversationID: UUID? = nil) {
        bodyEvaluationCount = 0
        bodyCountConversationID = conversationID
    }
    #endif

    var body: some View {
        #if DEBUG
        let _ = {
            if Self.bodyCountConversationID == nil || Self.bodyCountConversationID == conversationID {
                Self.bodyEvaluationCount += 1
            }
        }()
        #endif
        Group {
            if projection.loadState == .localFailure {
                conversationBootstrapFailureState
            } else if projection.loadState == .stalled {
                conversationStalledState
            } else if projection.loadState == .deleted {
                // The conversation was deleted, so leave it. Dismissing goes through the
                // carrier in use: compact pops the chat route, regular returns the detail
                // column to its empty state.
                Color.clear.onAppear {
                    if let conversationID {
                        navigation.dismissChat(conversationID: conversationID)
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
        // Page anchor for smoke / UI tests: the container only carries the identifier, and children stay readable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat_screen")
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
        .sheet(item: $compactionDetailPresentation) { presentation in
            ContextCompactionDetailSheet(detail: presentation.detail, conversationID: presentation.conversationID)
                .presentationDragIndicator(.visible)
                .environment(appState)
        }
        .sheet(item: $conversationSettingsPresentation, onDismiss: {
            guard let conversationID = pendingContextUsagePanelID else { return }
            pendingContextUsagePanelID = nil
            contextUsagePanelPresentation = ContextUsagePanelPresentation(
                conversationID: conversationID,
                capabilitySelection: conversationSettingsCapabilitySelection
            )
        }) { presentation in
            ConversationSettingsSheet(
                presentation: presentation,
                usageValue: ContextUsagePanel.settingsUsageValue(
                    contextUsage?.conversationID == presentation.conversationID ? contextUsage?.summary : nil
                ),
                onOpenUsage: presentation.conversationID.map { conversationID in
                    {
                        pendingContextUsagePanelID = conversationID
                        conversationSettingsPresentation = nil
                    }
                }
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environment(appState)
        }
        .sheet(item: $contextUsagePanelPresentation) { presentation in
            let summary = contextUsage?.conversationID == presentation.conversationID
                ? contextUsage?.summary ?? .empty
                : .empty
            ContextUsagePanelSheet(
                conversationID: presentation.conversationID,
                summary: summary,
                isSending: projection.isSendingMessage,
                capRows: ContextCapPresentation.panelSource(
                    in: appState,
                    conversationID: presentation.conversationID,
                    capabilitySelection: presentation.capabilitySelection
                )
                    .map { ContextUsagePanel.CapRows(source: $0, used: summary.used ?? 0) },
                onCapChange: { cap in
                    appState.conversationManager.setContextCap(id: presentation.conversationID, cap: cap)
                }
            )
                .contextUsagePanelDetents()
                .presentationDragIndicator(.visible)
                .environment(appState)
        }
        .sheet(item: $disclosureProvider) { kind in
            ProviderDisclosureSheet(
                provider: kind,
                onAccept: {
                    ProviderDisclosureStore.markAccepted(kind)
                    if let voiceSelection = pendingVoiceConversationStart, pendingSendPayload == nil {
                        startVoiceConversation(capabilitySelection: voiceSelection)
                    }
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
        .sheet(isPresented: $showsMcpToolPanel) {
            McpToolPanelSheet(
                state: mcpPanelState,
                onToggle: { serverId, enabled in setMcpServer(serverId, enabled: enabled) },
                onReauthorize: { openMcpReauthorization($0) },
                onManage: openMcpServers,
                onAddServer: openMcpAddServer,
                onSwitchModel: {
                    showsMcpToolPanel = false
                    presentModelPicker()
                }
            )
        }
        .task(id: mcpPanelReloadKey) { reloadMcpPanelState() }
        .mcpReauthorizationInlineHost(conversationID: projection.activeConversationID ?? conversationID)
        .contextCapConfirmPresenter(conversationID: projection.activeConversationID ?? conversationID)
        .onReceive(appState.chatManager.contextCapRollbacks) { rollback in
            restoreComposerAfterContextCapRollback(rollback)
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
        .onAppear {
            #if DEBUG
            // Screenshots only: the upper layers of the context page family are opened through their own production entry (ContextShots.open).
            if let overlay = ContextShots.takeOverlay(conversationID: conversationID), let conversationID {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    switch overlay {
                    case .detail:
                        presentCompactionDetail(conversationID: conversationID)
                    case .panel, .picker:
                        openContextUsage(capabilitySelection: ChatCapabilitySelection())
                    case .conversationSettings:
                        conversationSettingsPresentation = ConversationSettingsPresentation(
                            conversationID: conversationID,
                            useMemory: projection.useMemory,
                            focusEditor: false
                        )
                    case .confirm:
                        break
                    }
                }
            }
            #endif
        }
        .task(id: conversationID) {
            await bootstrapObservations(for: conversationID)
        }
        // Recompute on conversation switch, message changes and checkpoint changes.
        .task(id: ContextUsageRefreshKey(
            conversationID: projection.activeConversationID,
            messageRevision: projection.messageRevision,
            checkpointToken: contextUsageCheckpointToken
        )) {
            await refreshContextUsage()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .contextCheckpointsDidChange)
                .receive(on: DispatchQueue.main)
        ) { note in
            guard ChatMessageList.isCheckpointChange(note, conversationID: projection.activeConversationID) else { return }
            contextUsageCheckpointToken &+= 1
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .contextUsageInputsDidChange)
                .receive(on: DispatchQueue.main)
        ) { note in
            guard ChatMessageList.isCheckpointChange(note, conversationID: projection.activeConversationID) else { return }
            contextUsageCheckpointToken &+= 1
        }
        // When switching conversations on a wide screen ChatView is not rebuilt and @State is kept: a pending quote from the previous conversation must not carry into the new one.
        .onChange(of: conversationID) { oldID, newID in
            if oldID != newID {
                cancelPrecompaction()
                // Pending draft instructions belong to the draft being left.
                appState.pendingDraftInstructions = ""
            }
            guard ChatPendingQuoteReset.shouldClear(from: oldID, to: newID) else { return }
            pendingQuoteContext = nil
            pendingQuoteAttachedAt = nil
        }
        // The skeleton must have an upper bound. When the time is up and loading/backfilling is still going, switch to an explicit stalled error state.
        //
        // The id must carry `historyRetryGeneration`: with only conversationID, `.task` does not rerun after the user taps Retry
        // (the id did not change), so the watchdog is not re-armed. If the retried backfill hangs (an unresponsive connection
        // never throws by itself), the user is back to a skeleton with no upper bound, which is exactly the state this invariant forbids.
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
        .task(id: newChatRetiredFallbackHint) {
            if let message = newChatRetiredFallbackHint?.consumeMessage() {
                ToastManager.shared.show(message)
            }
        }
    }

    /// Loading the conversation failed.
    ///
    /// This used to be a ⚠️ and a Retry button and nothing else — the only error state in this
    /// file that did not explain itself. What the user saw was a triangle and a button, with no
    /// idea what went wrong or what pressing it would do.
    private var conversationBootstrapFailureState: some View {
        VStack(spacing: OriveoTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)

            Text(L10n.tr("Couldn't load this conversation."))
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, OriveoTheme.Spacing.xl)

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
                Image(systemName: "chevron.backward")
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
        let webOutboundPermitted = evidenceProjection?.permitsOutbound("web_search") == true
        // An always-on web search (Grok subscription) is not a choice the user can toggle: the globe stays unlit,
        // matching the panel, Android and Web.
        let webAllowed = currentModel.map {
            CapabilityWebPreferenceLiveness.composerWebPermitted(
                outboundPermitted: webOutboundPermitted, provider: provider, model: $0
            )
        } ?? webOutboundPermitted
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
        let composerVisibleCapabilityKeys = currentModel.flatMap { model in
            evidenceProjection.map { visibleCapabilityKeys(provider: provider, model: model, from: $0) }
        } ?? []
        let capabilitySelection = ChatCapabilitySelection(
            reasoningMode: capabilityDecision.reasoningMode,
            webSearchEnabled: capabilityDecision.webSearchEnabled
        )

        let content = VStack(spacing: 0) {
            ChatToolbar(
                projection: projection,
                provider: provider,
                currentModel: currentModel,
                pendingModelName: resolvedChatContext?.pendingModelName,
                isSendingMessage: isSendingMessage,
                transparentChrome: projection.messages.isEmpty,
                showModelSwitcher: Binding(
                    get: { modelPickerPresentation != nil },
                    set: { if $0 { presentModelPicker() } else { modelPickerPresentation = nil } }
                ),
                showDeleteConfirmation: $showDeleteConfirmation,
                onOpenSettings: { focusEditor in
                    conversationSettingsCapabilitySelection = capabilitySelection
                    conversationSettingsPresentation = ConversationSettingsPresentation(
                        conversationID: projection.activeConversationID,
                        useMemory: projection.useMemory,
                        focusEditor: focusEditor
                    )
                }
            )

            if let noteID = appState.activeReturnToNoteID {
                returnToNoteBar(noteID: noteID)
            }

            chatMessageList(
                projection: projection,
                conversationID: projection.activeConversationID,
                isSendingMessage: isSendingMessage,
                capabilitySelection: capabilitySelection,
                currentVisionInput: evidenceProjection?.inputProjection(for: CapabilityEvidenceFacade.visionInputKey),
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
        // Clamp the content to 620, the same rule the settings and detail pages follow rather
        // than a second one for the conversation screen. A phone in portrait (402) and the
        // detail column of an unfolded Duo (467) are both under 620 and never trigger it; an
        // iPad does, at 632 in portrait and 976 in landscape.
        //
        // This has to sit *before* the backgrounds: the trailing `frame(maxWidth: .infinity)`
        // inside `oriveoContentWidth` stretches the outer frame back to full width, so the
        // aurora and the screen background layered after it still span the container and only
        // the content is centred. The other order squeezes the whole backdrop into a stripe.
        .oriveoContentWidth()
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
        .onReceive(
            NotificationCenter.default.publisher(for: .metadataSnapshotDidPublish).receive(on: RunLoop.main)
        ) { _ in
            pendingModelNameCache.removeAll()
        }
        .onChange(of: resolvedChatContext?.provider.id) { _, _ in
            restoreCapabilityPreferences(provider: provider, model: currentModel, conversationID: projection.activeConversationID)
            pruneUnsupportedPendingAttachments()
        }
        .onChange(of: relayDispatchTransport) { _, _ in
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
            // After the preferences are restored: the handed-over state is what the user was just looking at, so it wins over the stored preferences.
            registerAndConsumeCarrierHandoff()
        }
        .onChange(of: pendingQuoteContext) { oldValue, newValue in
            guard oldValue != newValue else { return }
            pendingQuoteAttachedAt = newValue == nil ? nil : Date()
        }
        .onChange(of: composerFocused) { _, focused in
            if focused { precompactConversationIfNeeded() }
        }
        .onDisappear(perform: handleDisappear)
        // Menu bar commands: register the current conversation (its id changes once a draft is sent) and the last copyable reply with this window
        .onChange(of: chatCommandTarget, initial: true) { _, target in
            navigation.registerChatCommandTarget(target)
        }
        .onDisappear {
            navigation.unregisterChatCommandTarget(owner: commandTargetOwner)
        }
        // ⌘K: opens only when this window's request token changes; other windows' requests do not affect this page
        .onChange(of: navigation.modelPickerRequest) { _, _ in
            presentModelPicker()
        }
        // A new chat whose chain is empty (no usable model) opens the picker; the flag is consumed once the new-chat page appears.
        .onChange(of: appState.pendingNewChatModelPicker, initial: true) { _, pending in
            guard pending, conversationID == nil else { return }
            appState.pendingNewChatModelPicker = false
            presentModelPicker()
        }

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
        // The whole page is a drop target; the text field's own text drops (UITextView) sit above it and take precedence
        .onDrop(of: ChatDropImport.acceptedContentTypes, isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
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
            // The alert's message closure is evaluated with the body (on every keystroke in the
            // composer), so only query the store while the alert is actually presented.
            let refCount = showDeleteConfirmation
                ? projection.activeConversationID.map { appState.noteManager.referenceCount(conversationID: $0) } ?? 0
                : 0
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
                    .accessibilityLabel(L10n.tr("Close"))
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
                modelRemovedBanner: ChatModelRemovedBanner.resolve(resolvedChatContext),
                visibleCapabilityKeys: visibleCapabilityKeys,
                capabilityEvidenceIdentity: capabilityEvidenceIdentity,
                attachmentEntries: currentAttachmentEntries,
                generationProjection: currentModel.map {
                    generationProjection(provider: provider, model: $0)
                },
                capabilityDecision: capabilityDecision,
                isSendingMessage: isSendingMessage,
                conversationID: projection.activeConversationID,
                generationParameterScopeID: projection.activeConversationID ?? generationParameterDraftSessionID,
                isReadOnly: isComposerReadOnly,
                transparentChrome: projection.messages.isEmpty,
                // Not `projection.draftText`: it reads "" while the summary is nil (observation not ready
                // or stopped), and the composer would take "unknown" for "draft cleared".
                storeDraft: projection.summary?.draftText,
                textPush: composerTextPush,
                onDraftCommit: { text, conversationID in
                    appState.updateDraftText(text, in: conversationID)
                },
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
                // The entry is hidden when the master switch is off or no server has been added; existing configuration is kept.
                toolsChip: ComposerToolsChipState.resolve(
                    featureEnabled: MetadataClient.shared.syncMcpRuntimeConfig().enabled,
                    panelState: mcpPanelState
                ),
                onOpenTools: {
                    reloadMcpPanelState()
                    showsMcpToolPanel = true
                },
                onComposerTextStarted: precompactConversationIfNeeded,
                onCancel: {
                    guard let conversationID = projection.activeConversationID else { return }
                    appState.cancelGeneration(in: conversationID)
                },
                onShowPhotoPicker: { showPhotoPicker = true },
                onShowCamera: { showCamera = true },
                onShowFileImporter: { showFileImporter = true },
                modelControlsReopenToken: composerModelControlsReopenToken,
                contextUsage: activeContextUsage,
                onOpenContextUsage: { openContextUsage(capabilitySelection: capabilitySelection) },
                onStartVoiceConversation: {
                    handleVoiceConversationStart(capabilitySelection: capabilitySelection)
                }
            )
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(OriveoTheme.Palette.primary, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func chatMessageList(
        projection: ChatScreenProjection,
        conversationID: UUID?,
        isSendingMessage: Bool,
        capabilitySelection: ChatCapabilitySelection,
        currentVisionInput: CapabilityEvidenceFacade.InputCapabilityProjection?,
        bottomOverlayInset: CGFloat,
        scrollButtonBottomInset: CGFloat
    ) -> some View {
        ChatMessageList(
            projection: projection,
            conversationID: conversationID,
            isSendingMessage: isSendingMessage,
            capabilitySelection: capabilitySelection,
            currentVisionInput: currentVisionInput,
            bottomOverlayInset: bottomOverlayInset,
            scrollButtonBottomInset: scrollButtonBottomInset,
            windowLoader: windowLoader,
            isAtBottom: $isAtBottom,
            autoScrollEnabled: $autoScrollEnabled,
            onRestoreComposerText: restoreComposerText,
            onRestoreComposerAttachments: restoreComposerAttachments,
            onOpenCompactionDetail: { presentCompactionDetail(conversationID: conversationID) },
            pendingQuoteContext: $pendingQuoteContext,
            showModelSwitcher: Binding(
                get: { modelPickerPresentation != nil },
                set: { if $0 { presentModelPicker() } else { modelPickerPresentation = nil } }
            ),
            composerFocused: $composerFocused
        )
        .equatable()
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
            case .unsupported, .mediumUnavailable, .extractionFailed:
                await MainActor.run { isProcessingAttachment = false }
            }
        }
    }

    private func handleImportedFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        importFileURLs(urls)
    }

    /// Shared by the file button and drops: the same slots, import and rejection feedback.
    /// - Parameters:
    ///   - unreadableCount: sources a drop could not read a file from; reported as an unsupported format, like unreadable files.
    ///   - afterImport: called once the import finishes (drops use it to remove the temporary directory).
    private func importFileURLs(
        _ urls: [URL],
        unreadableCount: Int = 0,
        afterImport: (@Sendable () -> Void)? = nil
    ) {
        let importContext = currentAttachmentImportContext
        let refusalReasons = currentAttachmentEntries.fileImportRefusalReasons
        let extractionLimits = currentFileExtractionLimits
        isProcessingAttachment = true
        let byteLimit = currentAttachmentByteLimit
        // The slots are counted before any file is read: files beyond them are not read at all
        // (see `AttachmentImportLimiter.importSequentially`).
        let availableSlots = ChatDropImport.availableFileSlots(
            maxFiles: extractionLimits.maxFiles,
            pendingCount: pendingAttachments.count
        )

        Task(priority: .userInitiated) {
            let (attachments, rejectedCount, oversizedCount, overLimitCount, refusals) = await ChatDropImport.processFileURLs(
                urls,
                availableSlots: availableSlots,
                importContext: importContext,
                byteLimit: byteLimit,
                extractionLimits: extractionLimits,
                refusalReasons: refusalReasons
            )
            afterImport?()
            applyImportedAttachments(attachments, source: "file", skippedOverLimit: overLimitCount)
            if oversizedCount > 0 {
                await MainActor.run {
                    showAttachmentSizeLimitAlert = true
                }
            }
            if !refusals.isEmpty {
                await MainActor.run {
                    ToastManager.shared.show(refusals.joined(separator: "\n"))
                }
            }
            if rejectedCount + unreadableCount > 0 {
                await MainActor.run {
                    ToastManager.shared.show(L10n.tr("Unsupported file format"))
                }
            }
        }
    }

    // MARK: - Drag and drop

    /// Drops on the chat page: images take the camera path, files are copied to a temporary directory and take the file button path, and text alone is appended to the composer.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isComposerReadOnly else { return false }
        let plan = ChatDropImport.plan(
            providers.map(ChatDropImport.Item.init(provider:)),
            supportsImage: currentSupportsImageAttachment
        )
        guard !plan.isEmpty else { return false }

        if plan.appendsText {
            let textProviders = plan.textIndices.map { providers[$0] }
            Task { @MainActor in
                var pieces: [String] = []
                for provider in textProviders {
                    if let text = await ChatDropLoader.loadText(from: provider), !text.isEmpty {
                        pieces.append(text)
                    }
                }
                guard !pieces.isEmpty else { return }
                appendDroppedText(pieces.joined(separator: "\n"))
            }
            return true
        }

        let imageProviders = plan.imageIndices.map { providers[$0] }
        let fileProviders = plan.fileIndices.map { providers[$0] }
        let unsupportedImageCount = plan.unsupportedCount
        // When the image entry is disabled with a reason: dropped images are not added to the pending list, and the toast gives the same reason.
        let imageRefusal = currentAttachmentEntries.image.disabledReason
        Task { @MainActor in
            for provider in imageProviders {
                if let image = await ChatDropLoader.loadImage(from: provider) {
                    handleCapturedImage(image)
                }
            }
            if unsupportedImageCount > 0, let imageRefusal {
                ToastManager.shared.show(imageRefusal)
            }
            let unsupportedWithoutReason = imageRefusal == nil ? unsupportedImageCount : 0
            guard !fileProviders.isEmpty else {
                if unsupportedWithoutReason > 0 {
                    ToastManager.shared.show(L10n.tr("Unsupported file format"))
                }
                return
            }
            let directory = ChatDropLoader.makeTemporaryDirectory()
            var urls: [URL] = []
            var unreadable = unsupportedWithoutReason
            for provider in fileProviders {
                if let url = await ChatDropLoader.copyFile(from: provider, into: directory) {
                    urls.append(url)
                } else {
                    unreadable += 1
                }
            }
            importFileURLs(urls, unreadableCount: unreadable) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        return true
    }

    /// Appends after the composer's current text (the live text the composer registered; the stored draft may not be saved yet).
    private func appendDroppedText(_ text: String) {
        let current = navigation.chatHandoff.liveComposerText() ?? composerTextPush.text
        let result = ChatDropImport.appendingDroppedText(text, to: current, maxUTF16: ChatInputLimit.maxUTF16)
        if result.truncated {
            ChatInputLimit.showLimitReachedToast()
        }
        guard result.text != current else { return }
        composerTextPush.push(result.text)
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
            case .unsupported, .mediumUnavailable:
                break
            case .extractionFailed:
                // Photos from the camera do not take the local text extraction path, so this case does not actually fire.
                break
            }
        }
        return (results, oversized)
    }

    private func pruneUnsupportedPendingAttachments() {
        guard !pendingAttachments.isEmpty else { return }
        let pruned = Self.prunedPendingAttachments(
            pendingAttachments,
            context: resolvedChatContext,
            supportsImage: currentSupportsImageAttachment,
            supportsVideo: currentSupportsVideoAttachment,
            supportsFile: currentSupportsFileAttachment
        )
        if pruned.count != pendingAttachments.count {
            pendingAttachments = pruned
        }
    }

    /// Drops pending attachments the current entries do not support. While the connection is not in place (pending / removed) the model is nil and every entry is closed;
    /// that does not mean "the model does not accept them", so nothing is pruned, lest the draft's attachments be cleared.
    static func prunedPendingAttachments(
        _ attachments: [Attachment],
        context: ChatScreenContext?,
        supportsImage: Bool,
        supportsVideo: Bool,
        supportsFile: Bool
    ) -> [Attachment] {
        if let context, context.connectionState != .available { return attachments }
        return attachments.filter { attachment in
            switch attachment.kind {
            case .image:
                return supportsImage
            case .video:
                return supportsVideo
            case .file:
                return supportsFile
            }
        }
    }

    @MainActor
    private func applyImportedAttachments(
        _ attachments: [Attachment],
        source: String = "unknown",
        skippedOverLimit: Int = 0,
        announcesTruncation: Bool = true
    ) {
        // Media the entry does not accept is not added to the pending list; the toast gives the same disabled reason as the entry.
        let entries = currentAttachmentEntries
        let admission = ComposerAttachmentAdmission.partition(attachments, entries: entries)
        // Text budget gate: a file that would push this message's text over the limit is not added (same limit as at send time).
        let budgeted = AttachmentDelivery.admitWithinTextBudget(
            existing: pendingAttachments,
            incoming: admission.accepted,
            provider: resolvedChatContext?.provider.kind,
            model: resolvedChatContext?.model
        )
        let limited = AttachmentImportLimiter.limit(
            existing: pendingAttachments,
            incoming: budgeted.accepted,
            maxAttachments: currentFileExtractionLimits.maxFiles
        )
        // Notices for one batch are merged into a single multi-line toast: files not added first, then truncated ones.
        var notices = admission.refusalReasons
        notices += budgeted.rejected.map {
            String(format: L10n.tr("file_extraction_text_budget_exceeded", table: .chat), $0.fileName)
        }

        if !limited.accepted.isEmpty {
            pendingAttachments += limited.accepted
            pruneUnsupportedPendingAttachments()
            if let context = resolvedChatContext, let model = context.model,
               let hint = ComposerAttachmentAdmission.firstAttachHint(
                   added: limited.accepted, entries: entries,
                   providerID: context.provider.id, modelID: model.id
               ) {
                notices.append(hint)
            }
            // Attachments restored by an edit were already announced as truncated when first added.
            if announcesTruncation,
               let notice = ChatAttachmentPicker.truncationNotice(for: limited.accepted) {
                notices.append(notice)
            }
        }
        if !notices.isEmpty {
            ToastManager.shared.show(notices.joined(separator: "\n"))
        }
        if limited.rejectedCount + skippedOverLimit > 0 {
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

    private func handleDisappear() {
        // The draft is written by ChatComposerBar.onDisappear against its own stored snapshot, so it
        // does not depend on the order relative to this.
        conversationObservation.stop()
        windowLoader.stop()
        cancelPrecompaction()
        appState.activeReturnToNoteID = nil
        if let carrierHandoffToken {
            navigation.chatHandoff.unregister(carrierHandoffToken)
            self.carrierHandoffToken = nil
        }
    }

    // MARK: - Carrier handoff

    /// Registers the page state provider and takes back the state from before the move by this page's key (once; a mismatched key or an expired snapshot is discarded).
    private func registerAndConsumeCarrierHandoff() {
        let handoff = navigation.chatHandoff
        let token = carrierHandoffToken ?? handoff.registerPage { carrierPageState }
        carrierHandoffToken = token
        guard let snapshot = handoff.consume(key: ChatCarrierKey(conversationID: conversationID), by: token) else {
            return
        }
        if let page = snapshot.page {
            pendingAttachments = page.pendingAttachments
            pendingQuoteContext = page.pendingQuoteContext
            reasoningMode = page.reasoningMode
            reasoningIntentSelection = page.reasoningIntentSelection
            webEnabled = page.webEnabled
            generationParameterDraftSessionID = page.generationParameterDraftSessionID
        }
        if let composer = snapshot.composer {
            composerTextPush.push(composer.text)
            composerFocused = composer.isFocused
        }
        let sheet = snapshot.page?.sheet
        let reopensModelControls = snapshot.composer?.showsModelControls == true
        guard sheet != nil || reopensModelControls else { return }
        Task { @MainActor in
            try? await Task.sleep(for: Self.carrierSheetReopenDelay)
            reopenCarrierSheet(sheet)
            if reopensModelControls {
                composerModelControlsReopenToken &+= 1
            }
        }
    }

    /// Called synchronously by `NavigationManager` before the move: reads the page state at this moment.
    private var carrierPageState: ChatPageCarrierState {
        let sheet: ChatCarrierSheet?
        if modelPickerPresentation != nil {
            sheet = .modelPicker
        } else if showsMcpToolPanel {
            sheet = .mcpTools
        } else {
            sheet = nil
        }
        return ChatPageCarrierState(
            pendingAttachments: pendingAttachments,
            pendingQuoteContext: pendingQuoteContext,
            reasoningMode: reasoningMode,
            reasoningIntentSelection: reasoningIntentSelection,
            webEnabled: webEnabled,
            generationParameterDraftSessionID: generationParameterDraftSessionID,
            sheet: sheet
        )
    }

    private func reopenCarrierSheet(_ sheet: ChatCarrierSheet?) {
        switch sheet {
        case .modelPicker:
            presentModelPicker()
        case .mcpTools:
            reloadMcpPanelState()
            showsMcpToolPanel = true
        case nil:
            break
        }
    }

    private func restoreComposerText(_ text: String) {
        composerTextPush.push(text)
    }

    /// Editing a message with attachments: the original attachments replace those in the composer (the text is replaced too;
    /// a message without attachments leaves the composer's attachments alone). They take the same path as newly added
    /// attachments: the text budget gate, the file count limit, and filtering by the current model's capabilities.
    private func restoreComposerAttachments(_ attachments: [Attachment]) {
        guard !attachments.isEmpty else { return }
        pendingAttachments = []
        applyImportedAttachments(attachments, source: "edit", announcesTruncation: false)
    }

    /// Separator tap: resolve the latestValid row at tap time; no row means nothing to show.
    private func presentCompactionDetail(conversationID: UUID?) {
        guard let conversationID,
              let detail = ContextCompactionDetail.current(in: appState, conversationID: conversationID)
        else { return }
        compactionDetailPresentation = ContextCompactionDetailPresentation(
            conversationID: conversationID,
            detail: detail
        )
    }

    private func handleAppear(currentModel: AIModel?) {
        // No draft push here: when returning to this page the observation was just stopped and the
        // projected draft is "", which would clear unsent text in the composer.
        syncCapabilitySelection(for: currentModel)
        pruneUnsupportedPendingAttachments()
        // Starter chips in the detail column's empty state only prefill; consume the text right
        // away so it cannot reappear the next time a conversation opens.
        if let prefill = appState.pendingComposerPrefill {
            appState.pendingComposerPrefill = nil
            composerTextPush.push(prefill)
        }
        // "New chat with summary" quote: attach once, never auto-send.
        if let quote = appState.consumePendingComposerQuote() {
            pendingQuoteContext = quote
        }
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

/// `.task(id:)` key for the context usage summary.
private struct ContextUsageRefreshKey: Hashable {
    var conversationID: UUID?
    var messageRevision: UInt
    var checkpointToken: UInt
}
