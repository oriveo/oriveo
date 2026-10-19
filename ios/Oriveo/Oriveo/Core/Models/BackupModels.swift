import Foundation
import OriveoProviderKit
import UniformTypeIdentifiers
import CryptoKit

// MARK: - UTType

extension UTType {
    static let oriveoBackup = UTType(exportedAs: "ai.oriveo.community.backup")
}


nonisolated struct BackupFile: Codable {
    let version: Int
    let createdAt: String
    let appVersion: String
    let platform: String
    let checksum: String
    let containsKeys: Bool
    let data: BackupData
    let attachmentChecksums: [String: String]?
    let encryptedKeys: String?
}


nonisolated struct BackupData: Codable {
    let providers: [BackupProvider]
    let conversations: [BackupConversation]
    var skills: [Skill]?
    let preferences: BackupPreferences?
    let lastUsedModelRef: LastUsedModelRef?
    var folders: [BackupFolder]?    // Optional: backward compatible with old backups
    var notes: [BackupNote]?              // Optional: backward compatible (old backups lack this field)
    var noteFolders: [BackupNoteFolder]?  // Optional: backward compatible
    var checkpoints: [BackupContextCheckpoint]?  // Optional: backward compatible (old backups lack this field)
    /// Memory item section (including tombstones); old backups lack it and are migrated from the legacy fields in preferences on import. Key names are identical on all platforms.
    var memorySchemaVersion: Int?
    var memoryItems: [MemoryItem]?

    init(
        providers: [BackupProvider],
        conversations: [BackupConversation],
        skills: [Skill]? = nil,
        preferences: BackupPreferences?,
        lastUsedModelRef: LastUsedModelRef?,
        folders: [BackupFolder]? = nil,
        notes: [BackupNote]? = nil,
        noteFolders: [BackupNoteFolder]? = nil,
        checkpoints: [BackupContextCheckpoint]? = nil,
        memorySchemaVersion: Int? = nil,
        memoryItems: [MemoryItem]? = nil
    ) {
        self.providers = providers
        self.conversations = conversations
        self.skills = skills
        self.preferences = preferences
        self.lastUsedModelRef = lastUsedModelRef
        self.folders = folders
        self.notes = notes
        self.noteFolders = noteFolders
        self.checkpoints = checkpoints
        self.memorySchemaVersion = memorySchemaVersion
        self.memoryItems = memoryItems
    }
}


nonisolated struct BackupProvider: Codable {
    let id: UUID
    let kind: ProviderKind
    let baseURLText: String?
    let customName: String?
    let models: [AIModel]
    let catalogModels: [AIModel]
    let relayKind: RelayKind?
    let relayRequested: RelayRequestedConfig?

    init(from provider: Provider) {
        self.id = provider.id
        self.kind = provider.kind
        self.baseURLText = RelayRequestedConfig.credentialFreeEndpoint(provider.baseURLText)
        self.customName = provider.customName
        self.models = provider.models
        self.catalogModels = provider.kind == .relay ? provider.catalogModels : []
        self.relayKind = provider.kind == .relay ? provider.relayKind : nil
        self.relayRequested = provider.relayRequested?.credentialFreePortableCopy()
    }
}


nonisolated struct BackupConversation: Codable {
    let id: UUID
    var title: String
    var hasCustomTitle: Bool
    var providerID: UUID
    var providerKind: ProviderKind
    var modelID: String
    var previewText: String
    var estimatedCost: Double
    var messages: [ChatMessage]
    var updatedAt: Date
    var folderID: UUID?
    var pinnedNoteIds: [UUID]?   // Optional: backward compatible with old backups (missing key = no pinned notes)
    var instructions: String?    // Optional: empty is written as nil; a missing key in old backups = ""
    var contextCap: BackupContextCap?   // Optional: nil writes no key; a missing key or invalid value = follow the global default

    init(from conversation: Conversation) {
        self.id = conversation.id
        self.title = conversation.title
        self.hasCustomTitle = conversation.hasCustomTitle
        self.providerID = conversation.providerID
        self.providerKind = conversation.providerKind
        self.modelID = conversation.modelID
        self.previewText = conversation.previewText
        self.estimatedCost = conversation.estimatedCost
        self.messages = conversation.messages
        self.updatedAt = conversation.updatedAt
        self.folderID = conversation.folderID
        self.pinnedNoteIds = conversation.pinnedNoteIds.isEmpty ? nil : conversation.pinnedNoteIds
        self.instructions = conversation.instructions.isEmpty ? nil : conversation.instructions
        self.contextCap = conversation.contextCap.map(BackupContextCap.init(cap:))
    }

    func toConversation() -> Conversation {
        var conv = Conversation(
            id: id,
            title: title,
            providerID: providerID,
            providerKind: providerKind,
            modelID: modelID,
            previewText: previewText,
            estimatedCost: estimatedCost,
            isDraft: false,
            messages: messages,
            draftText: "",
            updatedAt: updatedAt,
            folderID: folderID
        )
        conv.hasCustomTitle = hasCustomTitle
        conv.pinnedNoteIds = pinnedNoteIds ?? []
        conv.instructions = ConversationInstructions.normalize(instructions ?? "")
        conv.contextCap = contextCap?.cap
        return conv
    }
}

/// A conversation context cap inside a backup: written in wire form ("auto" / "unlimited" / integer), decoded leniently.
/// Invalid values (numeric strings, out-of-range integers, booleans, objects, ...) decode to cap = nil (follow the
/// global default) and never throw; ContextBudgetCap's strict Codable cannot be used directly because it throws on
/// invalid values, which would fail the whole backup import.
nonisolated struct BackupContextCap: Codable, Equatable {
    let cap: ContextBudgetCap?

    init(cap: ContextBudgetCap?) {
        self.cap = cap
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.singleValueContainer() else {
            self.cap = nil
            return
        }
        if (try? container.decode(Bool.self)) != nil {
            self.cap = nil
        } else if let value = try? container.decode(Int.self) {
            self.cap = ContextBudgetCap.parse(value)
        } else if let value = try? container.decode(Double.self) {
            self.cap = ContextBudgetCap.parse(value)
        } else if let value = try? container.decode(String.self) {
            self.cap = ContextBudgetCap.parse(value)
        } else {
            self.cap = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch cap {
        case .auto: try container.encode("auto")
        case .unlimited: try container.encode("unlimited")
        case .custom(let tokens): try container.encode(tokens)
        case nil: try container.encodeNil()
        }
    }
}

// MARK: - Folder in backups

nonisolated struct BackupFolder: Codable {
    let id: UUID
    var name: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(from folder: Folder) {
        self.id = folder.id
        self.name = folder.name
        self.sortOrder = folder.sortOrder
        self.createdAt = folder.createdAt
        self.updatedAt = folder.updatedAt
    }

    func toFolder() -> Folder {
        Folder(
            id: id,
            name: name,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}


nonisolated struct BackupNote: Codable {
    let id: UUID
    var title: String
    var titleSource: NoteTitleSource
    var body: String
    var bodySnapshot: String?
    var userNote: String?
    var tags: [String]
    var noteFolderID: UUID?
    var sourceConversationId: UUID?
    var sourceMessageId: UUID?
    var sourceModelID: String?
    var sourceModelName: String?
    var sourceProviderKind: ProviderKind?
    var sourceProviderName: String?
    var sourcePrompt: String?
    var captureKind: NoteCaptureKind
    var provenance: [ProvenanceEntry]?
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(from note: Note) {
        id = note.id
        title = note.title
        titleSource = note.titleSource
        body = note.body
        bodySnapshot = note.bodySnapshot
        userNote = note.userNote
        tags = note.tags
        noteFolderID = note.noteFolderID
        sourceConversationId = note.sourceConversationId
        sourceMessageId = note.sourceMessageId
        sourceModelID = note.sourceModelID
        sourceModelName = note.sourceModelName
        sourceProviderKind = note.sourceProviderKind
        sourceProviderName = note.sourceProviderName
        sourcePrompt = note.sourcePrompt
        captureKind = note.captureKind
        provenance = note.provenance
        isPinned = note.isPinned
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        deletedAt = note.deletedAt
    }

    func toNote() -> Note {
        Note(
            id: id,
            title: title,
            titleSource: titleSource,
            body: body,
            bodySnapshot: bodySnapshot,
            userNote: userNote,
            tags: tags,
            noteFolderID: noteFolderID,
            sourceConversationId: sourceConversationId,
            sourceMessageId: sourceMessageId,
            sourceModelID: sourceModelID,
            sourceModelName: sourceModelName,
            sourceProviderKind: sourceProviderKind,
            sourceProviderName: sourceProviderName,
            sourcePrompt: sourcePrompt,
            captureKind: captureKind,
            provenance: provenance,
            isPinned: isPinned,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}

nonisolated struct BackupNoteFolder: Codable {
    let id: UUID
    var name: String
    var sortOrder: Int
    var colorTag: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(from folder: NoteFolder) {
        id = folder.id
        name = folder.name
        sortOrder = folder.sortOrder
        colorTag = folder.colorTag
        createdAt = folder.createdAt
        updatedAt = folder.updatedAt
        deletedAt = folder.deletedAt
    }

    func toNoteFolder() -> NoteFolder {
        NoteFolder(
            id: id,
            name: name,
            sortOrder: sortOrder,
            colorTag: colorTag,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}

// MARK: - Context checkpoint in backups (createdAt is an integer in milliseconds; empty optional fields are not encoded)

nonisolated struct BackupContextCheckpoint: Codable, Equatable {
    var conversationId: String
    var checkpointId: String
    var kind: String
    var coversFrom: String
    var coversTo: String
    var coversDigest: String
    var messagesCovered: Int
    var userMessageIds: [String]
    var text: String
    var summary: String?
    var language: String?
    var model: String
    var packerVersion: String
    var createdAt: Int64
    var cost: Double?

    init(from record: ContextCheckpointRecord) {
        conversationId = record.conversationId
        checkpointId = record.checkpointId
        kind = record.kind.rawValue
        coversFrom = record.coversFrom
        coversTo = record.coversTo
        coversDigest = record.coversDigest
        messagesCovered = record.messagesCovered
        userMessageIds = record.userMessageIds
        text = record.text
        summary = record.summary
        language = record.language
        model = record.model
        packerVersion = record.packerVersion
        createdAt = record.createdAt
        cost = record.cost
    }

    /// Nil when the kind is not recognized (the row is dropped on import).
    func toRecord() -> ContextCheckpointRecord? {
        guard let kind = ContextCheckpointRecord.Kind(rawValue: kind) else { return nil }
        return ContextCheckpointRecord(
            conversationId: conversationId,
            checkpointId: checkpointId,
            kind: kind,
            coversFrom: coversFrom,
            coversTo: coversTo,
            coversDigest: coversDigest,
            messagesCovered: messagesCovered,
            userMessageIds: userMessageIds,
            text: text,
            summary: summary,
            language: language,
            model: model,
            packerVersion: packerVersion,
            createdAt: createdAt,
            cost: cost
        )
    }
}

// MARK: - Preferences

nonisolated struct BackupPreferences: Codable {
    let theme: String
    let language: String
    var memoryText: String?
    var memoryAntiForgetEnabled: Bool?
    var memoryAntiForgetText: String?
    var memoryUpdatedAt: String?
}


nonisolated struct BackupKeyEntry: Codable {
    let providerID: UUID
    let apiKey: String
    let apiKeyPreview: String
}

nonisolated struct BackupKeysPayload: Codable {
    let keys: [BackupKeyEntry]
}


enum ImportMode: CaseIterable, Identifiable {
    case importNewOnly
    case merge
    case replaceAll

    var id: Self { self }

    var title: String {
        switch self {
        case .importNewOnly:
            return L10n.tr("Import New Only", table: .backup)
        case .merge:
            return L10n.tr("Merge", table: .backup)
        case .replaceAll:
            return L10n.tr("Replace All", table: .backup)
        }
    }

    var description: String {
        switch self {
        case .importNewOnly:
            return L10n.tr("Skip existing conversations and providers; only add new ones.", table: .backup)
        case .merge:
            return L10n.tr("Merge messages into existing conversations and add new ones.", table: .backup)
        case .replaceAll:
            return L10n.tr("Clear all local data and replace with backup contents.", table: .backup)
        }
    }

    var isDefault: Bool { self == .importNewOnly }
}


struct ImportResult {
    var newConversations = 0
    var skippedConversations = 0
    var mergedConversations = 0
    var newProviders = 0
    var skippedProviders = 0
    var newSkills = 0
    var mergedSkills = 0
    var skippedSkills = 0
    var skillsRequiringKnowledgeReupload = 0
    var restoredKeys = 0
    var restoredImages = 0
    var skippedImages = 0
    var restoredPreferences = false
    var restoredLastUsedModel = false
    /// Number of memory items changed (used after import to dual-write the legacy fields).
    var memoryItemsChanged = 0

    var hasChanges: Bool {
        newConversations > 0 ||
        mergedConversations > 0 ||
        newProviders > 0 ||
        newSkills > 0 ||
        mergedSkills > 0 ||
        restoredKeys > 0 ||
        restoredPreferences ||
        restoredLastUsedModel ||
        memoryItemsChanged > 0
    }
}


struct ImportPreview {
    let backupCreatedAt: String
    let backupPlatform: String
    let backupAppVersion: String
    let containsKeys: Bool

    let totalConversations: Int
    let existingConversations: Int
    let totalProviders: Int
    let existingProviders: Int
    let totalMessages: Int
    let totalImages: Int
}


enum BackupError: LocalizedError {
    case unrecognizedFormat
    case jsonParseFailed
    case versionTooNew(Int)
    case checksumMismatch
    case attachmentChecksumMismatch(String)
    case encryptionFailed
    case decryptionFailed
    case invalidEncryptedData
    case keyDerivationFailed
    case passwordTooShort
    case passwordMismatch
    case zipCreationFailed
    case zipExtractionFailed
    case resourceLimitExceeded
    case noDataToExport
    case sessionChangedDuringImport

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return L10n.tr("The backup file format is not recognized.", table: .backup)
        case .jsonParseFailed:
            return L10n.tr("The backup file is corrupted or in an unsupported format.", table: .backup)
        case .versionTooNew(let v):
            return String(format: L10n.tr("This backup requires a newer version of Oriveo (format version %d).", table: .backup), v)
        case .checksumMismatch:
            return L10n.tr("The backup file may have been modified or corrupted.", table: .backup)
        case .attachmentChecksumMismatch(let name):
            return String(format: L10n.tr("Attachment '%@' may be corrupted.", table: .backup), name)
        case .encryptionFailed:
            return L10n.tr("Failed to encrypt API keys.", table: .backup)
        case .decryptionFailed:
            return L10n.tr("Incorrect password or corrupted encrypted data.", table: .backup)
        case .invalidEncryptedData:
            return L10n.tr("The encrypted data is invalid.", table: .backup)
        case .keyDerivationFailed:
            return L10n.tr("Failed to derive encryption key.", table: .backup)
        case .passwordTooShort:
            return L10n.tr("Password must be at least 8 characters.", table: .backup)
        case .passwordMismatch:
            return L10n.tr("Passwords do not match.", table: .backup)
        case .zipCreationFailed:
            return L10n.tr("Failed to create backup archive.", table: .backup)
        case .zipExtractionFailed:
            return L10n.tr("Failed to extract backup archive.", table: .backup)
        case .resourceLimitExceeded:
            return L10n.tr("File too large", table: .chat)
        case .noDataToExport:
            return L10n.tr("No data to export.", table: .backup)
        case .sessionChangedDuringImport:
            return L10n.tr("The active session changed while importing. Please try again.")
        }
    }
}


nonisolated enum CanonicalJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func checksum(of data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return "sha256:" + hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
