import Foundation
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

        let result = ChatRequestBuilder.build(from: snapshot)
        let requestUser = try #require(result.requestMessages.first)
        #expect(requestUser.text.contains("\"selected\":\"conclusion\""))
        #expect(requestUser.text.hasSuffix("[Current User Input]\nContinue this paragraph"))
        #expect(requestUser.quoteContext == nil)
        #expect(user.text == "Continue this paragraph")
        #expect(result.requestOptions.systemPrompt.isEmpty)
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

        let result = ChatRequestBuilder.build(from: snapshot)

        #expect(result.requestMessages.count == 2)
        #expect(result.requestMessages.first?.id == attachmentOnlyMessage.id)
        #expect(result.requestMessages.first?.attachments?.first?.fileName == "diagram.png")
        #expect(result.requestMessages.first?.text.isEmpty == true)
        #expect(result.requestMessages.last?.id == deliveredAssistant.id)
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

        let result = ChatRequestBuilder.build(from: snapshot)

        #expect(result.requestMessages.map(\.role) == [.user, .assistant, .user])
        let assistantTurn = result.requestMessages.first(where: { $0.role == .assistant })
        #expect(assistantTurn?.text == "Here is the image I generated for you")
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

        let result = ChatRequestBuilder.build(from: snapshot)

        #expect(result.requestMessages.map(\.role) == [.user])
        #expect(result.requestMessages.first?.text == "Nice")
    }

    @Test("send path drops the older user left by a dropped mid-history empty failed assistant")
    func sendPathDropsOlderUserAfterDroppingEmptyFailedAssistant() {
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

        let result = ChatRequestBuilder.build(from: snapshot)

        #expect(result.requestMessages.map(\.role) == [.user, .assistant, .user])
        #expect(result.requestMessages.map(\.text) == ["q1", "a1", "q3"])
    }

    @Test("send path drops the orphaned earlier user when a stopped empty assistant is removed")
    func sendPathDropsOrphanedUserAfterEmptyInterruptedAssistant() {
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

        let result = ChatRequestBuilder.build(from: snapshot)

        #expect(result.requestMessages.map(\.role) == [.user])
        #expect(result.requestMessages.first?.text == "Who is the boss of Film Typhoon")
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

        let result = ChatRequestBuilder.build(from: snapshot)

        #expect(result.requestMessages.map(\.role) == [.user, .assistant, .user])
        #expect(result.requestMessages.map(\.text) == ["What is the micro-frontend framework called", "You probably mean micro-app", "Who is the boss of Film Typhoon"])
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

        let result = ChatRequestBuilder.build(from: snapshot)

        #expect(result.requestMessages.map(\.role) == [.user, .assistant])
        #expect(result.requestMessages.last?.text == "part1\n\npart2")
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

        let result = ChatRequestBuilder.build(from: snapshot)

        #expect(result.requestMessages.map(\.role) == [.user])
        #expect(result.requestMessages.first?.text == "q2")
    }

    @Test("continue path treats the current assistant as delivered and appends the continue instruction")
    func continuePathTreatsAssistantAsDelivered() {
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
            sendPath: .continueResponse(
                assistantMessageID: assistantMessageID,
                instruction: ChatManager.continueInstruction
            )
        )

        let result = ChatRequestBuilder.build(from: snapshot)

        #expect(result.requestMessages.count == 3)
        #expect(result.requestMessages[0].id == userMessage.id)
        #expect(result.requestMessages[1].id == assistantMessageID)
        #expect(result.requestMessages[1].state == .delivered)
        #expect(result.requestMessages[2].role == .user)
        #expect(result.requestMessages[2].text == ChatManager.continueInstruction)
    }

    @Test("continue instruction matches cross-platform contract")
    func continueInstructionMatchesCrossPlatformContract() {
        #expect(
            ChatManager.continueInstruction ==
                "Continue from where you stopped. Do not repeat what you have already said."
        )
    }

    @Test("builder composes skill prompt, knowledge files, memory, and anti-forget from immutable snapshots")
    func builderComposesSkillMemoryAndAntiForget() {
        var messages: [ChatMessage] = []
        for index in 0..<10 {
            messages.append(TestFactories.makeMessage(role: .user, text: "User message \(index)"))
            messages.append(TestFactories.makeMessage(role: .assistant, text: "Assistant reply \(index)"))
        }

        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: UUID(),
                useMemory: true,
                skillID: UUID()
            ),
            messages: messages,
            preferences: ChatRequestPreferencesSnapshot(
                memoryText: "User prefers concise Swift examples.",
                memoryAntiForgetEnabled: true,
                memoryAntiForgetText: "Keep the answer concise and code-first."
            ),
            skill: ChatRequestSkillSnapshot(
                id: UUID(),
                systemPrompt: "You are an iOS architecture copilot.",
                knowledgeFiles: [
                    ChatRequestKnowledgeFileSnapshot(
                        name: "guardrails.md",
                        content: "Prefer GRDB observations over legacy mirrors."
                    )
                ],
                useMemory: true
            ),
            sendPath: .send(excludingMessageID: nil)
        )

        let result = ChatRequestBuilder.build(from: snapshot)

        #expect(result.requestOptions.systemPrompt.contains("You are an iOS architecture copilot."))
        #expect(result.requestOptions.systemPrompt.contains("--- Reference: guardrails.md ---"))
        #expect(result.requestOptions.systemPrompt.contains("Prefer GRDB observations over legacy mirrors."))
        #expect(result.requestOptions.systemPrompt.contains("[User context: User prefers concise Swift examples.]"))

        let lastUserMessage = result.requestMessages.last(where: { $0.role == .user })
        #expect(lastUserMessage?.text.contains("[Reminder: Keep the answer concise and code-first.]") == true)
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
                memoryText: "User prefers concise Swift examples.",
                memoryAntiForgetEnabled: true,
                memoryAntiForgetText: "Keep the answer concise and code-first."
            ),
            skill: ChatRequestSkillSnapshot(
                id: UUID(),
                systemPrompt: "You are an iOS architecture copilot.",
                knowledgeFiles: [],
                useMemory: true
            ),
            sendPath: .send(excludingMessageID: nil)
        )

        let result = ChatRequestBuilder.build(from: snapshot)

        #expect(result.requestOptions.systemPrompt.contains("You are an iOS architecture copilot."))
        #expect(result.requestOptions.systemPrompt.contains("[User context: User prefers concise Swift examples.]") == false)
        let lastUserMessage = result.requestMessages.last(where: { $0.role == .user })
        #expect(lastUserMessage?.text.contains("[Reminder: Keep the answer concise and code-first.]") == false)
    }

    @Test("memory injection eligibility uses only snapshots, not full prompt assembly")
    func memoryInjectionEligibilityUsesOnlySnapshots() {
        let preferences = ChatRequestPreferencesSnapshot(
            memoryText: "User prefers concise Swift examples."
        )
        let conversation = ChatRequestConversationSnapshot(
            id: UUID(),
            useMemory: true,
            skillID: UUID()
        )
        let skill = ChatRequestSkillSnapshot(
            id: UUID(),
            systemPrompt: String(repeating: "System Prompt ", count: 200),
            knowledgeFiles: [
                ChatRequestKnowledgeFileSnapshot(
                    name: "guardrails.md",
                    content: String(repeating: "Large knowledge payload ", count: 500)
                )
            ],
            useMemory: true
        )

        #expect(
            ChatRequestBuilder.shouldInjectMemory(
                skill: skill,
                preferences: preferences,
                conversation: conversation
            ) == true
        )
        #expect(
            ChatRequestBuilder.shouldInjectMemory(
                skill: skill,
                preferences: preferences,
                conversation: ChatRequestConversationSnapshot(
                    id: conversation.id,
                    useMemory: false,
                    skillID: conversation.skillID
                )
            ) == false
        )
        #expect(
            ChatRequestBuilder.shouldInjectMemory(
                skill: nil,
                preferences: preferences,
                conversation: ChatRequestConversationSnapshot(
                    id: conversation.id,
                    useMemory: false,
                    skillID: nil
                )
            ) == false
        )
        #expect(
            ChatRequestBuilder.shouldInjectMemory(
                skill: nil,
                preferences: ChatRequestPreferencesSnapshot(memoryText: "   "),
                conversation: conversation
            ) == false
        )
    }

    @Test("memory injection availability respects prompt budget before counting usage")
    func memoryInjectionAvailabilityRespectsPromptBudget() {
        let preferences = ChatRequestPreferencesSnapshot(
            memoryText: "User prefers concise Swift examples."
        )
        let skill = ChatRequestSkillSnapshot(
            id: UUID(),
            systemPrompt: String(repeating: "S", count: 11_990),
            knowledgeFiles: [],
            useMemory: true
        )
        let conversation = ChatRequestConversationSnapshot(
            id: UUID(),
            useMemory: true,
            skillID: UUID()
        )

        #expect(
            ChatRequestBuilder.willInjectMemory(
                skill: skill,
                preferences: preferences,
                conversation: conversation
            ) == false
        )
        #expect(
            ChatRequestBuilder.buildPromptInjectionContext(
                skill: skill,
                preferences: preferences,
                conversation: conversation
            )?.memoryInjected == false
        )
    }

    @Test("knowledge base snippets are trimmed before reference files when prompt budget overflows")
    func knowledgeBaseSnippetsTrimBeforeReferenceFiles() {
        let skill = ChatRequestSkillSnapshot(
            id: UUID(),
            systemPrompt: "You are an iOS architecture copilot.",
            knowledgeFiles: [
                ChatRequestKnowledgeFileSnapshot(
                    name: "rules.md",
                    content: String(repeating: "R", count: 5_000)
                )
            ],
            knowledgeBase: ChatRequestKnowledgeBaseSnapshot(
                retrievalModel: "gpt-5.4-mini",
                vectorStoreId: "vs_123",
                readyFileCount: 1
            ),
            useMemory: true
        )

        let budgeted = ChatRequestBuilder.applyKnowledgeBudget(
            skill: skill,
            retrievalSnippets: [
                ChatRequestRetrievedSnippet(
                    fileName: "kb.txt",
                    text: String(repeating: "K", count: 4_000),
                    score: 1
                )
            ],
            remainingChars: 7_000
        )

        #expect(budgeted.referenceFiles.count == 1)
        #expect(budgeted.referenceFiles[0].content.count == 5_000)
        #expect(budgeted.retrievalSnippets.count == 1)
        #expect(budgeted.retrievalSnippets[0].text.count == 2_000)
    }

    @Test("builder injects knowledge base snippets after reference files")
    func builderInjectsKnowledgeBaseSnippetsAfterReferenceFiles() {
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(
                id: UUID(),
                useMemory: true,
                skillID: UUID()
            ),
            messages: [
                TestFactories.makeMessage(role: .user, text: "Explain how to structure this app.")
            ],
            preferences: ChatRequestPreferencesSnapshot(
                memoryText: "User prefers concise Swift examples."
            ),
            skill: ChatRequestSkillSnapshot(
                id: UUID(),
                systemPrompt: "You are an iOS architecture copilot.",
                knowledgeFiles: [
                    ChatRequestKnowledgeFileSnapshot(
                        name: "guardrails.md",
                        content: "Prefer focused services."
                    )
                ],
                knowledgeBase: ChatRequestKnowledgeBaseSnapshot(
                    retrievalModel: "gpt-5.4-mini",
                    vectorStoreId: "vs_123",
                    readyFileCount: 1
                ),
                useMemory: true
            ),
            retrievedSnippets: [
                ChatRequestRetrievedSnippet(
                    fileName: "kb.txt",
                    text: "Retrieved guidance from the vector store.",
                    score: 0.98
                )
            ],
            sendPath: .send(excludingMessageID: nil)
        )

        let result = ChatRequestBuilder.build(from: snapshot)
        let systemPrompt = result.requestOptions.systemPrompt

        #expect(systemPrompt.contains("--- Reference: guardrails.md ---"))
        #expect(systemPrompt.contains("Prefer focused services."))
        #expect(systemPrompt.contains("--- Knowledge Base: kb.txt ---"))
        #expect(systemPrompt.contains("Retrieved guidance from the vector store."))
        #expect(
            systemPrompt.range(of: "--- Reference: guardrails.md ---")?.lowerBound ?? systemPrompt.startIndex
                < systemPrompt.range(of: "--- Knowledge Base: kb.txt ---")?.lowerBound ?? systemPrompt.endIndex
        )
    }
}
