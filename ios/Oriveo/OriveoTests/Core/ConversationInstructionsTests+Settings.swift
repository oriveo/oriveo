import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

// Conversation settings sheet: saving, pending instructions for a draft, inherited source, and copy.
// Assertions come from the production path: ConversationSettingsLogic -> AppState / ConversationManager, and the Chat table compiled into the app.

extension ConversationInstructionsTests {
    @MainActor
    private func withState(_ body: (AppState) throws -> Void) rethrows {
        let uid = "instructions-settings-\(UUID().uuidString)"
        let state = AppState(seedDemoData: false, sessionUID: uid)
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        try body(state)
    }

    @Test("settings_draft_instructions_written_on_create")
    @MainActor
    func settingsDraftInstructionsWrittenOnCreate() throws {
        try withState { state in
            // Saving in the draft state (no conversation id) only writes the in-memory pending instructions, normalized.
            #expect(ConversationSettingsLogic.save(" \n\t", original: "", conversationID: nil, appState: state) == false)
            #expect(ConversationSettingsLogic.save("Reply in Arabic.\n", original: "", conversationID: nil, appState: state))
            #expect(state.pendingDraftInstructions == "Reply in Arabic.\n")
            #expect(state.conversations.isEmpty)

            // On the first send the conversation is created: the pending instructions are written into the object before persisting, then cleared.
            let provider = TestFactories.makeProvider()
            let created = state.createConversationForFirstSend(provider: provider, modelID: "gpt-4o")
            #expect(created.instructions == "Reply in Arabic.\n")
            #expect(state.conversation(for: created.id)?.instructions == "Reply in Arabic.\n")
            #expect(state.pendingDraftInstructions == "")

            // A new conversation clears the pending instructions.
            state.pendingDraftInstructions = "stale"
            state.startNewChat()
            #expect(state.pendingDraftInstructions == "")
        }
    }

    @Test("settings_save_normalizes_on_close")
    @MainActor
    func settingsSaveNormalizesOnClose() throws {
        try withState { state in
            let conversation = TestFactories.makeConversation(hasCustomTitle: true, messages: [TestFactories.makeMessage()])
            state.replaceConversationProjection([conversation])

            #expect(ConversationSettingsLogic.save("  Use metric units.\n", original: "", conversationID: conversation.id, appState: state))
            #expect(state.conversation(for: conversation.id)?.instructions == "  Use metric units.\n")
            // An unchanged value is not written.
            #expect(!ConversationSettingsLogic.save("  Use metric units.\n", original: "  Use metric units.\n", conversationID: conversation.id, appState: state))
            // All whitespace -> "".
            #expect(ConversationSettingsLogic.save(" \n", original: "  Use metric units.\n", conversationID: conversation.id, appState: state))
            #expect(state.conversation(for: conversation.id)?.instructions == "")
            // Overlong text is truncated to the first 8000 code points.
            let long = String(repeating: "a", count: ConversationInstructions.maxCodePoints + 3)
            #expect(ConversationSettingsLogic.save(long, original: "", conversationID: conversation.id, appState: state))
            #expect(state.conversation(for: conversation.id)?.instructions.unicodeScalars.count
                == ConversationInstructions.maxCodePoints)
        }
    }

    @Test("settings_carry_over_source_is_latest_other_conversation")
    func settingsCarryOverSourceIsLatestOtherConversation() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var current = TestFactories.makeConversation(updatedAt: base.addingTimeInterval(500))
        current.instructions = ""
        var older = TestFactories.makeConversation(updatedAt: base)
        older.instructions = "Older rule."
        var latest = TestFactories.makeConversation(updatedAt: base.addingTimeInterval(100))
        latest.instructions = "Latest rule."
        var deleted = TestFactories.makeConversation(updatedAt: base.addingTimeInterval(200))
        deleted.instructions = "Deleted rule."
        deleted.deletedAt = base.addingTimeInterval(300)
        let all = [older, current, deleted, latest]

        #expect(ConversationSettingsLogic.carryOverInstructions(
            in: all, currentID: current.id, currentText: "") == "Latest rule.")
        // The draft state (no current conversation) also takes the latest one.
        #expect(ConversationSettingsLogic.carryOverInstructions(
            in: [older, deleted, latest], currentID: nil, currentText: "") == "Latest rule.")

        // The latest instruction is empty -> not shown (older ones are not searched).
        var emptyLatest = latest
        emptyLatest.instructions = ""
        #expect(ConversationSettingsLogic.carryOverInstructions(
            in: [older, current, deleted, emptyLatest], currentID: current.id, currentText: "") == nil)
    }

    @Test("settings_carry_over_hidden_when_current_non_empty")
    func settingsCarryOverHiddenWhenCurrentNonEmpty() {
        let current = TestFactories.makeConversation()
        var other = TestFactories.makeConversation(updatedAt: Date().addingTimeInterval(-60))
        other.instructions = "Other rule."
        #expect(ConversationSettingsLogic.carryOverInstructions(
            in: [current, other], currentID: current.id, currentText: "Mine.") == nil)
        #expect(ConversationSettingsLogic.carryOverInstructions(
            in: [current, other], currentID: current.id, currentText: " \n") == "Other rule.")
    }

    @Test("settings_carry_over_hidden_when_editor_non_empty")
    func settingsCarryOverHiddenWhenEditorNonEmpty() {
        // The current conversation's saved instructions are empty, so visibility depends only on the editor content: hidden as soon as the user types, shown again after clearing back to blank (normalized to "").
        let current = TestFactories.makeConversation()
        #expect(current.instructions == "")
        var other = TestFactories.makeConversation(updatedAt: Date().addingTimeInterval(-60))
        other.instructions = "Other rule."
        #expect(ConversationSettingsLogic.carryOverInstructions(
            in: [current, other], currentID: current.id, currentText: "") == "Other rule.")
        #expect(ConversationSettingsLogic.carryOverInstructions(
            in: [current, other], currentID: current.id, currentText: "R") == nil)
        #expect(ConversationSettingsLogic.carryOverInstructions(
            in: [current, other], currentID: current.id, currentText: " \t\n") == "Other rule.")
    }

    @Test("settings_close_without_edit_keeps_remote_change")
    @MainActor
    func settingsCloseWithoutEditKeepsRemoteChange() throws {
        try withState { state in
            var conversation = TestFactories.makeConversation(hasCustomTitle: true, messages: [TestFactories.makeMessage()])
            conversation.instructions = "Old rule."
            state.replaceConversationProjection([conversation])
            // A snapshot of "Old rule." is taken on open; while it is open the remote value changes to "Remote rule." (synced into the projection).
            let opened = ConversationSettingsLogic.currentInstructions(conversationID: conversation.id, appState: state)
            #expect(opened == "Old rule.")
            var remote = try #require(state.conversation(for: conversation.id))
            remote.instructions = "Remote rule."
            state.upsertConversationProjection(remote)

            // The user closes without touching the editor: nothing is written and the remote value is kept.
            #expect(!ConversationSettingsLogic.save(opened, original: opened, conversationID: conversation.id, appState: state))
            #expect(state.conversation(for: conversation.id)?.instructions == "Remote rule.")
            // A difference only in normalization (trailing blank lines) also counts as untouched.
            #expect(!ConversationSettingsLogic.save(" \n", original: "", conversationID: nil, appState: state))

            // The user edited it: write it.
            #expect(ConversationSettingsLogic.save("Mine.", original: opened, conversationID: conversation.id, appState: state))
            #expect(state.conversation(for: conversation.id)?.instructions == "Mine.")
        }
    }

    @Test("strings_present_in_16_locales")
    func stringsPresentIn16Locales() {
        let keys = [
            "conversation_settings_title",
            "conversation_settings_instructions_header",
            "conversation_settings_instructions_placeholder",
            "conversation_settings_instructions_footer",
            "conversation_settings_carry_over",
            "conversation_settings_usage",
            "conversation_instructions_badge",
            "conversation_instructions_badge_a11y",
            "directive_suggestion_prompt",
            "directive_suggestion_accept",
            "directive_suggestion_ignore",
            "directive_suggestion_added",
            "memory_suggestion_prompt",
            "memory_suggestion_save",
            "memory_suggestion_edit",
            "memory_suggestion_ignore",
            "memory_suggestion_saved",
            "memory_suggestion_failed",
            "memory_suggestion_memory_off",
            "memory_inbox_title",
            "memory_inbox_empty",
            "memory_inbox_footnote",
            "memory_inbox_auto_suggest",
            "memory_inbox_auto_suggest_footnote",
            "memory_extraction_title_draft",
            "memory_extraction_title_organize",
            "memory_extraction_model",
            "memory_extraction_scope_draft",
            "memory_extraction_scope_organize",
            "memory_extraction_no_fallback",
            "memory_extraction_send",
        ]
        let locales = [
            "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko",
            "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
        ]
        for locale in locales {
            guard let path = Bundle.main.path(forResource: locale, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                Issue.record("App bundle is missing \(locale).lproj")
                continue
            }
            for key in keys {
                let resolved = bundle.localizedString(forKey: key, value: key, table: "Chat")
                #expect(resolved != key && !resolved.isEmpty, "\(locale) · \(key) did not resolve")
            }
        }
        let zh = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))
        #expect(zh?.localizedString(forKey: "conversation_settings_title", value: nil, table: "Chat") == "\u{5BF9}\u{8BDD}\u{8BBE}\u{7F6E}")
    }
}
