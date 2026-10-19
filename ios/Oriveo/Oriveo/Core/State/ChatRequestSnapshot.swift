import Foundation
import OriveoProviderKit

nonisolated enum ChatRequestSendPath: Sendable, Equatable {
    case send(excludingMessageID: UUID?)
    case continueResponse(assistantMessageID: UUID)
}

nonisolated struct ChatRequestConversationSnapshot: Sendable, Equatable {
    let id: UUID
    let useMemory: Bool
    let skillID: UUID?
    /// Conversation instructions (already normalized); passed in when assembling chat / continue / toolLoopLeg / imageGeneration.
    var instructions: String = ""
    /// The folder the conversation lives in; memory items with folder scope are filtered by it.
    var folderID: UUID? = nil
}

/// Request building only reads memory items: a copy of the current partition's items (no tombstones), taken from
/// AppState's in-memory cache so the database is never read on the main thread. The injection filter runs
/// `MemoryItems.injectable` at assembly time. memoryText is only dual-written for older clients and is no longer injected.
/// Anti-forget (`memoryAntiForgetEnabled/Text`) no longer injects anything.
nonisolated struct ChatRequestPreferencesSnapshot: Sendable, Equatable {
    var memoryItems: [MemoryItem]

    init(memoryItems: [MemoryItem] = []) {
        self.memoryItems = memoryItems
    }
}

nonisolated struct ChatRequestKnowledgeFileSnapshot: Sendable, Equatable {
    let name: String
    let content: String

    init(name: String, content: String) {
        self.name = name
        self.content = content
    }

    @MainActor
    init(_ file: SkillKnowledgeFile) {
        name = file.name
        content = file.content
    }
}

nonisolated struct ChatRequestKnowledgeBaseSnapshot: Sendable, Equatable {
    let retrievalModel: String
    let vectorStoreId: String
    let readyFileCount: Int
    let fileCount: Int

    init(
        retrievalModel: String,
        vectorStoreId: String,
        readyFileCount: Int
    ) {
        self.retrievalModel = retrievalModel
        self.vectorStoreId = vectorStoreId
        self.readyFileCount = readyFileCount
        self.fileCount = readyFileCount
    }

    @MainActor
    init(_ knowledgeBase: SkillKnowledgeBase) {
        retrievalModel = knowledgeBase.retrievalModel
        vectorStoreId = knowledgeBase.vectorStoreId
        readyFileCount = knowledgeBase.files.filter { $0.status == .ready }.count
        fileCount = knowledgeBase.files.count
    }
}

nonisolated struct ChatRequestRetrievedSnippet: Sendable, Equatable {
    let fileName: String
    let text: String
    let score: Double
}

nonisolated struct ChatRequestSkillSnapshot: Sendable, Equatable {
    let id: UUID
    let systemPrompt: String
    let knowledgeFiles: [ChatRequestKnowledgeFileSnapshot]
    let knowledgeBase: ChatRequestKnowledgeBaseSnapshot?
    let useMemory: Bool

    init(
        id: UUID,
        systemPrompt: String,
        knowledgeFiles: [ChatRequestKnowledgeFileSnapshot],
        knowledgeBase: ChatRequestKnowledgeBaseSnapshot? = nil,
        useMemory: Bool
    ) {
        self.id = id
        self.systemPrompt = systemPrompt
        self.knowledgeFiles = knowledgeFiles
        self.knowledgeBase = knowledgeBase
        self.useMemory = useMemory
    }

    @MainActor
    init(_ skill: Skill) {
        id = skill.id
        systemPrompt = skill.systemPrompt
        knowledgeFiles = skill.knowledgeFiles.map(ChatRequestKnowledgeFileSnapshot.init)
        knowledgeBase = skill.knowledgeBase.map(ChatRequestKnowledgeBaseSnapshot.init)
        useMemory = skill.useMemory
    }
}

nonisolated struct ChatRequestSnapshot: Sendable {
    let conversation: ChatRequestConversationSnapshot?
    let messages: [ChatMessage]
    let preferences: ChatRequestPreferencesSnapshot
    let skill: ChatRequestSkillSnapshot?
    let retrievedSnippets: [ChatRequestRetrievedSnippet]
    let pinnedNotes: [ChatRequestPinnedNoteSnapshot]
    let sendPath: ChatRequestSendPath
    /// Library evidence for this message (goes into [D] `<oriveo-library>`). nil = the library was not searched; empty array = searched but no evidence.
    /// The evidence is read back inside the send task, so it is not part of init; `withLibrary` fills it in before the builder gets it.
    private(set) var library: [ContextLibraryEntry]?
    /// This turn's L3 recall (goes into [D] `<oriveo-recall>`): searched once in the send task from the item snapshot (same source as L2);
    /// every leg of the same turn and the overflow-fallback reassembly reuse this one copy; empty when effective useMemory is off.
    private(set) var recall: [ContextRecallEntry] = []

    init(
        conversation: ChatRequestConversationSnapshot?,
        messages: [ChatMessage],
        preferences: ChatRequestPreferencesSnapshot,
        skill: ChatRequestSkillSnapshot?,
        retrievedSnippets: [ChatRequestRetrievedSnippet] = [],
        pinnedNotes: [ChatRequestPinnedNoteSnapshot] = [],
        sendPath: ChatRequestSendPath
    ) {
        self.conversation = conversation
        self.messages = messages
        self.preferences = preferences
        self.skill = skill
        self.retrievedSnippets = retrievedSnippets
        self.pinnedNotes = pinnedNotes
        self.sendPath = sendPath
    }

    func withLibrary(_ entries: [ContextLibraryEntry]) -> ChatRequestSnapshot {
        var snapshot = self
        snapshot.library = entries
        return snapshot
    }

    func withRecall(_ entries: [ContextRecallEntry]) -> ChatRequestSnapshot {
        var snapshot = self
        snapshot.recall = entries
        return snapshot
    }

    /// The useMemory that actually applies to this request: the conversation switch wins, then the skill, default on (same rule as builder assembly).
    var effectiveUseMemory: Bool {
        conversation?.useMemory ?? skill?.useMemory ?? true
    }
}
