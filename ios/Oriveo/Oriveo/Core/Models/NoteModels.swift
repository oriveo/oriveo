import Foundation


enum NoteTitleSource: String, Codable, Sendable {
    case placeholder
    case manual
}

enum NoteCaptureKind: String, Codable, Sendable {
    case fullAnswer
    case selection
    case userMessage
    case blank

    nonisolated static func decoded(_ raw: String?) -> NoteCaptureKind {
        guard let raw, let value = NoteCaptureKind(rawValue: raw) else { return .blank }
        return value
    }
}

enum ProvenanceKind: String, Codable, Sendable {
    case origin
    case crosscheck
    case digest
    case transform
}

struct ProvenanceEntry: Identifiable, Hashable, Codable, Sendable {
    var id: String { "\(kind.rawValue)-\(at.timeIntervalSince1970)-\(modelID ?? "")" }
    var kind: ProvenanceKind
    var modelID: String?
    var modelName: String?
    var providerKind: ProviderKind?
    var providerName: String?
    var conversationId: UUID?
    var messageId: UUID?
    var at: Date
}

struct Note: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
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

    nonisolated var hasSource: Bool {
        captureKind != .blank && (sourceModelName != nil || sourceProviderName != nil || sourcePrompt != nil)
    }

    nonisolated var showsBadge: Bool {
        captureKind != .blank && (sourceProviderKind != nil || sourceModelName != nil)
    }

    /// A cross-check needs the original question, the model that answered it and a live note to
    /// hang the second opinion off, so all three are required before the action is offered.
    nonisolated var canCrosscheck: Bool {
        !isTrashed && captureKind != .blank
            && (sourcePrompt?.isEmpty == false)
            && sourceModelName != nil
            && sourceProviderKind != nil
    }

    nonisolated var isTrashed: Bool { deletedAt != nil }
}

struct NoteFolder: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var sortOrder: Int
    var colorTag: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    nonisolated var isTrashed: Bool { deletedAt != nil }
}

extension Note {
    static let folderSortStep = 1000
    static let folderNameMaxLength = 30
}

extension NoteSummary {
    nonisolated init(_ note: Note) {
        self.init(
            id: note.id,
            title: note.title,
            titleSource: note.titleSource,
            body: String(note.body.prefix(NoteSummary.bodyProjectionCharacters)),
            tags: note.tags,
            noteFolderID: note.noteFolderID,
            sourceConversationId: note.sourceConversationId,
            sourceMessageId: note.sourceMessageId,
            sourceModelName: note.sourceModelName,
            sourceProviderKind: note.sourceProviderKind,
            sourceProviderName: note.sourceProviderName,
            captureKind: note.captureKind,
            isPinned: note.isPinned,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            deletedAt: note.deletedAt
        )
    }
}

struct NoteSourceJump: Equatable {
    var conversationID: UUID
    var messageID: UUID?
    var fromNoteID: UUID
}

struct NoteDraft {
    var title: String?
    var body: String
    var bodySnapshot: String?
    var userNote: String?
    var tags: [String] = []
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
}
