import Foundation
import OriveoProviderKit

/// The only request chat entry points accept: it can only be obtained by projecting a ContextPlan, and the initializer is visible only in this file.
/// system = plan.system; messages = plan.messages mapped back to app messages ([D] is appended after a blank line to the end of the last user text);
/// dynamicText = the [D] blocks joined by blank lines, empty if none.
nonisolated struct PlannedChatRequest: Sendable {
    let plan: ContextPlan
    let system: String
    let messages: [ChatMessage]
    let dynamicText: String

    fileprivate init(plan: ContextPlan, system: String, messages: [ChatMessage], dynamicText: String) {
        self.plan = plan
        self.system = system
        self.messages = messages
        self.dynamicText = dynamicText
    }

    /// Arguments for the chat entry point: the other fields of options pass through unchanged; systemPrompt / dynamicText are written only here.
    func transportInput(_ options: ChatRequestOptions) -> TransportInput {
        var options = options
        options.systemPrompt = system
        options.dynamicText = dynamicText.isEmpty ? nil : dynamicText
        return TransportInput(messages: messages, options: options)
    }

    /// Projection of chat / continue / toolLoopLeg: plan messages fetch their original message and attachments by id, and attachments go through the outbound history budget.
    static func projecting(
        _ plan: ContextPlan,
        messages: [String: ChatMessage],
        attachments: [String: Attachment]
    ) -> PlannedChatRequest {
        let planMessages = plan.messages ?? []
        let projected = OutboundAttachmentBudget.apply(
            to: planMessages.compactMap { projectedMessage($0, messages: messages, attachments: attachments) }
        )
        let dynamicText = planMessages
            .flatMap(\.blocks)
            .filter { $0.kind == .dynamic }
            .map(\.text)
            .joined(separator: "\n\n")
        return PlannedChatRequest(plan: plan, system: plan.system ?? "", messages: projected, dynamicText: dynamicText)
    }

    /// Projection of single-purpose requests (crosscheck / memoryExtraction): plan messages fetch the original history messages by id, with the text replaced by the plan block text;
    /// no [D], dynamicText is empty.
    static func projectingPurpose(_ plan: ContextPlan, history: [ChatMessage]) -> PlannedChatRequest {
        let byID = Dictionary(history.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        let messages: [ChatMessage] = (plan.messages ?? []).compactMap { planMessage in
            guard var message = byID[planMessage.id] else { return nil }
            message.text = planMessage.blocks.map(\.text).joined(separator: "\n\n")
            return message
        }
        return PlannedChatRequest(plan: plan, system: plan.system ?? "", messages: messages, dynamicText: "")
    }

    /// Compaction summary call: purpose compaction; system and messages are sent exactly as the summary request has them,
    /// with no tools, [D] or extra memory. The plan only carries purpose and budget.
    static func compactionSummary(
        system: String,
        messages: [ChatMessage],
        window: ContextWindowInput,
        instructions: String? = nil
    ) -> PlannedChatRequest {
        let plan = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .compaction,
            window: window,
            conversation: ContextConversation(id: "", useMemory: false, instructions: instructions),
            history: messages.map { message in
                ContextMessage(
                    id: message.id.uuidString,
                    role: message.role == .user ? .user : .assistant,
                    text: message.text,
                    state: .delivered,
                    attachments: []
                )
            }
        ))
        return PlannedChatRequest(plan: plan, system: system, messages: messages, dynamicText: "")
    }

    /// Projection of dedicated image generation: a single user message, text = plan.imagePrompt, other fields and attachments taken from the last user message;
    /// no system or [D]. The message list is empty when the plan gives no prompt or there is no user message.
    static func projectingImageGeneration(_ plan: ContextPlan, history: [ChatMessage]) -> PlannedChatRequest {
        var messages: [ChatMessage] = []
        if let prompt = plan.imagePrompt, var latestUser = history.last(where: { $0.role == .user }) {
            latestUser.text = prompt
            messages = [latestUser]
        }
        return PlannedChatRequest(plan: plan, system: "", messages: messages, dynamicText: "")
    }

    /// The Responses inline image-generation tool and the Gemini image modality still send a chat request, but the last user message is swapped back to the user's original text
    /// (no [D] / checkpoint), so this projection's dynamicText is empty. Returned unchanged when the original text is empty or there is no user message.
    func replacingLatestUserText(with text: String) -> PlannedChatRequest {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = messages.lastIndex(where: { $0.role == .user }) else { return self }
        var replaced = messages
        replaced[index].text = text
        return PlannedChatRequest(plan: plan, system: system, messages: replaced, dynamicText: "")
    }

    /// Maps plan messages back to app messages: fields come from the original message with the same id, text = text blocks followed by [D] blocks (separated by blank lines), attachments fetched back by id.
    private static func projectedMessage(
        _ planMessage: ContextPlanMessage,
        messages: [String: ChatMessage],
        attachments: [String: Attachment]
    ) -> ChatMessage? {
        guard var message = messages[planMessage.id] else { return nil }
        message.text = planMessage.blocks.map(\.text).joined(separator: "\n\n")
        let resolved = planMessage.attachments.compactMap { attachments[$0.id] }
        message.attachments = resolved.isEmpty ? nil : resolved
        message.quoteContext = nil
        return message
    }
}

/// The argument pair for the chat entry point: it can only be produced by `PlannedChatRequest.transportInput(_:)`.
nonisolated struct TransportInput: Sendable {
    let messages: [ChatMessage]
    let options: ChatRequestOptions

    fileprivate init(messages: [ChatMessage], options: ChatRequestOptions) {
        self.messages = messages
        self.options = options
    }

    /// Tool-loop first-leg messages: the plan's system (options.systemPrompt) goes first, then the history.
    /// An empty system is not sent. This is the only place tool-loop legs get a system message.
    func toolLoopMessages(history: [ToolLoopMessage]) -> [ToolLoopMessage] {
        let system = options.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return system.isEmpty ? history : [ToolLoopMessage(role: "system", content: system)] + history
    }
}
