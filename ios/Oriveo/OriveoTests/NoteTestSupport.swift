import Foundation
import GRDB
@testable import Oriveo

struct NoteStoreHarness {
    let rootURL: URL
    let dbPool: DatabasePool
    let store: NoteStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oriveo-note-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        dbPool = try DatabasePool(
            path: rootURL.appendingPathComponent(DatabaseSchema.fileName).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        try DatabaseSchema.makeMigrator(
            attachmentFileStore: AttachmentFileStore(rootDirectory: rootURL)
        ).migrate(dbPool)
        store = NoteStore(dbPool: dbPool)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

enum NoteTestFactories {
    static func makeNote(
        id: UUID = UUID(),
        title: String = "Sample note",
        titleSource: NoteTitleSource = .manual,
        body: String = "Body text",
        bodySnapshot: String? = nil,
        userNote: String? = nil,
        tags: [String] = [],
        noteFolderID: UUID? = nil,
        sourceConversationId: UUID? = nil,
        sourceMessageId: UUID? = nil,
        sourceModelID: String? = nil,
        sourceModelName: String? = nil,
        sourceProviderKind: ProviderKind? = nil,
        sourceProviderName: String? = nil,
        sourcePrompt: String? = nil,
        captureKind: NoteCaptureKind = .blank,
        provenance: [ProvenanceEntry]? = nil,
        isPinned: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        deletedAt: Date? = nil
    ) -> Note {
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

    static func makeFolder(
        id: UUID = UUID(),
        name: String = "Folder",
        sortOrder: Int = 1000,
        colorTag: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        deletedAt: Date? = nil
    ) -> NoteFolder {
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
