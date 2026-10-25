import CoreGraphics
import Foundation

nonisolated struct ChatCollectionProviderMetadata: Sendable {
    private let lookup: ModelDisplayLookup

    nonisolated fileprivate init(
        lookup: ModelDisplayLookup
    ) {
        self.lookup = lookup
    }

    nonisolated static let empty = ChatCollectionProviderMetadata(lookup: .empty)

    nonisolated func resolvedProviderName(for message: ChatMessage) -> String? {
        guard let providerID = message.providerID else { return message.providerName }
        return lookup.providerDisplayName(providerID: providerID) ?? message.providerName
    }

    nonisolated func resolvedModelName(for message: ChatMessage) -> String? {
        guard let providerID = message.providerID,
              let modelID = message.modelID,
              modelID.isEmpty == false else {
            return message.modelName
        }
        return lookup.modelDisplayName(
            providerID: providerID,
            modelID: modelID,
            fallback: message.modelName
        )
    }

    nonisolated func relayKind(for message: ChatMessage) -> RelayKind? {
        guard let providerID = message.providerID else { return nil }
        return lookup.relayKind(providerID: providerID)
    }

    nonisolated func relayAvatar(for message: ChatMessage) -> RelayAvatar? {
        lookup.relayAvatar(providerID: message.providerID, providerKind: message.providerKind)
    }

    nonisolated func resolvedContextLength(for message: ChatMessage) -> Int? {
        guard let providerID = message.providerID,
              let modelID = message.modelID,
              modelID.isEmpty == false else {
            return nil
        }
        return lookup.contextLength(providerID: providerID, modelID: modelID)
    }

    /// Reads the lookup the shared store built in the background, O(1). Until it is built the store hands out
    /// `.empty`: messages keep the providerName / modelName they carry (the names at send time), and the context
    /// window is treated as unknown.
    @MainActor
    static func current(from store: ConversationModelLookupStore) -> Self {
        Self(lookup: store.lookup)
    }
}

nonisolated enum ChatCollectionProjectionBuilder {
    private static let compactTopPadding: CGFloat = 8
    private static let groupedTopPadding: CGFloat = 24

    nonisolated enum PresentationKind: Hashable, Sendable {
        case user
        case assistant
        case spacer
    }

    nonisolated struct MessageItem: Hashable, Sendable {
        let id: UUID
        let presentationKind: PresentationKind
        let spacerHeight: CGFloat

        init(
            id: UUID,
            presentationKind: PresentationKind,
            spacerHeight: CGFloat = 0
        ) {
            self.id = id
            self.presentationKind = presentationKind
            self.spacerHeight = spacerHeight
        }
    }

    nonisolated struct MessageRow: Identifiable, Equatable, Sendable {
        let message: ChatMessage
        let showMetadata: Bool
        let resolvedProviderName: String?
        let resolvedModelName: String?
        let relayKind: RelayKind?
        var relayAvatar: RelayAvatar? = nil
        let noteReferences: [NoteSummary]
        let noteBadgePresentation: NoteBadgePresentation
        var renderHint: MarkdownRenderHint?
        let topPadding: CGFloat
        let isLastInConversation: Bool
        /// Secondary note under the reply (relay web search was not used); comes only from ChatManager in-process memory, not stored on the message.
        var replyNotice: RelayWebReplyNotice? = nil
        /// Compaction separator row: attached only to the first message after coversTo, drawn at the top of that cell.
        var compactionSeparator: ContextCompactionSeparator? = nil
        /// "Set as instruction" suggestion bar: attached only to the user message the pending suggestion belongs to, drawn below the bubble.
        var showsDirectiveSuggestion: Bool = false
        /// "Save to memory?" bar: attached only to the assistant message of this turn that the suggestion belongs to,
        /// appears only after streaming ends and is drawn after the metadata action row.
        var memorySuggestion: MemorySuggestionBar? = nil
        /// Vision input projection of the current model: attached only to user messages carrying images;
        /// when it is a placeholder the bubble shows "not sent to this model" under the attachments; rows are rebuilt when the model or the negative cache changes.
        var visionInput: CapabilityEvidenceFacade.InputCapabilityProjection? = nil

        nonisolated var id: UUID { message.id }
    }

    nonisolated enum NoteBadgePresentation: Equatable, Sendable {
        case none
        case single(UUID)
        case multiple([UUID])
    }

    nonisolated struct MessageRenderModel: Equatable, Sendable {
        let messageID: UUID
        let message: ChatMessage
        let presentationKind: PresentationKind
        let showMetadata: Bool
        let resolvedProviderName: String?
        let resolvedModelName: String?
        let relayKind: RelayKind?
        /// Avatar of the relay connection; nil means this is not a relay message and the plain relayKind logo is used.
        let relayAvatar: RelayAvatar?
        let noteReferences: [NoteSummary]
        let noteBadgePresentation: NoteBadgePresentation
        let renderHint: MarkdownRenderHint?
        let topPadding: CGFloat
        let displayText: String?
        let textHash: Int
        let isStreaming: Bool
        let providerMetadataVersion: UInt
        let isLastInConversation: Bool
        /// Secondary note under the reply (passed through from MessageRow).
        let replyNotice: RelayWebReplyNotice?
        /// Compaction separator (passed through from MessageRow); part of Equatable, so adding or removing the row triggers a reconfigure.
        let compactionSeparator: ContextCompactionSeparator?
        /// Suggestion bar (passed through from MessageRow); part of Equatable, so appearing / disappearing triggers a reconfigure.
        let showsDirectiveSuggestion: Bool
        /// Memory bar (passed through from MessageRow); part of Equatable, so appearing / disappearing / a new candidate triggers a reconfigure.
        let memorySuggestion: MemorySuggestionBar?
        /// Passed through from MessageRow; part of Equatable, so a change in placeholder state triggers a reconfigure.
        let visionInput: CapabilityEvidenceFacade.InputCapabilityProjection?

        init(
            messageID: UUID,
            message: ChatMessage,
            presentationKind: PresentationKind,
            showMetadata: Bool,
            resolvedProviderName: String?,
            resolvedModelName: String?,
            relayKind: RelayKind?,
            relayAvatar: RelayAvatar? = nil,
            noteReferences: [NoteSummary] = [],
            noteBadgePresentation: NoteBadgePresentation = .none,
            renderHint: MarkdownRenderHint?,
            topPadding: CGFloat,
            displayText: String?,
            textHash: Int,
            isStreaming: Bool,
            providerMetadataVersion: UInt,
            isLastInConversation: Bool = true,
            replyNotice: RelayWebReplyNotice? = nil,
            compactionSeparator: ContextCompactionSeparator? = nil,
            showsDirectiveSuggestion: Bool = false,
            memorySuggestion: MemorySuggestionBar? = nil,
            visionInput: CapabilityEvidenceFacade.InputCapabilityProjection? = nil
        ) {
            self.messageID = messageID
            self.message = message
            self.presentationKind = presentationKind
            self.showMetadata = showMetadata
            self.resolvedProviderName = resolvedProviderName
            self.resolvedModelName = resolvedModelName
            self.relayKind = relayKind
            self.relayAvatar = relayAvatar
            self.noteReferences = noteReferences
            self.noteBadgePresentation = noteBadgePresentation
            self.renderHint = renderHint
            self.topPadding = topPadding
            self.displayText = displayText
            self.textHash = textHash
            self.isStreaming = isStreaming
            self.providerMetadataVersion = providerMetadataVersion
            self.isLastInConversation = isLastInConversation
            self.replyNotice = replyNotice
            self.compactionSeparator = compactionSeparator
            self.showsDirectiveSuggestion = showsDirectiveSuggestion
            self.memorySuggestion = memorySuggestion
            self.visionInput = visionInput
        }
    }

    nonisolated struct SnapshotPlan: Equatable, Sendable {
        let items: [MessageItem]
        let renderModelsByID: [UUID: MessageRenderModel]
    }

    nonisolated struct MarkdownHintRefreshKey: Equatable, Sendable {
        nonisolated struct Entry: Equatable, Sendable {
            let id: UUID
            let contentHash: Int
        }

        let entries: [Entry]
    }

    nonisolated struct MarkdownHintRefreshDelta: Equatable, Sendable {
        let refreshedEntries: [MarkdownHintRefreshKey.Entry]
        let removedIDs: [UUID]

        var isEmpty: Bool {
            refreshedEntries.isEmpty && removedIDs.isEmpty
        }
    }

    nonisolated static func makeRows(
        from messages: [ChatMessage],
        metadata: ChatCollectionProviderMetadata,
        noteReferencesByMessageID: [UUID: [NoteSummary]] = [:],
        replyNotices: [UUID: RelayWebReplyNotice] = [:],
        compactionSeparator: ContextCompactionSeparator? = nil,
        directiveSuggestionMessageID: UUID? = nil,
        memorySuggestion: MemorySuggestionBar? = nil,
        currentVisionInput: CapabilityEvidenceFacade.InputCapabilityProjection? = nil
    ) -> [MessageRow] {
        var rows: [MessageRow] = []
        rows.reserveCapacity(messages.count)
        let separatorAnchorID = compactionSeparator.flatMap { UUID(uuidString: $0.anchorMessageId) }

        for index in messages.indices {
            let message = messages[index]
            let previousRole = index > 0 ? messages[index - 1].role : nil
            // The first message after coversTo carries the separator; it is not drawn when coversTo is outside the loaded window or is the last message.
            let separator = index > 0 && separatorAnchorID != nil && messages[index - 1].id == separatorAnchorID
                ? compactionSeparator
                : nil
            let isLastAssistant = message.role == .assistant &&
                (index == messages.count - 1 || messages[index + 1].role != .assistant)
            let isLastInConversation = index == messages.count - 1
            let noteReferences = noteReferencesByMessageID[message.id] ?? []
            let noteBadgePresentation: NoteBadgePresentation = {
                switch noteReferences.count {
                case 0: return .none
                case 1: return .single(noteReferences[0].id)
                default: return .multiple(noteReferences.map(\.id))
                }
            }()

            rows.append(
                MessageRow(
                    message: message,
                    showMetadata: message.role == .user || isLastAssistant,
                    resolvedProviderName: metadata.resolvedProviderName(for: message),
                    resolvedModelName: metadata.resolvedModelName(for: message),
                    relayKind: metadata.relayKind(for: message),
                    relayAvatar: metadata.relayAvatar(for: message),
                    noteReferences: noteReferences,
                    noteBadgePresentation: noteBadgePresentation,
                    renderHint: nil,
                    topPadding: previousRole == message.role
                        ? compactTopPadding
                        : groupedTopPadding,
                    isLastInConversation: isLastInConversation,
                    replyNotice: message.role == .assistant ? replyNotices[message.id] : nil,
                    compactionSeparator: separator,
                    showsDirectiveSuggestion: message.role == .user && message.id == directiveSuggestionMessageID,
                    memorySuggestion: message.role == .assistant
                        && message.state != .generating
                        && message.id == memorySuggestion?.messageID
                        ? memorySuggestion
                        : nil,
                    visionInput: message.role == .user
                        && (message.attachments ?? []).contains { $0.kind == .image }
                        ? currentVisionInput
                        : nil
                )
            )
        }

        return rows
    }

    nonisolated static func makeSnapshotPlan(
        from rows: [MessageRow],
        streamingMessageID: UUID? = nil,
        streamingText: String = "",
        providerMetadataVersion: UInt
    ) -> SnapshotPlan {
        var items: [MessageItem] = []
        items.reserveCapacity(rows.count)

        var renderModelsByID: [UUID: MessageRenderModel] = [:]
        renderModelsByID.reserveCapacity(rows.count)

        for row in rows {
            let presentationKind: PresentationKind = row.message.role == .user ? .user : .assistant
            let displayText: String? = streamingMessageID == row.message.id ? streamingText : nil
            let effectiveText = displayText ?? row.message.text

            items.append(
                MessageItem(
                    id: row.message.id,
                    presentationKind: presentationKind
                )
            )

            renderModelsByID[row.message.id] = MessageRenderModel(
                messageID: row.message.id,
                message: row.message,
                presentationKind: presentationKind,
                showMetadata: row.showMetadata,
                resolvedProviderName: row.resolvedProviderName,
                resolvedModelName: row.resolvedModelName,
                relayKind: row.relayKind,
                relayAvatar: row.relayAvatar,
                noteReferences: row.noteReferences,
                noteBadgePresentation: row.noteBadgePresentation,
                renderHint: row.renderHint,
                topPadding: row.topPadding,
                displayText: displayText,
                textHash: effectiveText.hashValue,
                isStreaming: row.message.state == .generating,
                providerMetadataVersion: providerMetadataVersion,
                isLastInConversation: row.isLastInConversation,
                replyNotice: row.replyNotice,
                compactionSeparator: row.compactionSeparator,
                showsDirectiveSuggestion: row.showsDirectiveSuggestion,
                memorySuggestion: row.memorySuggestion,
                visionInput: row.visionInput
            )
        }

        return SnapshotPlan(items: items, renderModelsByID: renderModelsByID)
    }

    nonisolated static func markdownHintRefreshKey(messages: [ChatMessage]) -> MarkdownHintRefreshKey {
        MarkdownHintRefreshKey(
            entries: messages.compactMap { message in
                guard message.role == .assistant,
                      message.state != .generating,
                      !message.text.isEmpty else { return nil }
                return MarkdownHintRefreshKey.Entry(
                    id: message.id,
                    contentHash: MarkdownRenderHint.hash(for: message.text)
                )
            }
        )
    }

    nonisolated static func markdownHintRefreshDelta(
        from previous: MarkdownHintRefreshKey,
        to next: MarkdownHintRefreshKey
    ) -> MarkdownHintRefreshDelta {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.id, $0) })
        let nextByID = Dictionary(uniqueKeysWithValues: next.entries.map { ($0.id, $0) })

        let refreshedEntries = next.entries.filter { entry in
            previousByID[entry.id] != entry
        }
        let removedIDs = previous.entries.compactMap { entry in
            nextByID[entry.id] == nil ? entry.id : nil
        }

        return MarkdownHintRefreshDelta(
            refreshedEntries: refreshedEntries,
            removedIDs: removedIDs
        )
    }
}

struct ChatCollectionViewModel {
    let conversationID: UUID?
    let messageRevision: UInt
    let rows: [ChatCollectionProjectionBuilder.MessageRow]
    let isSendingMessage: Bool
    let streamingMessageID: UUID?
    let streamingText: String
    let pendingAnchorUserMessageID: UUID?
    let pendingSearchScrollTarget: PendingSearchScrollTarget?
    let isBootstrappingPersistedConversation: Bool
    let retryCapabilitySelection: ChatCapabilitySelection
    /// Separator for the latestValid compaction row (computed from the full history); the rows must be rebuilt when it changes, even if the message revision did not.
    var compactionSeparator: ContextCompactionSeparator? = nil
    /// The user message the pending "set as instruction" suggestion is attached to; rows must be rebuilt when it appears / disappears.
    var directiveSuggestionMessageID: UUID? = nil
    /// The pending memory bar (which assistant message it is attached to and what it shows); rows must be rebuilt when it appears / disappears.
    var memorySuggestion: MemorySuggestionBar? = nil
    /// The current model's vision input projection; rows must be rebuilt when it changes (the "not sent to this model" caption on user bubbles with images).
    var currentVisionInput: CapabilityEvidenceFacade.InputCapabilityProjection? = nil
}
