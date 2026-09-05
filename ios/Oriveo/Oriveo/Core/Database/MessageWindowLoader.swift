import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class MessageWindowLoader {
    typealias RemoteAnchorHydrator = @MainActor @Sendable (_ conversationID: UUID, _ messageID: UUID) async -> [ChatMessage]

    /// "Cannot infer contextual base in reference to member 'latest'".
    nonisolated enum WindowAnchor: Equatable, Sendable {
        case latest
        case messageID(UUID)
    }

    nonisolated static let windowSize = 60

    private(set) var messages: [ChatMessage] = []

    private(set) var revision: UInt = 0

    private(set) var hasMoreAbove: Bool = false

    private(set) var hasMoreBelow: Bool = false

    private(set) var initialLoadFailed: Bool = false
    private(set) var failedAnchorMessageID: UUID?

    private(set) var anchor: WindowAnchor = .latest

    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var observedConversationID: UUID?
    @ObservationIgnored private var observedDbPool: DatabasePool?
    @ObservationIgnored private var remoteAnchorHydrator: RemoteAnchorHydrator?
    @ObservationIgnored private var attachmentFileStore: AttachmentFileStore?
    @ObservationIgnored private var pendingRemoteAnchorHydrations: Set<UUID> = []
    @ObservationIgnored private var earliestBoundary: ConversationStore.MessageBoundary?
    @ObservationIgnored private var latestBoundary: ConversationStore.MessageBoundary?
    @ObservationIgnored private var isExtending: Bool = false

    private let attachmentFileStoreOverride: AttachmentFileStore?

    init() {
        self.attachmentFileStoreOverride = nil
    }

    init(attachmentFileStore: AttachmentFileStore) {
        self.attachmentFileStoreOverride = attachmentFileStore
    }

    init(
        attachmentFileStore: AttachmentFileStore,
        remoteAnchorHydrator: @escaping RemoteAnchorHydrator
    ) {
        self.attachmentFileStoreOverride = attachmentFileStore
        self.remoteAnchorHydrator = remoteAnchorHydrator
    }

    /// - Parameters:
    func observe(
        conversationID: UUID,
        anchor: WindowAnchor = .latest,
        in dbPool: DatabasePool,
        remoteAnchorHydrator: RemoteAnchorHydrator? = nil
    ) {
        stop()
        observedConversationID = conversationID
        observedDbPool = dbPool
        if let remoteAnchorHydrator {
            self.remoteAnchorHydrator = remoteAnchorHydrator
        }
        self.anchor = anchor
        initialLoadFailed = false
        failedAnchorMessageID = nil
        let attachmentFileStore = attachmentFileStoreOverride
            ?? AttachmentFileStore(rootDirectory: AppSessionStore.filesDir)
        self.attachmentFileStore = attachmentFileStore

        let region = Message.filter(
            Column("conversationID") == conversationID.uuidString
        )

        let observation = ValueObservation.tracking(
            region: region,
            fetch: { [anchor] db in
                try Self.fetchWindowSnapshot(
                    db: db,
                    conversationID: conversationID,
                    anchor: anchor,
                    attachmentFileStore: attachmentFileStore
                )
            }
        )
        let dedupedObservation = observation.removeDuplicates()

        cancellable = dedupedObservation.start(
            in: dbPool,
            scheduling: .immediate,
            onError: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let strongSelf = self, strongSelf.observedConversationID == conversationID else { return }
                    guard strongSelf.messages.isEmpty, strongSelf.revision == 0 else { return }
                    strongSelf.initialLoadFailed = true
                }
            },
            onChange: { [weak self] snapshot in
                MainActor.assumeIsolated {
                    guard let strongSelf = self, strongSelf.observedConversationID == conversationID else { return }
                    strongSelf.applySnapshot(snapshot)
                }
            }
        )
    }

    func extendUpward() {
        guard let conversationID = observedConversationID,
              let dbPool = observedDbPool,
              let boundary = earliestBoundary,
              hasMoreAbove,
              !isExtending else { return }
        isExtending = true
        let attachmentFileStore = attachmentFileStoreOverride
            ?? AttachmentFileStore(rootDirectory: AppSessionStore.filesDir)
        let limit = Self.windowSize

        Task { [weak self] in
            let result = try? await dbPool.read { db in
                try ConversationStore.fetchMessagesBefore(
                    db: db,
                    conversationID: conversationID,
                    boundary: boundary,
                    limit: limit,
                    attachmentFileStore: attachmentFileStore
                )
            }
            guard let strongSelf = self else { return }
            await MainActor.run {
                guard strongSelf.observedConversationID == conversationID else { return }
                strongSelf.isExtending = false
                guard let result, !result.messages.isEmpty else {
                    strongSelf.hasMoreAbove = false
                    return
                }
                strongSelf.messages = Self.excludingDuplicates(result.messages, of: strongSelf.messages)
                    + strongSelf.messages
                strongSelf.earliestBoundary = result.earliestBoundary ?? strongSelf.earliestBoundary
                strongSelf.hasMoreAbove = result.hasMoreAbove
                strongSelf.revision &+= 1
            }
        }
    }

    func extendDownward() {
        guard let conversationID = observedConversationID,
              let dbPool = observedDbPool,
              let boundary = latestBoundary,
              hasMoreBelow,
              !isExtending else { return }
        isExtending = true
        let attachmentFileStore = attachmentFileStoreOverride
            ?? AttachmentFileStore(rootDirectory: AppSessionStore.filesDir)
        let limit = Self.windowSize

        Task { [weak self] in
            let result = try? await dbPool.read { db in
                try ConversationStore.fetchMessagesAfter(
                    db: db,
                    conversationID: conversationID,
                    boundary: boundary,
                    limit: limit,
                    attachmentFileStore: attachmentFileStore
                )
            }
            guard let strongSelf = self else { return }
            await MainActor.run {
                guard strongSelf.observedConversationID == conversationID else { return }
                strongSelf.isExtending = false
                guard let result, !result.messages.isEmpty else {
                    strongSelf.hasMoreBelow = false
                    return
                }
                strongSelf.messages = strongSelf.messages
                    + Self.excludingDuplicates(result.messages, of: strongSelf.messages)
                strongSelf.latestBoundary = result.latestBoundary ?? strongSelf.latestBoundary
                strongSelf.hasMoreBelow = result.hasMoreBelow
                strongSelf.revision &+= 1
            }
        }
    }

    func jump(to messageID: UUID) {
        guard let conversationID = observedConversationID,
              let dbPool = observedDbPool else { return }
        observe(
            conversationID: conversationID,
            anchor: .messageID(messageID),
            in: dbPool
        )
    }

    func jumpToLatest() {
        guard let conversationID = observedConversationID,
              let dbPool = observedDbPool else { return }
        if case .latest = anchor { return }
        observe(
            conversationID: conversationID,
            anchor: .latest,
            in: dbPool
        )
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        observedConversationID = nil
        observedDbPool = nil
        attachmentFileStore = nil
        pendingRemoteAnchorHydrations = []
        anchor = .latest
        initialLoadFailed = false
        failedAnchorMessageID = nil
        messages = []
        revision = 0
        hasMoreAbove = false
        hasMoreBelow = false
        earliestBoundary = nil
        latestBoundary = nil
        isExtending = false
    }

    // MARK: - Private

    private func applySnapshot(_ snapshot: WindowSnapshot) {
        initialLoadFailed = false

        if case .messageID = anchor {
            messages = snapshot.messages
            earliestBoundary = snapshot.earliestBoundary
            latestBoundary = snapshot.latestBoundary
            hasMoreAbove = snapshot.hasMoreAbove
            hasMoreBelow = snapshot.hasMoreBelow
            revision &+= 1
            if case .messageID(let messageID) = anchor,
               snapshot.messages.contains(where: { $0.id == messageID }) == false {
                hydrateMissingRemoteAnchor(messageID)
            }
            return
        }

        if messages.isEmpty {
            messages = snapshot.messages
            earliestBoundary = snapshot.earliestBoundary
            latestBoundary = snapshot.latestBoundary
            hasMoreAbove = snapshot.hasMoreAbove
            hasMoreBelow = snapshot.hasMoreBelow
            revision &+= 1
            return
        }

        guard let snapshotHeadID = snapshot.messages.first?.id else {
            messages = []
            earliestBoundary = nil
            latestBoundary = nil
            hasMoreAbove = false
            hasMoreBelow = false
            revision &+= 1
            return
        }
        if let cutIndex = messages.firstIndex(where: { $0.id == snapshotHeadID }) {
            let newMessages = mergePrefix(upTo: cutIndex, with: snapshot.messages)
            if newMessages != messages {
                messages = newMessages
                revision &+= 1
            }
        } else if let alignedIndex = findSnapshotAlignmentIndex(snapshot: snapshot.messages, in: messages) {
            let newMessages = mergePrefix(upTo: alignedIndex, with: snapshot.messages)
            if newMessages != messages {
                messages = newMessages
                revision &+= 1
            }
        } else {
            messages = snapshot.messages
            earliestBoundary = snapshot.earliestBoundary
            latestBoundary = snapshot.latestBoundary
            hasMoreAbove = snapshot.hasMoreAbove
            hasMoreBelow = snapshot.hasMoreBelow
            revision &+= 1
            return
        }
        latestBoundary = snapshot.latestBoundary
        hasMoreBelow = snapshot.hasMoreBelow
        if earliestBoundary == nil {
            earliestBoundary = snapshot.earliestBoundary
            hasMoreAbove = snapshot.hasMoreAbove
        }
    }

    private func hydrateMissingRemoteAnchor(_ messageID: UUID) {
        guard let conversationID = observedConversationID,
              let dbPool = observedDbPool,
              let attachmentFileStore,
              let remoteAnchorHydrator,
              pendingRemoteAnchorHydrations.contains(messageID) == false
        else { return }
        pendingRemoteAnchorHydrations.insert(messageID)

        Task { [weak self] in
            let remoteMessages = await remoteAnchorHydrator(conversationID, messageID)
            guard remoteMessages.isEmpty == false else {
                await MainActor.run {
                    self?.pendingRemoteAnchorHydrations.remove(messageID)
                    guard self?.observedConversationID == conversationID else { return }
                    self?.failedAnchorMessageID = messageID
                }
                return
            }
            let store = ConversationStore(dbPool: dbPool, attachmentFileStore: attachmentFileStore)
            try? store.upsertHydratedMessages(remoteMessages, conversationID: conversationID)
            await MainActor.run {
                guard self?.observedConversationID == conversationID else { return }
                self?.pendingRemoteAnchorHydrations.remove(messageID)
                self?.failedAnchorMessageID = nil
            }
        }
    }

    private static let snapshotAlignmentProbeLimit = 16

    private static func excludingDuplicates(
        _ incoming: [ChatMessage],
        of existing: [ChatMessage]
    ) -> [ChatMessage] {
        guard existing.isEmpty == false else { return incoming }
        let existingIDs = Set(existing.map(\.id))
        guard incoming.contains(where: { existingIDs.contains($0.id) }) else { return incoming }
        return incoming.filter { existingIDs.contains($0.id) == false }
    }

    /// Drop prefix messages whose IDs already appear in the snapshot so a window
    /// realignment cannot duplicate rows.
    private func mergePrefix(upTo cutIndex: Int, with snapshotMessages: [ChatMessage]) -> [ChatMessage] {
        guard cutIndex > 0 else { return snapshotMessages }
        let prefix = messages[..<cutIndex]
        let snapshotIDs = Set(snapshotMessages.map(\.id))
        guard prefix.contains(where: { snapshotIDs.contains($0.id) }) else {
            return Array(prefix) + snapshotMessages
        }
        return prefix.filter { snapshotIDs.contains($0.id) == false } + snapshotMessages
    }

    private func findSnapshotAlignmentIndex(snapshot: [ChatMessage], in existing: [ChatMessage]) -> Int? {
        let probeCount = min(snapshot.count, Self.snapshotAlignmentProbeLimit)
        guard probeCount > 1 else { return nil }
        var idToIndex: [UUID: Int] = [:]
        idToIndex.reserveCapacity(existing.count)
        for (i, msg) in existing.enumerated() {
            idToIndex[msg.id] = i
        }
        for i in 1..<probeCount {
            if let idx = idToIndex[snapshot[i].id] {
                return idx
            }
        }
        return nil
    }

    nonisolated struct WindowSnapshot: Equatable, Sendable {
        let messages: [ChatMessage]
        let earliestBoundary: ConversationStore.MessageBoundary?
        let latestBoundary: ConversationStore.MessageBoundary?
        let hasMoreAbove: Bool
        let hasMoreBelow: Bool
    }

    nonisolated private static func fetchWindowSnapshot(
        db: Database,
        conversationID: UUID,
        anchor: WindowAnchor,
        attachmentFileStore: AttachmentFileStore
    ) throws -> WindowSnapshot {
        switch anchor {
        case .latest:
            let window = try ConversationStore.fetchLatestMessageWindow(
                db: db,
                conversationID: conversationID,
                limit: windowSize,
                attachmentFileStore: attachmentFileStore
            )
            return WindowSnapshot(
                messages: window.messages,
                earliestBoundary: window.earliestBoundary,
                latestBoundary: window.latestBoundary,
                hasMoreAbove: window.hasMoreAbove,
                hasMoreBelow: window.hasMoreBelow
            )
        case .messageID(let messageID):
            guard let boundary = try ConversationStore.fetchMessageBoundary(
                db: db,
                conversationID: conversationID,
                messageID: messageID
            ) else {
                let window = try ConversationStore.fetchLatestMessageWindow(
                    db: db,
                    conversationID: conversationID,
                    limit: windowSize,
                    attachmentFileStore: attachmentFileStore
                )
                return WindowSnapshot(
                    messages: window.messages,
                    earliestBoundary: window.earliestBoundary,
                    latestBoundary: window.latestBoundary,
                    hasMoreAbove: window.hasMoreAbove,
                    hasMoreBelow: window.hasMoreBelow
                )
            }
            let half = windowSize / 2
            let window = try ConversationStore.fetchMessageWindowAround(
                db: db,
                conversationID: conversationID,
                anchor: boundary,
                before: half,
                after: half,
                attachmentFileStore: attachmentFileStore
            )
            return WindowSnapshot(
                messages: window.messages,
                earliestBoundary: window.earliestBoundary,
                latestBoundary: window.latestBoundary,
                hasMoreAbove: window.hasMoreAbove,
                hasMoreBelow: window.hasMoreBelow
            )
        }
    }
}

private struct Message: TableRecord {
    static let databaseTableName = "message"
}
