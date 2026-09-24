import Foundation
import Testing
@testable import Oriveo

/// Deleting a single conversation always asks first. The Home list showed "Delete this conversation?" (with the note
/// reference count), while the same long-press menu inside a folder deleted right away with no confirmation. Both
/// must share one confirmation with the same wording.
@Suite("Conversation delete confirmation")
struct ConversationDeleteConfirmationTests {
    @Test("Long-press Delete on a conversation inside a folder goes through the same confirmation as Home")
    func folderRowDeleteGoesThroughConfirmation() throws {
        let folderRow = try ProductionSource.read("Features/Home/FolderRow.swift")
        let menu = try #require(
            folderRow.range(of: "private func conversationContextMenu(").map { String(folderRow[$0.lowerBound...]) },
            "conversation context menu not found in FolderRow"
        )
        #expect(
            !menu.contains("appState.deleteConversation("),
            "long-press Delete inside a folder deletes the conversation without asking"
        )
        #expect(folderRow.contains(".conversationDeleteConfirmation("), "FolderRow does not attach the shared delete confirmation")
    }

    @Test("Home and folders share one confirmation whose wording is defined in one place")
    func homeAndFolderShareOneConfirmation() throws {
        let home = try ProductionSource.read("Features/Home/HomeView.swift")
        #expect(home.contains(".conversationDeleteConfirmation("), "Home does not use the shared delete confirmation")
        #expect(
            !home.contains("L10n.tr(\"Delete this conversation?\")"),
            "Home still defines its own delete confirmation; the two would drift apart"
        )

        let shared = try ProductionSource.read("Features/Home/ConversationDeleteConfirmation.swift")
        #expect(shared.contains("L10n.tr(\"Delete this conversation?\")"))
        #expect(shared.contains("This conversation is referenced by %d notes."), "the note reference hint is missing")
        #expect(shared.contains("appState.deleteConversation(id: id)"))
    }
}
