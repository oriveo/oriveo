import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

@Suite("ChatRequestBuilder")
struct ChatRequestBuilderTests {

    @Test("Quote Context Expands At Provider Boundary")
    func quoteContextExpandsAtProviderBoundary() throws {
        var user = TestFactories.makeMessage(role: .user, text: "Continue this paragraph")
        user.quoteContext = try QuoteContext.capture(
            sourceMessageID: UUID(),
            sourceRole: .assistant,
            contentKind: .table,
            leadingText: "Before ",
            selectedText: "conclusion",
            trailingText: " after"
        ).get()
        let assistant = TestFactories.makeMessage(role: .assistant, text: "old reply")
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
            messages: [user, assistant],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )

        let result = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly)
        let requestUser = try #require(result.planned.messages.first)
        #expect(requestUser.text.contains("\"selected\":\"conclusion\""))
        #expect(requestUser.text.hasSuffix("[Current User Input]\nContinue this paragraph"))
        #expect(requestUser.quoteContext == nil)
        #expect(user.text == "Continue this paragraph")
        #expect(result.planned.system.isEmpty)
    }

    @Test("send path preserves delivered attachment-only user messages")
    func sendPathPreservesAttachmentOnlyUserMessages() {
        let imageAttachment = TestFactories.makeImageAttachment(fileName: "diagram.png")
        let attachmentOnlyMessage = TestFactories.makeMessage(
            role: .user,
            text: "",
            attachments: [imageAttachment]
        )
        let deliveredAssistant = TestFactories.makeMessage(role: .assistant, text: "I can help with that.")
        let generatingAssistantID = UUID()
        let generatingAssistant = TestFactories.makeMessage(
            id: generatingAssistantID,
            role: .assistant,
            text: "",
            state: .generating
        )

        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: UUID(),
                useMemory: true,
                skillID: nil
            ),
            messages: [attachmentOnlyMessage, deliveredAssistant, generatingAssistant],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: generatingAssistantID)
        )

        let result = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly)

        #expect(result.planned.messages.count == 2)
        #expect(result.planned.messages.first?.id == attachmentOnlyMessage.id)
        #expect(result.planned.messages.first?.attachments?.first?.fileName == "diagram.png")
        #expect(result.planned.messages.first?.text.isEmpty == true)
        #expect(result.planned.messages.last?.id == deliveredAssistant.id)
    }

    @Test("send path strips AI-generated images off assistant messages but keeps their text")
    func sendPathStripsAssistantGeneratedImages() {
        let userPrompt = TestFactories.makeMessage(role: .user, text: "Draw a farmer")
        let generatedImage = TestFactories.makeImageAttachment(fileName: "generated.png")
        let assistantWithImage = TestFactories.makeMessage(
            role: .assistant,
            text: "Here is the image I generated for you",
            attachments: [generatedImage]
        )
        let followUp = TestFactories.makeMessage(role: .user, text: "Nice")

        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
            messages: [userPrompt, assistantWithImage, followUp],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )

        let result = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly)

        #expect(result.planned.messages.map(\.role) == [.user, .assistant, .user])
        let assistantTurn = result.planned.messages.first(where: { $0.role == .assistant })
        #expect(assistantTurn?.text == "Here is the image I generated for you")
        // The generated image is stripped, so the assistant no longer carries any media attachment
        #expect(assistantTurn?.attachments?.isEmpty ?? true)
    }

    @Test("send path drops an image-only assistant message after stripping its generated image")
    func sendPathDropsImageOnlyAssistantMessage() {
        let userPrompt = TestFactories.makeMessage(role: .user, text: "Draw a farmer")
        let imageOnlyAssistant = TestFactories.makeMessage(
            role: .assistant,
            text: "",
            attachments: [TestFactories.makeImageAttachment(fileName: "generated.png")]
        )
        let followUp = TestFactories.makeMessage(role: .user, text: "Nice")

        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
            messages: [userPrompt, imageOnlyAssistant, followUp],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )

        let result = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly)

        // The text-less generated-image assistant becomes empty and is dropped; the now adjacent users merge
        // into one, with the earlier text inside the unanswered envelope (contract sanitize.v1).
        #expect(result.planned.messages.map(\.role) == [.user])
        #expect(result.planned.messages.first?.id == followUp.id)
        #expect(result.planned.messages.first?.text == "<oriveo-unanswered>\n<note>\(ContextSanitizer.unansweredNote)</note>\nDraw a farmer\n</oriveo-unanswered>\n\nNice")
    }

    @Test("send path folds the older user left by a dropped mid-history empty failed assistant into the envelope")
    func sendPathFoldsOlderUserAfterDroppingEmptyFailedAssistant() {
        // u1 -> a1(delivered) -> u2 -> a2(failed, '') -> u3: once a2 is dropped u2/u3 are adjacent. Strict relays
        // require alternation, so they merge into one: u2 goes into the unanswered envelope, u3's text follows,
        // and u3's id is kept (contract sanitize.v1).
        let u1 = TestFactories.makeMessage(role: .user, text: "q1")
        let a1 = TestFactories.makeMessage(role: .assistant, text: "a1")
        let u2 = TestFactories.makeMessage(role: .user, text: "q2")
        let failedAssistant = TestFactories.makeMessage(role: .assistant, text: "", state: .failed)
        let u3 = TestFactories.makeMessage(role: .user, text: "q3")

        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: UUID(),
                useMemory: false,
                skillID: nil
            ),
            messages: [u1, a1, u2, failedAssistant, u3],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )

        let result = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly)

        #expect(result.planned.messages.map(\.role) == [.user, .assistant, .user])
        #expect(result.planned.messages.map(\.text) == ["q1", "a1", "<oriveo-unanswered>\n<note>\(ContextSanitizer.unansweredNote)</note>\nq2\n</oriveo-unanswered>\n\nq3"])
        #expect(result.planned.messages.last?.id == u3.id)
    }

    @Test("send path keeps the orphaned earlier user as unanswered context when a stopped empty assistant is removed")
    func sendPathEnvelopesOrphanedUserAfterEmptyInterruptedAssistant() {
        // Ask A -> tap stop (the assistant is interrupted before any text) -> ask B. Gluing A and B into one
        // prompt made the model answer both; dropping A loses standing instructions. Per contract sanitize.v1,
        // A goes into the unanswered envelope (which says to answer only the latest) and B's text follows.
        let uA = TestFactories.makeMessage(role: .user, text: "What is the micro-frontend framework called")
        let aA = TestFactories.makeMessage(role: .assistant, text: "", state: .interrupted)
        let uB = TestFactories.makeMessage(role: .user, text: "Who is the boss of Film Typhoon")

        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
            messages: [uA, aA, uB],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )

        let result = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly)

        #expect(result.planned.messages.map(\.role) == [.user])
        #expect(result.planned.messages.first?.id == uB.id)
        #expect(result.planned.messages.first?.text == "<oriveo-unanswered>\n<note>\(ContextSanitizer.unansweredNote)</note>\nWhat is the micro-frontend framework called\n</oriveo-unanswered>\n\nWho is the boss of Film Typhoon")
    }

    @Test("send path keeps a non-empty interrupted assistant to separate two user turns")
    func sendPathKeepsPartialInterruptedAssistantBetweenUsers() {
        let uA = TestFactories.makeMessage(role: .user, text: "What is the micro-frontend framework called")
        let aA = TestFactories.makeMessage(role: .assistant, text: "You probably mean micro-app", state: .interrupted)
        let uB = TestFactories.makeMessage(role: .user, text: "Who is the boss of Film Typhoon")

        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
            messages: [uA, aA, uB],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )

        let result = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly)

        #expect(result.planned.messages.map(\.role) == [.user, .assistant, .user])
        #expect(result.planned.messages.map(\.text) == ["What is the micro-frontend framework called", "You probably mean micro-app", "Who is the boss of Film Typhoon"])
    }

    @Test("send path merges adjacent assistant messages from malformed history")
    func sendPathMergesAdjacentAssistants() {
        let u1 = TestFactories.makeMessage(role: .user, text: "q1")
        let a1 = TestFactories.makeMessage(role: .assistant, text: "part1")
        let a2 = TestFactories.makeMessage(role: .assistant, text: "part2")

        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
            messages: [u1, a1, a2],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )

        let result = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly)

        #expect(result.planned.messages.map(\.role) == [.user, .assistant])
        #expect(result.planned.messages.last?.text == "part1\n\npart2")
    }

    @Test("send path drops a failed assistant turn even when its text holds an error placeholder")
    func sendPathDropsFailedAssistantWithErrorPlaceholderText() {
        let u1 = TestFactories.makeMessage(role: .user, text: "q1")
        let failed = TestFactories.makeMessage(role: .assistant, text: "Request failed: invalid API key", state: .failed)
        let u2 = TestFactories.makeMessage(role: .user, text: "q2")

        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil),
            messages: [u1, failed, u2],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )

        let result = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly)

        #expect(result.planned.messages.map(\.role) == [.user])
        #expect(result.planned.messages.first?.text == "<oriveo-unanswered>\n<note>\(ContextSanitizer.unansweredNote)</note>\nq1\n</oriveo-unanswered>\n\nq2")
    }

    @Test("continue path is a plan of purpose continue: history through the delivered target plus the core continue prompt")
    func continuePathTreatsAssistantAsDelivered() throws {
        let assistantMessageID = UUID()
        let userMessage = TestFactories.makeMessage(role: .user, text: "Explain GRDB observations.")
        let assistantMessage = TestFactories.makeMessage(
            id: assistantMessageID,
            role: .assistant,
            text: "Here is the partial answer",
            state: .generating
        )

        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: UUID(),
                useMemory: true,
                skillID: nil
            ),
            messages: [userMessage, assistantMessage],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .continueResponse(assistantMessageID: assistantMessageID)
        )

        let result = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly)
        let plan = result.planned.plan

        #expect(plan.purpose == .continue)
        #expect(plan.reminder == false)
        #expect(plan.messages?.map(\.id).prefix(2) == [userMessage.id.uuidString, assistantMessageID.uuidString])
        #expect(result.planned.messages.count == 3)
        #expect(result.planned.messages[0].id == userMessage.id)
        #expect(result.planned.messages[1].id == assistantMessageID)
        #expect(result.planned.messages[1].text == "Here is the partial answer")
        #expect(result.planned.messages[2].role == .user)
        #expect(result.planned.messages[2].text == ContextAssembler.continuePrompt)
        #expect(result.requestOptions.statefulLegText == ContextAssembler.continuePrompt)
    }

    @Test("continue prompt is the core constant shared by every platform")
    func continueInstructionMatchesCrossPlatformContract() {
        #expect(
            ContextAssembler.continuePrompt ==
                "Continue exactly where your previous answer stopped. Do not repeat what you already wrote."
        )
    }

    @Test("anti-forget preference enabled with text still yields requests without [Reminder:")
    @MainActor
    func antiForgetPreferenceNeverInjectsReminder() {
        var messages: [ChatMessage] = []
        for index in 0..<12 {
            messages.append(TestFactories.makeMessage(role: .user, text: "User message \(index)"))
            messages.append(TestFactories.makeMessage(role: .assistant, text: "Assistant reply \(index)"))
        }
        let preference = AppPreference(
            theme: .system,
            language: .system,
            memoryText: "User prefers concise Swift examples.",
            memoryAntiForgetEnabled: true,
            memoryAntiForgetText: "Keep the answer concise and code-first.",
            memoryUpdatedAt: Date()
        )
        // The preference itself is kept as is (stored / synced / backed up); it just no longer reaches requests
        #expect(preference.memoryAntiForgetEnabled)
        #expect(preference.memoryAntiForgetText == "Keep the answer concise and code-first.")

        for sendPath in [
            ChatRequestSendPath.send(excludingMessageID: nil),
            .continueResponse(assistantMessageID: messages[messages.count - 1].id),
        ] {
            let result = ChatRequestBuilder.build(from: ChatRequestSnapshot(
                conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: true, skillID: nil),
                messages: messages,
                preferences: ChatRequestPreferencesSnapshot(
                    memoryItems: RetiredAntiForgetProbe.memoryItems(preference.memoryText)
                ),
                skill: nil,
                sendPath: sendPath
            ), assembly: RetiredAntiForgetProbe.assembly)
            #expect(result.planned.system.contains("User prefers concise Swift examples."))
            #expect(RetiredAntiForgetProbe.containsReminder(result) == false)
        }
    }

    @Test("skill path respects the current conversation memory toggle")
    func skillPathRespectsConversationUseMemoryToggle() {
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: UUID(),
                useMemory: false,
                skillID: UUID()
            ),
            messages: [
                TestFactories.makeMessage(role: .user, text: "hello"),
                TestFactories.makeMessage(role: .assistant, text: "world")
            ],
            preferences: ChatRequestPreferencesSnapshot(
                memoryItems: RetiredAntiForgetProbe.memoryItems("User prefers concise Swift examples.")
            ),
            skill: ChatRequestSkillSnapshot(
                id: UUID(),
                systemPrompt: "You are an iOS architecture copilot.",
                knowledgeFiles: [],
                useMemory: true
            ),
            sendPath: .send(excludingMessageID: nil)
        )

        let result = ChatRequestBuilder.build(from: snapshot, assembly: RetiredAntiForgetProbe.assembly)

        #expect(result.planned.system.contains("You are an iOS architecture copilot."))
        #expect(result.planned.system.contains("[User context: User prefers concise Swift examples.]") == false)
        #expect(RetiredAntiForgetProbe.containsReminder(result) == false)
    }

}

/// Anti-forget no longer injects reminders. Memory-related tests run the production
/// `ChatRequestBuilder.build` through this probe and assert that the outbound request
/// (every message and the system prompt) never contains `[Reminder:`.
enum RetiredAntiForgetProbe {
    static let reminderMarker = "[Reminder:"
    /// Assembly parameters with an unknown window (no budget trimming): only the projected shape of the plan matters.
    static let assembly = ChatRequestAssemblyContext(
        window: ContextWindowInput(W: nil, windowKind: .total, maxOutput: ContextMaxOutputSources()),
        rhoHi: 0.5
    )

    static func build(
        _ messages: [ChatMessage],
        memoryText: String,
        useMemory: Bool
    ) -> ChatRequestBuildResult {
        ChatRequestBuilder.build(from: ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: useMemory, skillID: nil),
            messages: messages,
            preferences: ChatRequestPreferencesSnapshot(memoryItems: memoryItems(memoryText)),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        ), assembly: RetiredAntiForgetProbe.assembly)
    }

    /// Memory items are injected on read: the old memoryText fixture becomes a single global fact.
    static func memoryItems(_ memoryText: String) -> [MemoryItem] {
        memoryText.isEmpty
            ? []
            : [MemoryItem(id: "mem-probe", kind: .fact, content: memoryText, mutationId: "mut-probe", deviceId: "device-test")]
    }

    static func containsReminder(_ result: ChatRequestBuildResult) -> Bool {
        result.planned.system.contains(reminderMarker)
            || result.planned.messages.contains { $0.text.contains(reminderMarker) }
    }
}
