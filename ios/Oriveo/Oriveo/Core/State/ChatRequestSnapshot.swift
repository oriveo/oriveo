import Foundation

nonisolated enum ChatRequestSendPath: Sendable, Equatable {
    case send(excludingMessageID: UUID?)
    case continueResponse(assistantMessageID: UUID, instruction: String)
}

nonisolated struct ChatRequestConversationSnapshot: Sendable, Equatable {
    let id: UUID
    let useMemory: Bool
    let skillID: UUID?
}

/// Request building only reads the memory text. Anti-forget (`memoryAntiForgetEnabled/Text`) no longer
/// injects anything: the preference fields are still stored / synced / backed up so existing values
/// survive, but they are not part of the request snapshot.
nonisolated struct ChatRequestPreferencesSnapshot: Sendable, Equatable {
    var memoryText: String

    init(memoryText: String = "") {
        self.memoryText = memoryText
    }

    @MainActor
    init(_ preferences: AppPreference) {
        memoryText = preferences.memoryText
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
}
