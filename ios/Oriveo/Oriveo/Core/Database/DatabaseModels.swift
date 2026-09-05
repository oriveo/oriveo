import Foundation
import GRDB

struct ConversationSummary: Identifiable, Hashable {
    let id: UUID
    var title: String
    var hasCustomTitle: Bool
    var providerID: UUID
    var providerKind: ProviderKind
    var modelID: String
    var previewText: String
    var messageCount: Int
    var remoteMessageCount: Int = 0
    var estimatedCost: Double
    var isDraft: Bool
    var draftText: String
    var createdAt: Date
    var updatedAt: Date
    var folderID: UUID?
    var useMemory: Bool
    var skillId: UUID?
    var metadataUpdatedAt: Date? = nil
    var messagesHydratedAt: Date?
    var messagesStale: Bool
    var deletedAt: Date?
    var isConflictCopy: Bool = false
    var originalConversationId: UUID?
    var pinnedNoteIds: [UUID] = []

    nonisolated var isVisibleInConversationList: Bool {
        ConversationVisibility.isVisible(
            folderID: folderID,
            isDraft: isDraft,
            messageCount: messageCount
        )
    }

    nonisolated var isVisibleInUngroupedConversationList: Bool {
        folderID == nil && isVisibleInConversationList && !isConflictCopy
    }
}

struct ConversationThread: Hashable {
    var summary: ConversationSummary
    var messages: [ChatMessage]
}

struct ConversationRecord {
    let id: String
    let title: String
    let hasCustomTitle: Bool
    let providerID: String
    let providerKind: String
    let modelID: String
    let previewText: String
    let messageCount: Int
    let remoteMessageCount: Int
    let estimatedCost: Double
    let isDraft: Bool
    let draftText: String
    let createdAt: Double
    let updatedAt: Double
    let folderID: String?
    let useMemory: Bool
    let skillId: String?
    let metadataUpdatedAt: Double?
    let messagesHydratedAt: Double?
    let messagesStale: Bool
    let deletedAt: Double?
    let isConflictCopy: Bool
    let originalConversationId: String?
    let pinnedNoteIds: String?

    nonisolated init(row: Row) {
        id = row["id"]
        title = row["title"]
        hasCustomTitle = row["hasCustomTitle"]
        providerID = row["providerID"]
        providerKind = row["providerKind"]
        modelID = row["modelID"]
        previewText = row["previewText"]
        messageCount = row["messageCount"]
        remoteMessageCount = row["remoteMessageCount"] ?? 0
        estimatedCost = row["estimatedCost"]
        isDraft = row["isDraft"]
        draftText = row["draftText"]
        createdAt = row["createdAt"]
        updatedAt = row["updatedAt"]
        folderID = row["folderID"]
        useMemory = row["useMemory"]
        skillId = row["skillId"]
        metadataUpdatedAt = row["metadataUpdatedAt"]
        messagesHydratedAt = row["messagesHydratedAt"]
        messagesStale = row["messagesStale"]
        deletedAt = row["deletedAt"]
        isConflictCopy = row["isConflictCopy"]
        originalConversationId = row["originalConversationId"]
        pinnedNoteIds = row["pinnedNoteIds"]
    }
}

struct MessageRecord {
    let id: String
    let conversationID: String
    let role: String
    let text: String
    let quoteContext: String?
    let providerID: String?
    let providerKind: String
    let providerName: String
    let modelID: String?
    let modelName: String
    let servedModelID: String?
    let estimatedCost: Double
    let state: String
    let errorTitle: String?
    let errorDetail: String?
    let createdAt: Double?
    let sortOrder: Int
    let citations: String?
    let reasoningText: String?
    let reasoningDurationMs: Int64?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cachedInputTokens: Int?
    let cacheCreation5mTokens: Int?
    let cacheCreation1hTokens: Int?
    let costSource: String?
    let capabilityExecution: String?
    let unhandledToolCalls: String?

    nonisolated init(row: Row) {
        id = row["id"]
        conversationID = row["conversationID"]
        role = row["role"]
        text = row["text"]
        quoteContext = row["quoteContext"]
        providerID = row["providerID"]
        providerKind = row["providerKind"]
        providerName = row["providerName"]
        modelID = row["modelID"]
        modelName = row["modelName"]
        servedModelID = row["servedModelID"]
        estimatedCost = row["estimatedCost"]
        state = row["state"]
        errorTitle = row["errorTitle"]
        errorDetail = row["errorDetail"]
        createdAt = row["createdAt"]
        sortOrder = row["sortOrder"]
        citations = row["citations"]
        reasoningText = row["reasoningText"]
        reasoningDurationMs = row["reasoningDurationMs"]
        inputTokens = row["inputTokens"]
        outputTokens = row["outputTokens"]
        cacheCreationInputTokens = row["cacheCreationInputTokens"]
        cachedInputTokens = row["cachedInputTokens"]
        cacheCreation5mTokens = row["cacheCreation5mTokens"]
        cacheCreation1hTokens = row["cacheCreation1hTokens"]
        costSource = row["costSource"]
        capabilityExecution = row["capabilityExecution"]
        unhandledToolCalls = row["unhandledToolCalls"]
    }
}

struct AttachmentRecord {
    let id: String
    let messageID: String
    let kind: String
    let fileName: String
    let mimeType: String
    let localFileID: String?
    let localImageID: String?
    let thumbnailBase64: String?
    let sortOrder: Int
    let extractedTotalLines: Int?
    let extractedTruncated: Bool?
    let extractedSizeBytes: Int?
    let extractionErrorCode: String?    // D18
    let originalFileID: String?

    nonisolated init(row: Row) {
        id = row["id"]
        messageID = row["messageID"]
        kind = row["kind"]
        fileName = row["fileName"]
        mimeType = row["mimeType"]
        localFileID = row["localFileID"]
        localImageID = row["localImageID"]
        thumbnailBase64 = row["thumbnailBase64"]
        sortOrder = row["sortOrder"]
        extractedTotalLines = row["extractedTotalLines"]
        extractedTruncated = row["extractedTruncated"]
        extractedSizeBytes = row["extractedSizeBytes"]
        extractionErrorCode = row["extractionErrorCode"]
        originalFileID = row["originalFileID"]
    }
}


nonisolated struct NoteRecallCandidate: Identifiable, Sendable {
    static let maxTitleCharacters = 512
    static let maxBodyCharacters = 32_768
    static let maxTagJSONCharacters = 8_192
    static let maxTags = 32
    static let maxTagCharacters = 128
    static let maxSourceCharacters = 256

    let id: UUID
    let title: String
    let body: String
    let tags: [String]
    let sourceModelName: String?
    let sourceProviderKind: ProviderKind?
    let sourceProviderName: String?
    let captureKind: NoteCaptureKind
    let updatedAt: Date
}

nonisolated struct NoteSummary: Identifiable, Hashable, Sendable {
    static let bodyProjectionCharacters = NoteRecallCandidate.maxBodyCharacters

    let id: UUID
    var title: String
    var titleSource: NoteTitleSource
    var body: String
    var tags: [String]
    var noteFolderID: UUID?
    var sourceConversationId: UUID? = nil
    var sourceMessageId: UUID? = nil
    var sourceModelName: String?
    var sourceProviderKind: ProviderKind?
    var sourceProviderName: String?
    var captureKind: NoteCaptureKind
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    nonisolated var isTrashed: Bool { deletedAt != nil }

    nonisolated var showsSourceBadge: Bool {
        captureKind != .blank && (sourceProviderKind != nil || sourceModelName != nil)
    }
}

struct NoteRecord {
    let id: String
    let title: String
    let titleSource: String
    let body: String
    let bodySnapshot: String?
    let userNote: String?
    let tagsJSON: String
    let noteFolderID: String?
    let sourceConversationId: String?
    let sourceMessageId: String?
    let sourceModelID: String?
    let sourceModelName: String?
    let sourceProviderKind: String?
    let sourceProviderName: String?
    let sourcePrompt: String?
    let captureKind: String
    let provenanceJSON: String?
    let isPinned: Bool
    let createdAt: Double
    let updatedAt: Double
    let deletedAt: Double?

    nonisolated init(row: Row) {
        id = row["id"]
        title = row["title"]
        titleSource = row["titleSource"]
        body = row["body"]
        bodySnapshot = row["bodySnapshot"]
        userNote = row["userNote"]
        tagsJSON = row["tags"]
        noteFolderID = row["noteFolderID"]
        sourceConversationId = row["sourceConversationId"]
        sourceMessageId = row["sourceMessageId"]
        sourceModelID = row["sourceModelID"]
        sourceModelName = row["sourceModelName"]
        sourceProviderKind = row["sourceProviderKind"]
        sourceProviderName = row["sourceProviderName"]
        sourcePrompt = row["sourcePrompt"]
        captureKind = row["captureKind"]
        provenanceJSON = row["provenance"]
        isPinned = row["isPinned"]
        createdAt = row["createdAt"]
        updatedAt = row["updatedAt"]
        deletedAt = row["deletedAt"]
    }
}

struct NoteFolderRecord {
    let id: String
    let name: String
    let sortOrder: Int
    let colorTag: String?
    let createdAt: Double
    let updatedAt: Double
    let deletedAt: Double?

    nonisolated init(row: Row) {
        id = row["id"]
        name = row["name"]
        sortOrder = row["sortOrder"]
        colorTag = row["colorTag"]
        createdAt = row["createdAt"]
        updatedAt = row["updatedAt"]
        deletedAt = row["deletedAt"]
    }
}

struct ConversationFolderAssignment: Hashable {
    let conversationID: UUID
    let folderID: UUID
    let metadataUpdatedAt: Date?
}
