import Foundation
import OriveoProviderKit

/// propose_memory runtime state (P10 contract items 2, 6): the in-process degraded set plus mode resolution.
///
/// The degraded set lives for the process only: a connection + model whose first tool-carrying leg was
/// deterministically rejected falls back to the v1 path until relaunch.
@MainActor
final class ProposeMemoryRuntime {
    static let shared = ProposeMemoryRuntime()

    private var degradedKeys: Set<String> = []

    func markDegraded(connectionID: UUID, modelID: String) {
        degradedKeys.insert(Self.key(connectionID: connectionID, modelID: modelID))
    }

    func isDegraded(connectionID: UUID, modelID: String) -> Bool {
        degradedKeys.contains(Self.key(connectionID: connectionID, modelID: modelID))
    }

    /// Mode of one chat request. Can carry client tools = the MCP connection rule, not the Moonshot built-in
    /// web loop and not Gemini generateContent with web search on; an unresolved model counts as unable to carry tools.
    func mode(
        purpose: MemoryPropose.Purpose,
        freshSend: Bool,
        memoryEnabled: Bool,
        autoSuggest: Bool,
        provider: Provider?,
        model: AIModel?,
        webSearchEnabled: Bool,
        structuredOutputActive: Bool = false,
        toolCallMemory: ToolCallMemoryStore
    ) -> MemoryPropose.Mode {
        let support = toolSupport(
            provider: provider, model: model, webSearchEnabled: webSearchEnabled,
            structuredOutputActive: structuredOutputActive, toolCallMemory: toolCallMemory
        )
        return MemoryPropose.mode(MemoryPropose.ModeInput(
            purpose: purpose,
            freshSend: freshSend,
            memoryEnabled: memoryEnabled,
            autoSuggest: autoSuggest,
            connectionSupportsTools: support.supportsTools,
            degraded: support.degraded
        ))
    }

    /// search_memory mode of one request (memory-search.v1 rule 5): the same tool predicate and degraded set as
    /// propose_memory, but any chat request (retries and regenerations too) with at least one visible L3 item.
    func searchMode(
        purpose: MemoryPropose.Purpose,
        memoryEnabled: Bool,
        recallableItems: Int,
        provider: Provider?,
        model: AIModel?,
        webSearchEnabled: Bool,
        structuredOutputActive: Bool = false,
        toolCallMemory: ToolCallMemoryStore
    ) -> MemorySearch.Mode {
        let support = toolSupport(
            provider: provider, model: model, webSearchEnabled: webSearchEnabled,
            structuredOutputActive: structuredOutputActive, toolCallMemory: toolCallMemory
        )
        return MemorySearch.mode(MemorySearch.ModeInput(
            purpose: purpose,
            memoryEnabled: memoryEnabled,
            connectionSupportsTools: support.supportsTools,
            degraded: support.degraded,
            recallableItems: recallableItems
        ))
    }

    /// Can carry client tools = the MCP connection rule, not the Moonshot built-in web loop and not Gemini
    /// generateContent with web search on; an unresolved model counts as unable to carry tools.
    private func toolSupport(
        provider: Provider?, model: AIModel?, webSearchEnabled: Bool, structuredOutputActive: Bool,
        toolCallMemory: ToolCallMemoryStore
    ) -> (supportsTools: Bool, degraded: Bool) {
        guard let provider, let model else { return (false, false) }
        let runsMoonshotWebLoop = provider.kind == .moonshot && webSearchEnabled
        // Gemini generateContent rejects the search tool and function tools in one request.
        let geminiWebOn = webSearchEnabled && Self.usesGeminiGenerateContent(provider: provider, model: model)
        // Structured output (json_schema) conflicts with tools in the generation parameter contract (D-296).
        let supportsTools = !runsMoonshotWebLoop && !geminiWebOn && !structuredOutputActive
            && McpToolBridge.connectionSupportsTools(provider: provider, model: model, memory: toolCallMemory)
        return (supportsTools, isDegraded(connectionID: provider.id, modelID: model.id))
    }

    /// The request goes out as Gemini generateContent (native Gemini or a generateContent protocol route).
    static func usesGeminiGenerateContent(provider: Provider, model: AIModel) -> Bool {
        switch ProviderServiceRouter.route(provider: provider, model: model) {
        case let .byProtocol(route): route.transport == .geminiGenerateContent
        case let .native(kind): kind == .gemini
        }
    }

    private static func key(connectionID: UUID, modelID: String) -> String {
        MemoryPropose.degradedKey(connectionId: connectionID.uuidString, modelId: modelID)
    }
}

/// What AppState hands ChatManager for a mode=tool fresh send (P10 contract items 3-6).
@MainActor
struct ProposeMemoryTurnContext {
    let repository: MemoryCandidateRepository
    /// The user message text of this fresh send (the quote check runs against it).
    let userText: String
    let folderID: String?
    /// A propose call created a candidate; the controller keeps only the first one of the turn as the bar.
    let onCandidate: (MemoryCandidate, _ assistantMessageID: UUID) -> Void
    /// The tool-carrying first leg was deterministically rejected: this turn runs the fallback path.
    let onDegraded: (_ userMessageID: UUID, _ assistantMessageID: UUID) -> Void
}

/// How `finishProposeMemoryTurn` left the turn.
enum ProposeMemoryTurnOutcome {
    /// Delivered (or nothing to do for this turn).
    case finished
    /// Thinking with an empty first-leg text: the caller resends the original request through the plain pipeline
    /// without tools, carrying the first leg's held delivery so usage and cost are summed.
    /// `searchRecall`: entries search_memory returned on the first leg, appended after the automatic [D] recall.
    case plainResend(carried: ProposeMemoryDeferredDelivery, searchRecall: [ContextRecallEntry])
}

/// Host-tool state of one turn (propose_memory and / or search_memory), carried in the streaming session.
/// Both tools share one tail leg, one degraded set and one plain resend (memory-search.v1 legRules 2, 3, 5).
@MainActor
struct ProposeMemoryTurn {
    /// propose_memory context; nil when only search_memory is attached.
    let context: ProposeMemoryTurnContext?
    let userMessageID: UUID
    /// search_memory state; nil when this request is not in search tool mode.
    var search: MemorySearchSession?
    /// Host-tool calls (propose and search) seen and not yet executed, in call order.
    var pendingCalls: [ProviderToolCall] = []
    /// propose calls of this turn so far, whatever their outcome (priorInTurn).
    var callCount = 0

    init(context: ProposeMemoryTurnContext?, userMessageID: UUID, search: MemorySearchSession? = nil) {
        self.context = context
        self.userMessageID = userMessageID
        self.search = search
    }
    /// The first leg also asked for tools nobody runs here: no tail leg.
    var firstLegHadOtherCalls = false
    var firstLegFinish: StreamFinish?
    /// The first leg is over; later rejections are not a degrade and later calls never add a leg.
    var pastFirstLeg = false
    /// The first leg's successful completion, held until the calls ran and the tail leg (if any) finished.
    var deferredDelivery: ProposeMemoryDeferredDelivery?
}

/// Arguments of a held `completeStreamingMessage(state: .delivered)`.
struct ProposeMemoryDeferredDelivery {
    var estimatedCost: Double?
    var attachments: [Attachment]?
    var servedModelID: String?
    var reasoningText: String?
    var usageMetrics: ChatDeliveredUsageMetrics?
    var streamFinish: StreamFinish?
    var stopReason: StopReason?
    var clearsCitations: Bool
}
