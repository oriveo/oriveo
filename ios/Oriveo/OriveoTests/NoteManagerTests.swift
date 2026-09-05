import Foundation
import Testing
@testable import Oriveo

@MainActor
private func makeNotesAppState() -> AppState {
    AppState(seedDemoData: false, sessionUID: "note-manager-\(UUID().uuidString)")
}

@Suite("NoteManager", .serialized)
struct NoteManagerTests {
    enum TestError: Error {
        case localDeleteFailed
    }

    @Test("Direct Mirror Mutations Bump Generation")
    func directMirrorMutationsBumpGeneration() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Oriveo/Core/State/NoteManager.swift"),
            encoding: .utf8
        )

        func body(of functionName: String) throws -> String {
            guard let range = source.range(of: "func \(functionName)") else {
                Issue.record("missing function \(functionName)")
                return ""
            }
            let suffix = source[range.lowerBound...]
            guard let start = suffix.firstIndex(of: "{") else {
                Issue.record("missing function body \(functionName)")
                return ""
            }
            var depth = 0
            var end = start
            var index = start
            while index < source.endIndex {
                let char = source[index]
                if char == "{" { depth += 1 }
                if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        end = index
                        break
                    }
                }
                index = source.index(after: index)
            }
            return String(source[start...end])
        }

        for functionName in [
            "permanentlyDeleteNote",
            "emptyTrash",
            "deleteNoteFolder",
            "reorderNoteFolders",
        ] {
            #expect(try body(of: functionName).contains("mirrorGeneration &+="), "\(functionName) must bump mirrorGeneration")
        }
        #expect(try body(of: "mutateFolder").contains("mirrorGeneration &+="), "mutateFolder must bump mirrorGeneration")
    }

    @Test("Placeholder Title Comes From The First Body Line, titleSource = placeholder")
    @MainActor
    func placeholderFromBody() {
        let state = makeNotesAppState()
        let note = state.noteManager.createNote(from: NoteDraft(body: "First line\nsecond", captureKind: .blank))
        #expect(note?.titleSource == .placeholder)
        #expect(note?.title == "First line")
    }

    @Test("Providing A Title Sets titleSource = manual")
    @MainActor
    func manualTitle() {
        let state = makeNotesAppState()
        let note = state.noteManager.createNote(from: NoteDraft(title: "My Title", body: "body", captureKind: .blank))
        #expect(note?.titleSource == .manual)
        #expect(note?.title == "My Title")
    }

    @Test("Editing The Title Locks manual")
    @MainActor
    func updateTitleLocksManual() {
        let state = makeNotesAppState()
        guard let note = state.noteManager.createNote(from: NoteDraft(body: "orig body", captureKind: .blank)) else {
            Issue.record("create failed"); return
        }
        #expect(note.titleSource == .placeholder)
        let updated = state.noteManager.updateTitle(id: note.id, title: "Custom")
        #expect(updated?.titleSource == .manual)
        #expect(updated?.title == "Custom")
    }

    @Test("Clearing A Manual Title Restores placeholder And Follows The First Body Line Again")
    @MainActor
    func blankTitleResetsToPlaceholder() {
        let state = makeNotesAppState()
        guard let note = state.noteManager.createNote(from: NoteDraft(title: "Custom", body: "Original first line\nbody", captureKind: .blank)) else {
            Issue.record("create failed"); return
        }

        let reset = state.noteManager.updateTitle(id: note.id, title: "   ")
        #expect(reset?.titleSource == .placeholder)
        #expect(reset?.title == "Original first line")

        let updatedBody = state.noteManager.updateBody(id: note.id, body: "New first line\nbody")
        #expect(updatedBody?.titleSource == .placeholder)
        #expect(updatedBody?.title == "New first line")
    }

    @Test("Blurring An Unchanged Placeholder Title Does Not Save, Avoiding Accidental manual Lock")
    @MainActor
    func unchangedPlaceholderTitleDoesNotSave() {
        #expect(NoteDetailTitleEditPolicy.shouldSave(
            draft: "Original first line",
            currentTitle: "Original first line",
            currentSource: .placeholder
        ) == false)
        #expect(NoteDetailTitleEditPolicy.shouldSave(
            draft: "Custom",
            currentTitle: "Original first line",
            currentSource: .placeholder
        ) == true)
        #expect(NoteDetailTitleEditPolicy.shouldSave(
            draft: "   ",
            currentTitle: "Manual",
            currentSource: .manual
        ) == true)
        #expect(NoteDetailTitleEditPolicy.shouldSave(
            draft: "   ",
            currentTitle: "Original first line",
            currentSource: .placeholder
        ) == false)
    }

    @Test("placeholder Title Follows The Body; manual Title Does Not")
    @MainActor
    func bodyUpdateTitleFollow() {
        let state = makeNotesAppState()
        guard let n1 = state.noteManager.createNote(from: NoteDraft(body: "line one", captureKind: .blank)) else {
            Issue.record("create failed"); return
        }
        let afterBody = state.noteManager.updateBody(id: n1.id, body: "brand new first line\nrest")
        #expect(afterBody?.title == "brand new first line")

        guard let n2 = state.noteManager.createNote(from: NoteDraft(title: "Fixed", body: "x", captureKind: .blank)) else {
            Issue.record("create failed"); return
        }
        let afterBody2 = state.noteManager.updateBody(id: n2.id, body: "totally different")
        #expect(afterBody2?.title == "Fixed")
    }

    @Test("Selection Replaces The Current Note: Keeps Organize Fields, Updates Body/Source/Snapshot, Clears Old Provenance")
    @MainActor
    func replaceNoteWithSelectionDraft() {
        let state = makeNotesAppState()
        let folderID = UUID()
        let originalConversationID = UUID()
        let originalMessageID = UUID()
        let replacementConversationID = UUID()
        let replacementMessageID = UUID()
        let provenance = [
            ProvenanceEntry(kind: .origin, modelID: "gpt-5", modelName: "GPT-5",
                            providerKind: .openAI, providerName: "OpenAI",
                            conversationId: originalConversationID, messageId: originalMessageID,
                            at: Date(timeIntervalSince1970: 1_700_000_000)),
            ProvenanceEntry(kind: .crosscheck, modelID: "claude", modelName: "Claude",
                            providerKind: .anthropic, providerName: "Anthropic",
                            conversationId: nil, messageId: nil,
                            at: Date(timeIntervalSince1970: 1_700_000_010))
        ]
        var originalDraft = NoteDraft(
            title: "Manual title",
            body: "Old body",
            tags: ["keep"],
            noteFolderID: folderID,
            sourceConversationId: originalConversationID,
            sourceMessageId: originalMessageID,
            sourceModelID: "gpt-5",
            sourceModelName: "GPT-5",
            sourceProviderKind: .openAI,
            sourceProviderName: "OpenAI",
            sourcePrompt: "Old prompt",
            captureKind: .fullAnswer,
            provenance: provenance
        )
        originalDraft.bodySnapshot = "Old full answer"
        guard let note = state.noteManager.createNote(from: originalDraft) else {
            Issue.record("create failed"); return
        }
        _ = state.noteManager.setPinned(id: note.id, isPinned: true)

        var replacement = NoteDraft(
            body: "Selected replacement",
            tags: ["should-not-copy"],
            noteFolderID: UUID(),
            sourceConversationId: replacementConversationID,
            sourceMessageId: replacementMessageID,
            sourceModelID: "claude-3-5",
            sourceModelName: "Claude 3.5",
            sourceProviderKind: .anthropic,
            sourceProviderName: "Anthropic",
            sourcePrompt: "New prompt",
            captureKind: .selection,
            provenance: [
                ProvenanceEntry(kind: .origin, modelID: "unused", modelName: "Unused",
                                providerKind: .openAI, providerName: "Unused",
                                conversationId: replacementConversationID, messageId: replacementMessageID,
                                at: Date())
            ]
        )
        replacement.bodySnapshot = "Full replacement answer"

        guard let replaced = state.noteManager.replaceNote(id: note.id, with: replacement) else {
            Issue.record("replace failed"); return
        }

        #expect(replaced.id == note.id)
        #expect(abs(replaced.createdAt.timeIntervalSince(note.createdAt)) < 0.001)
        #expect(replaced.title == "Manual title")
        #expect(replaced.titleSource == .manual)
        #expect(replaced.body == "Selected replacement")
        #expect(replaced.bodySnapshot == "Full replacement answer")
        #expect(replaced.tags == ["keep"])
        #expect(replaced.noteFolderID == folderID)
        #expect(replaced.isPinned == true)
        #expect(replaced.captureKind == .selection)
        #expect(replaced.sourceConversationId == replacementConversationID)
        #expect(replaced.sourceMessageId == replacementMessageID)
        #expect(replaced.sourceModelID == "claude-3-5")
        #expect(replaced.sourceModelName == "Claude 3.5")
        #expect(replaced.sourceProviderKind == .anthropic)
        #expect(replaced.sourceProviderName == "Anthropic")
        #expect(replaced.sourcePrompt == "New prompt")
        #expect(replaced.provenance == nil)
    }

    @Test("Free (No syncAdapter) createNote Writes Locally Without Crashing")
    @MainActor
    func localizationFallbackNotPersisted() {
        let state = makeNotesAppState()
        let note = state.noteManager.createNote(from: NoteDraft(body: "", captureKind: .blank))
        #expect(note?.title == "")
        #expect(note?.titleSource == .placeholder)
    }

    @Test("Blank Manually Created Notes Are Discarded On Exit Without Hitting The Trash")
    @MainActor
    func discardEmptyBlankNoteDeletesWithoutTrash() {
        let state = makeNotesAppState()
        guard let note = state.noteManager.createBlankNote() else {
            Issue.record("create failed"); return
        }

        let discarded = state.noteManager.discardEmptyBlankNoteIfNeeded(id: note.id)

        #expect(discarded == true)
        #expect(state.noteManager.note(id: note.id) == nil)
        #expect(!state.noteSummaries.contains { $0.id == note.id })
        #expect(!state.trashedNoteSummaries.contains { $0.id == note.id })
    }

    @Test("A Blank Note With Content Is Not Auto-Discarded")
    @MainActor
    func discardEmptyBlankNoteKeepsUserContent() {
        let state = makeNotesAppState()
        guard let note = state.noteManager.createNote(from: NoteDraft(body: "kept", captureKind: .blank)) else {
            Issue.record("create failed"); return
        }

        let discarded = state.noteManager.discardEmptyBlankNoteIfNeeded(id: note.id)

        #expect(discarded == false)
        #expect(state.noteManager.note(id: note.id) != nil)
        #expect(state.noteSummaries.contains { $0.id == note.id })
    }

    @Test("Generated Note IDs Are Uppercased In Persistence")
    @MainActor
    func idUppercase() {
        let state = makeNotesAppState()
        guard let note = state.noteManager.createNote(from: NoteDraft(body: "x", captureKind: .blank)) else {
            Issue.record("create failed"); return
        }
        #expect(note.id.uuidString == note.id.uuidString.uppercased())
    }

    @Test("Delete Mirrors Into Trash And Restore Mirrors Back To Active")
    @MainActor
    func deleteRestoreMirror() {
        let state = makeNotesAppState()
        guard let note = state.noteManager.createNote(from: NoteDraft(body: "trash me", captureKind: .blank)) else {
            Issue.record("create failed"); return
        }
        state.noteManager.deleteNote(id: note.id)
        #expect(!state.noteSummaries.contains { $0.id == note.id })
        #expect(state.trashedNoteSummaries.contains { $0.id == note.id })

        state.noteManager.restoreNote(id: note.id)
        #expect(state.noteSummaries.contains { $0.id == note.id })
        #expect(!state.trashedNoteSummaries.contains { $0.id == note.id })
    }

    @Test("Folder Create Plus Drag Reorder Writes sortOrder")
    @MainActor
    func folderCreateReorder() {
        let state = makeNotesAppState()
        let a = state.noteManager.createNoteFolder(name: "A")
        let b = state.noteManager.createNoteFolder(name: "B")
        #expect(a != nil && b != nil)
        #expect(state.noteFolders.count == 2)
        let reversed = [b!, a!]
        state.noteManager.reorderNoteFolders(reversed)
        #expect(state.noteFolders.map(\.name) == ["B", "A"])
        #expect(state.noteFolders.first?.sortOrder == 1000)
    }

    @Test("Failed Local Folder-Delete Transaction Keeps The Mirror And Does Not Falsely Report Cloud Deletion")
    @MainActor
    func deleteFolderLocalFailureKeepsMirror() {
        let state = makeNotesAppState()
        let folder = NoteTestFactories.makeFolder(name: "Keep")
        let bridge = NoteRuntimeBridge(softDeleteNoteFolderHandler: { _, _, _, _ in
            throw TestError.localDeleteFailed
        })
        state.noteManager = NoteManager(bridge: bridge)
        state.noteManager.bind(to: state)
        state.noteFolders = [folder]

        state.noteManager.deleteNoteFolder(id: folder.id)

        #expect(state.noteFolders.map(\.id) == [folder.id])
    }

    @Test(
        "Import: Notes Referencing Tombstoned/Dangling Folders Get noteFolderID Cleared (All Three Modes)",
        arguments: [ImportMode.importNewOnly, ImportMode.merge, ImportMode.replaceAll]
    )
    @MainActor
    func importNullsDanglingNoteFolder(mode: ImportMode) {
        let state = makeNotesAppState()
        let tombstoneFolder = NoteTestFactories.makeFolder(
            name: "Deleted",
            deletedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let danglingFolderID = UUID()
        let noteInTombstone = NoteTestFactories.makeNote(title: "in tombstone", noteFolderID: tombstoneFolder.id)
        let noteDangling = NoteTestFactories.makeNote(title: "dangling", noteFolderID: danglingFolderID)

        state.noteManager.importNotes(
            [noteInTombstone, noteDangling],
            folders: [tombstoneFolder],
            mode: mode
        )

        #expect(!state.noteFolders.contains { $0.id == tombstoneFolder.id })
        #expect(state.noteManager.note(id: noteInTombstone.id)?.noteFolderID == nil)
        #expect(state.noteManager.note(id: noteDangling.id)?.noteFolderID == nil)
    }

    @Test(
        "Import: Notes Referencing Active Folders Keep noteFolderID (All Three Modes, No False Clears)",
        arguments: [ImportMode.importNewOnly, ImportMode.merge, ImportMode.replaceAll]
    )
    @MainActor
    func importKeepsValidNoteFolder(mode: ImportMode) {
        let state = makeNotesAppState()
        let activeFolder = NoteTestFactories.makeFolder(name: "Keep")
        let note = NoteTestFactories.makeNote(title: "valid", noteFolderID: activeFolder.id)

        state.noteManager.importNotes([note], folders: [activeFolder], mode: mode)

        #expect(state.noteFolders.contains { $0.id == activeFolder.id })
        #expect(state.noteManager.note(id: note.id)?.noteFolderID == activeFolder.id)
    }

    @Test("merge: When A Backup Tombstones The Active Folder A Local Note Points To, noteFolderID Cascades To Nil (Matches Android/Web)")
    @MainActor
    func mergeCascadesClearsLocalDanglingReference() {
        let state = makeNotesAppState()
        let folderID = UUID()
        let activeFolder = NoteTestFactories.makeFolder(
            id: folderID,
            name: "F",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let noteA = NoteTestFactories.makeNote(
            title: "A",
            noteFolderID: folderID,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        state.noteManager.importNotes([noteA], folders: [activeFolder], mode: .replaceAll)
        #expect(state.noteManager.note(id: noteA.id)?.noteFolderID == folderID)

        let tombstoneFolder = NoteTestFactories.makeFolder(
            id: folderID,
            name: "F",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            deletedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        state.noteManager.importNotes([], folders: [tombstoneFolder], mode: .merge)

        #expect(!state.noteFolders.contains { $0.id == folderID })
        #expect(state.noteManager.note(id: noteA.id)?.noteFolderID == nil)
    }
}
