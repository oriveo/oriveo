import Foundation
import Testing
@testable import Oriveo

@Suite("NoteBackup", .serialized)
struct NoteBackupTests {

    private func codec() -> (JSONEncoder, JSONDecoder) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (enc, dec)
    }

    @Test("Backup Note Roundtrip")
    func backupNoteRoundtrip() {
        let note = NoteTestFactories.makeNote(
            title: "T", titleSource: .manual, body: "B", bodySnapshot: "Snap",
            userNote: "remark", tags: ["a", "b"], noteFolderID: UUID(),
            sourceModelName: "GPT-4", sourceProviderKind: .openAI, sourcePrompt: "Q",
            captureKind: .fullAnswer,
            provenance: [ProvenanceEntry(kind: .origin, modelID: "m", modelName: "M",
                                         providerKind: .openAI, providerName: "OpenAI",
                                         conversationId: nil, messageId: nil,
                                         at: Date(timeIntervalSince1970: 1_700_000_000))],
            isPinned: true,
            deletedAt: Date(timeIntervalSince1970: 1_700_000_500))
        let restored = BackupNote(from: note).toNote()
        #expect(restored.id == note.id)
        #expect(restored.title == note.title)
        #expect(restored.bodySnapshot == note.bodySnapshot)
        #expect(restored.userNote == note.userNote)
        #expect(restored.tags == note.tags)
        #expect(restored.captureKind == note.captureKind)
        #expect(restored.provenance?.count == 1)
        #expect(restored.isPinned == true)
        #expect(restored.deletedAt == note.deletedAt)
    }

    @Test("Backup Folder Roundtrip")
    func backupFolderRoundtrip() {
        let folder = NoteTestFactories.makeFolder(name: "F", sortOrder: 3000, colorTag: "blue",
                                                  deletedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let restored = BackupNoteFolder(from: folder).toNoteFolder()
        #expect(restored.name == "F")
        #expect(restored.sortOrder == 3000)
        #expect(restored.colorTag == "blue")
        #expect(restored.deletedAt != nil)
    }

    @Test("Backup Data Roundtrip")
    func backupDataRoundtrip() throws {
        let (enc, dec) = codec()
        let data = BackupData(
            providers: [],
            conversations: [],
            preferences: nil,
            lastUsedModelRef: nil,
            notes: [BackupNote(from: NoteTestFactories.makeNote(title: "kept"))],
            noteFolders: [BackupNoteFolder(from: NoteTestFactories.makeFolder(name: "kept-folder"))]
        )
        let encoded = try enc.encode(data)
        let decoded = try dec.decode(BackupData.self, from: encoded)
        #expect(decoded.notes?.count == 1)
        #expect(decoded.notes?.first?.title == "kept")
        #expect(decoded.noteFolders?.first?.name == "kept-folder")
    }

    @Test("Backward Compat No Notes")
    func backwardCompatNoNotes() throws {
        let (_, dec) = codec()
        let legacyJSON = """
        {"providers":[],"conversations":[]}
        """
        let decoded = try dec.decode(BackupData.self, from: Data(legacyJSON.utf8))
        #expect(decoded.notes == nil)
        #expect(decoded.noteFolders == nil)
        #expect(decoded.conversations.isEmpty)
    }
}
