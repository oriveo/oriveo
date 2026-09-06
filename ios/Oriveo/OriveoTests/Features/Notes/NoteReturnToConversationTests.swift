import Foundation
import Testing
@testable import Oriveo

@Suite("Note Return To Conversation", .serialized)
struct NoteReturnToConversationTests {

    @Test("NoteDetail source card exposes one primary action plus independent cross-check")
    func sourceCardActionsUseSinglePrimaryReturnAction() {
        let conversationID = UUID()
        let sourceNote = NoteTestFactories.makeNote(
            sourceConversationId: conversationID,
            sourceMessageId: UUID(),
            sourceModelName: "GPT-5",
            sourceProviderKind: .openAI,
            sourceProviderName: "OpenAI",
            sourcePrompt: "Explain notes",
            captureKind: .fullAnswer
        )

        let actions = NoteDetailSourceActions.make(note: sourceNote)

        #expect(actions.primary?.titleKey == "Back to conversation")
        #expect(actions.primary?.kind == .backToConversation)
        #expect(actions.primary?.isEnabled == true)
        // Cross-check is a separate action, not a variant of "back to conversation".
        #expect(actions.secondary.map(\.kind) == [.crosscheck])
        #expect(actions.secondary.first?.style == .neutral)
    }

    @Test("NoteDetail keeps return action enabled when the source anchor exists")
    func returnActionUsesSourceAnchorInsteadOfLocalConversationGate() {
        let sourceNote = NoteTestFactories.makeNote(
            sourceConversationId: UUID(),
            sourceMessageId: UUID(),
            captureKind: .blank
        )

        let actions = NoteDetailSourceActions.make(note: sourceNote)

        #expect(actions.primary?.kind == .backToConversation)
        #expect(actions.primary?.titleKey == "Back to conversation")
        #expect(actions.primary?.isEnabled == true)
        #expect(actions.secondary.isEmpty)
        #expect(NoteDetailSourceActions.shouldRenderSourceCard(note: sourceNote))
    }

    @Test("ChatView no longer contains continue-ask linkedConversation or update-original-note paths")
    func chatViewRetiresContinueAskWritePaths() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Features/Notes
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // Oriveo
            .appendingPathComponent("Oriveo/Features/Chat/ChatView.swift")
        let source = try String(contentsOf: root, encoding: .utf8)

        #expect(source.contains("pendingContinueAskNoteID") == false)
        #expect(source.contains("continueAskNoteID") == false)
        #expect(source.contains("setLinkedConversation") == false)
        #expect(source.contains("appendSection") == false)
        #expect(source.contains("Update original note") == false)
        #expect(source.contains("Follow-up from chat") == false)
    }

    @Test("ChatMessageList treats sourceMessageId as optional for return-to-conversation")
    func chatMessageListDoesNotRequireMessageAnchorToRestoreReturnBar() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Features/Notes
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // Oriveo
            .appendingPathComponent("Oriveo/Features/Chat/ChatMessageList.swift")
        let source = try String(contentsOf: root, encoding: .utf8)

        #expect(source.contains("jump.conversationID == projection.activeConversationID,\n              let messageID = jump.messageID") == false)
        #expect(source.contains("NoteSourceJumpConsumption.resolve") == true)
        #expect(source.contains("failedAnchorMessageID: windowLoader.failedAnchorMessageID") == true)
    }

    @Test("ChatMessageList consumes return jump when source message is absent")
    func chatMessageListConsumesMissingSourceAnchorAsLatestFallback() {
        let conversationID = UUID()
        let noteID = UUID()
        let missingMessageID = UUID()
        let visibleMessage = TestFactories.makeMessage(text: "latest visible message")
        let jump = NoteSourceJump(
            conversationID: conversationID,
            messageID: missingMessageID,
            fromNoteID: noteID
        )

        let decision = NoteSourceJumpConsumption.resolve(
            jump: jump,
            activeConversationID: conversationID,
            messages: [visibleMessage],
            failedAnchorMessageID: missingMessageID
        )

        #expect(decision.shouldConsume == true)
        #expect(decision.scrollMessageID == nil)

        let waitingDecision = NoteSourceJumpConsumption.resolve(
            jump: jump,
            activeConversationID: conversationID,
            messages: [visibleMessage],
            failedAnchorMessageID: nil
        )
        #expect(waitingDecision.shouldConsume == false)
        #expect(waitingDecision.scrollMessageID == nil)
    }

    @Test("Note domain removes continue-ask entry points instead of leaving dormant UI APIs")
    func noteDomainRetiresContinueAskEntryPoints() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Features/Notes
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // Oriveo
            .appendingPathComponent("Oriveo")
        let appState = try String(
            contentsOf: appRoot.appendingPathComponent("Core/State/AppState.swift"),
            encoding: .utf8
        )
        let noteManager = try String(
            contentsOf: appRoot.appendingPathComponent("Core/State/NoteManager.swift"),
            encoding: .utf8
        )
        let detail = try String(
            contentsOf: appRoot.appendingPathComponent("Features/Notes/NoteDetailView.swift"),
            encoding: .utf8
        )

        #expect(appState.contains("pendingContinueAskNoteID") == false)
        #expect(appState.contains("openChatWithNoteContext") == false)
        #expect(noteManager.contains("setLinkedConversation") == false)
        #expect(noteManager.contains("appendSection") == false)
        #expect(detail.contains("case continueAsking") == false)
        #expect(detail.contains("case jumpToSource") == false)
    }

    @Test("iOS note model hard-removes linkedConversationId and continue-ask composer contract")
    func iosNoteDomainHardRemovesLinkedConversationAndContinueAskContracts() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Features/Notes
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // Oriveo
            .appendingPathComponent("Oriveo")
        let testRoot = appRoot
            .deletingLastPathComponent() // Oriveo
            .appendingPathComponent("OriveoTests")

        let paths = [
            "Core/Models/NoteModels.swift",
            "Core/Models/BackupModels.swift",
            "Core/Database/DatabaseModels.swift",
            "Core/Database/DatabaseSchema.swift",
            "Core/Database/NoteStore.swift",
            "Core/Database/RecordMappers+Notes.swift",
            "Core/State/NoteManager.swift",
            "Features/Chat/ChatView.swift",
            "Features/Chat/ChatComposerBar.swift"
        ]
        for path in paths {
            let source = try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains("linkedConversationId") == false, "\(path) still references linkedConversationId")
            #expect(source.contains("continueAskPlaceholder") == false, "\(path) still references continueAskPlaceholder")
        }

        let testPaths = [
            "NoteTestSupport.swift"
        ]
        for path in testPaths {
            let source = try String(contentsOf: testRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains("linkedConversationId") == false, "\(path) still references linkedConversationId")
        }
    }

    @Test("AppState return-to-conversation route does not seed pinned note context")
    @MainActor
    func returnToConversationRouteDoesNotPinNoteContext() {
        let uid = "note-return-\(UUID().uuidString)"
        let state = AppState(seedDemoData: false, sessionUID: uid)
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        let noteID = UUID()
        let conversationID = UUID()

        state.prepareReturnToConversation(
            noteID: noteID,
            conversationID: conversationID,
            messageID: UUID()
        )

        #expect(state.pendingPinnedNoteIds.isEmpty)
        #expect(state.pendingNoteSourceJump?.conversationID == conversationID)
        #expect(state.pendingNoteSourceJump?.fromNoteID == noteID)
    }
}
