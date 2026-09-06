import Foundation

enum ChatLoadState: Equatable {
    case localFailure
    case deleted
    case content
    case bootstrapping
    case stalled
    case empty
}

struct ChatScreenProjection: Equatable {
    let requestedConversationID: UUID?
    let summary: ConversationSummary?
    let messages: [ChatMessage]
    let hasLoadedSummary: Bool
    let messageRevision: UInt
    var localLoadFailed: Bool = false
    var bootstrapWatchdogExpired: Bool = false

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
        if bootstrapWatchdogExpired { return .stalled }
        return .bootstrapping
    }

    var isBootstrappingPersistedConversation: Bool {
        loadState == .bootstrapping
    }
}
