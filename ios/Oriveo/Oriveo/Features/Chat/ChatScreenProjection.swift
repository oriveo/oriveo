import Foundation

enum ChatLoadState: Equatable {
    case localFailure
    case deleted
    case content
    case backfilling
    case bootstrapping
    case stalled
    case empty
}

enum MessageBackfillPhase: Equatable {
    case idle
    case skipped
    case running
    case succeededWithDocs
    case succeededEmpty
    case failed
}

struct ChatScreenProjection: Equatable {
    let requestedConversationID: UUID?
    let summary: ConversationSummary?
    let messages: [ChatMessage]
    let hasLoadedSummary: Bool
    let messageRevision: UInt
    var localLoadFailed: Bool = false
    var bootstrapWatchdogExpired: Bool = false
    var backfillPhase: MessageBackfillPhase = .idle

    var activeConversationID: UUID? {
        summary?.id ?? requestedConversationID
    }

    var providerID: UUID? {
        summary?.providerID
    }

    var modelID: String? {
        summary?.modelID
    }

    var skillID: UUID? {
        summary?.skillId
    }

    var draftText: String {
        summary?.draftText ?? ""
    }

    var useMemory: Bool {
        summary?.useMemory ?? true
    }

    var estimatedCost: Double {
        summary?.estimatedCost ?? 0
    }

    var messageCount: Int {
        messages.count
    }

    var exportsEnabled: Bool {
        !messages.isEmpty
    }

    var isSendingMessage: Bool {
        guard let lastMessage = messages.last else { return false }
        return lastMessage.role == .assistant && lastMessage.state == .generating
    }

    var isMissingPersistedConversation: Bool {
        requestedConversationID != nil && hasLoadedSummary && summary == nil
    }

    var loadState: ChatLoadState {
        if localLoadFailed { return .localFailure }
        if isMissingPersistedConversation { return .deleted }
        if !messages.isEmpty { return .content }
        guard requestedConversationID != nil else { return .empty }
        if let summary,
           summary.isDraft || !summary.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .empty
        }
        if backfillPhase == .skipped, let summary, !Self.hasRemoteHistoryEvidence(summary) {
            return .empty
        }
        // An in-flight one-time read remains a visible recovery state even if
        // it takes longer than the bootstrap watchdog threshold.
        if backfillPhase == .running { return .backfilling }
        if backfillPhase == .failed { return .stalled }
        if bootstrapWatchdogExpired { return .stalled }
        if backfillPhase == .succeededEmpty {
            if let summary, Self.hasRemoteHistoryEvidence(summary) { return .stalled }
            return .empty
        }
        return .bootstrapping
    }

    private static func hasRemoteHistoryEvidence(_ summary: ConversationSummary) -> Bool {
        summary.remoteMessageCount > 0
            || summary.messageCount > 0
            || !summary.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isBootstrappingPersistedConversation: Bool {
        loadState == .bootstrapping || loadState == .backfilling
    }

    var isBootstrapStalled: Bool {
        loadState == .stalled
    }
}
