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

    nonisolated func resolvedContextLength(for message: ChatMessage) -> Int? {
        guard let providerID = message.providerID,
              let modelID = message.modelID,
              modelID.isEmpty == false else {
            return nil
        }
        return lookup.contextLength(providerID: providerID, modelID: modelID)
    }

    @MainActor
    static func resolve(from providers: [Provider], metadata: MetadataClient = .shared) -> Self {
        Self(lookup: ModelDisplayLookup(providers: providers, metadata: metadata))
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
        let resolvedContextLength: Int?
        let noteReferences: [NoteSummary]
        let noteBadgePresentation: NoteBadgePresentation
        var renderHint: MarkdownRenderHint?
        let topPadding: CGFloat
        let isLastInConversation: Bool

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
        let resolvedContextLength: Int?
        let noteReferences: [NoteSummary]
        let noteBadgePresentation: NoteBadgePresentation
        let renderHint: MarkdownRenderHint?
        let topPadding: CGFloat
        let displayText: String?
        let textHash: Int
        let isStreaming: Bool
        let providerMetadataVersion: UInt
        let isLastInConversation: Bool

        init(
            messageID: UUID,
            message: ChatMessage,
            presentationKind: PresentationKind,
            showMetadata: Bool,
            resolvedProviderName: String?,
            resolvedModelName: String?,
            relayKind: RelayKind?,
            resolvedContextLength: Int? = nil,
            noteReferences: [NoteSummary] = [],
            noteBadgePresentation: NoteBadgePresentation = .none,
            renderHint: MarkdownRenderHint?,
            topPadding: CGFloat,
            displayText: String?,
            textHash: Int,
            isStreaming: Bool,
            providerMetadataVersion: UInt,
            isLastInConversation: Bool = true
        ) {
            self.messageID = messageID
            self.message = message
            self.presentationKind = presentationKind
            self.showMetadata = showMetadata
            self.resolvedProviderName = resolvedProviderName
            self.resolvedModelName = resolvedModelName
            self.relayKind = relayKind
            self.resolvedContextLength = resolvedContextLength
            self.noteReferences = noteReferences
            self.noteBadgePresentation = noteBadgePresentation
            self.renderHint = renderHint
            self.topPadding = topPadding
            self.displayText = displayText
            self.textHash = textHash
            self.isStreaming = isStreaming
            self.providerMetadataVersion = providerMetadataVersion
            self.isLastInConversation = isLastInConversation
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
        noteReferencesByMessageID: [UUID: [NoteSummary]] = [:]
    ) -> [MessageRow] {
        var rows: [MessageRow] = []
        rows.reserveCapacity(messages.count)

        for index in messages.indices {
            let message = messages[index]
            let previousRole = index > 0 ? messages[index - 1].role : nil
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
                    resolvedContextLength: metadata.resolvedContextLength(for: message),
                    noteReferences: noteReferences,
                    noteBadgePresentation: noteBadgePresentation,
                    renderHint: nil,
                    topPadding: previousRole == message.role
                        ? compactTopPadding
                        : groupedTopPadding,
                    isLastInConversation: isLastInConversation
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
                resolvedContextLength: row.resolvedContextLength,
                noteReferences: row.noteReferences,
                noteBadgePresentation: row.noteBadgePresentation,
                renderHint: row.renderHint,
                topPadding: row.topPadding,
                displayText: displayText,
                textHash: effectiveText.hashValue,
                isStreaming: row.message.state == .generating,
                providerMetadataVersion: providerMetadataVersion,
                isLastInConversation: row.isLastInConversation
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
}
