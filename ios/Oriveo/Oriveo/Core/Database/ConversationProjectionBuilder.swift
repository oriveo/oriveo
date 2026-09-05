import Foundation

enum ConversationProjectionBuilder {
    static func buildLegacyConversation(
        summary: ConversationSummary,
        messages: [ChatMessage]
    ) -> Conversation {
        var conversation = Conversation(
            id: summary.id,
            title: summary.title,
            providerID: summary.providerID,
            providerKind: summary.providerKind,
            modelID: summary.modelID,
            previewText: summary.previewText,
            estimatedCost: summary.estimatedCost,
            isDraft: summary.isDraft,
            messages: messages,
            draftText: summary.draftText,
            createdAt: summary.createdAt,
            updatedAt: summary.updatedAt,
            folderID: summary.folderID
        )
        conversation.hasCustomTitle = summary.hasCustomTitle
        conversation.useMemory = summary.useMemory
        conversation.skillId = summary.skillId
        conversation.metadataUpdatedAt = summary.metadataUpdatedAt
        conversation.messageCountOverride = max(summary.messageCount, summary.remoteMessageCount)
        return conversation
    }
}
