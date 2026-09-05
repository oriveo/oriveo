import Foundation
import Testing
@testable import Oriveo

@Suite("ConversationProjectionBuilder")
struct ConversationProjectionBuilderTests {

    @Test("buildLegacyConversation preserves summary metadata and observed messages")
    func buildLegacyConversationPreservesSummaryAndMessages() {
        let conversationID = UUID()
        let providerID = UUID()
        let folderID = UUID()
        let skillID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_999)
        let messages = [
            TestFactories.makeMessage(role: .user, text: "hello"),
            TestFactories.makeMessage(role: .assistant, text: "world")
        ]
        let summary = ConversationSummary(
            id: conversationID,
            title: "Observed Title",
            hasCustomTitle: true,
            providerID: providerID,
            providerKind: .openAI,
            modelID: "gpt-4o",
            previewText: "world",
            messageCount: 2,
            estimatedCost: 1.23,
            isDraft: false,
            draftText: "draft value",
            createdAt: createdAt,
            updatedAt: updatedAt,
            folderID: folderID,
            useMemory: false,
            skillId: skillID,
            messagesHydratedAt: nil,
            messagesStale: false
        )

        let conversation = ConversationProjectionBuilder.buildLegacyConversation(
            summary: summary,
            messages: messages
        )

        #expect(conversation.id == conversationID)
        #expect(conversation.title == "Observed Title")
        #expect(conversation.hasCustomTitle == true)
        #expect(conversation.providerID == providerID)
        #expect(conversation.modelID == "gpt-4o")
        #expect(conversation.previewText == "world")
        #expect(abs(conversation.estimatedCost - 1.23) < 0.000_001)
        #expect(conversation.messages == messages)
        #expect(conversation.draftText == "draft value")
        #expect(conversation.folderID == folderID)
        #expect(conversation.useMemory == false)
        #expect(conversation.skillId == skillID)
        #expect(conversation.createdAt == createdAt)
        #expect(conversation.updatedAt == updatedAt)
    }
}
