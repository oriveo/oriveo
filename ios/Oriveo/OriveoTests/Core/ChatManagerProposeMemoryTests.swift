import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

// Normal sends attach propose_memory when mode=tool; when only propose is called, one extra leg is added;
// a tail leg that calls propose again adds no further leg; when the first leg's tools are deterministically rejected, resend without tools and degrade; with thinking and an empty first-leg body, resend once without tools.
// Assertions come from the production path: AppState.sendMessage -> ChatManager -> request bodies recorded by ScriptedModelURLProtocol, the persisted assistant message, and the candidate store.

private let proposeUserText = "\u{8BB0}\u{4F4F}\u{6211}\u{559C}\u{6B22}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}"

private func proposeArguments(_ proposition: String) -> String {
    let object: [String: Any] = [
        "proposition": proposition, "sourceQuote": "\u{6211}\u{559C}\u{6B22}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}", "kind": "preference", "scope": "global",
    ]
    return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
}

private func proposeSSE(_ frames: [[String: Any]]) -> String {
    frames.map { frame in
        let data = (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }.joined() + "data: [DONE]\n\n"
}

private func usageFrame(prompt: Int, completion: Int) -> [String: Any] {
    ["choices": [Any](), "usage": ["prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion]]
}

/// One leg: optional thinking, optional body, optional single propose call; ends with tool_calls when there is a call.
private func proposeLeg(
    reasoning: String? = nil,
    text: String? = nil,
    callID: String? = nil,
    proposition: String = "\u{504F}\u{597D}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}",
    usage: (Int, Int) = (10, 2)
) -> String {
    var frames: [[String: Any]] = []
    if let reasoning { frames.append(["choices": [["delta": ["reasoning_content": reasoning]]]]) }
    if let text { frames.append(["choices": [["delta": ["content": text]]]]) }
    if let callID {
        frames.append(["choices": [["delta": ["tool_calls": [
            ["index": 0, "id": callID, "type": "function",
             "function": ["name": MemoryPropose.toolName, "arguments": proposeArguments(proposition)]],
        ]]]]])
    }
    frames.append(["choices": [["delta": [String: Any](), "finish_reason": callID == nil ? "stop" : "tool_calls"]]])
    frames.append(usageFrame(prompt: usage.0, completion: usage.1))
    return proposeSSE(frames)
}

/// One leg: optional thinking, optional body, and a sequence of host tool calls (name, id, arguments); ends with tool_calls when there are calls.
private func hostLeg(
    reasoning: String? = nil,
    text: String? = nil,
    calls: [(name: String, id: String, arguments: String)] = [],
    usage: (Int, Int) = (10, 2)
) -> String {
    var frames: [[String: Any]] = []
    if let reasoning { frames.append(["choices": [["delta": ["reasoning_content": reasoning]]]]) }
    if let text { frames.append(["choices": [["delta": ["content": text]]]]) }
    if !calls.isEmpty {
        frames.append(["choices": [["delta": ["tool_calls": calls.enumerated().map { index, call in
            ["index": index, "id": call.id, "type": "function",
             "function": ["name": call.name, "arguments": call.arguments]] as [String: Any]
        }]]]])
    }
    frames.append(["choices": [["delta": [String: Any](), "finish_reason": calls.isEmpty ? "stop" : "tool_calls"]]])
    frames.append(usageFrame(prompt: usage.0, completion: usage.1))
    return proposeSSE(frames)
}

private let searchArguments = #"{"query":"Tesla car bought"}"#

/// Shares no word with the user message: the [D] auto-recall will not bring it in, only search_memory can find it.
private let teslaItem = MemoryItem(
    id: "40000000-0000-4000-8000-0000000000a5", layer: .episodic, kind: .event,
    content: "Bought a Tesla Model 3 after the test drive", mutationId: "mut-search", deviceId: "device-test",
    occurredAt: "2025-08-10T10:00:00Z", createdAt: "2025-08-10T10:00:00Z"
)

private let teslaEntry = #"<entry date="2025-08-10">Bought a Tesla Model 3 after the test drive</entry>"#

private let toolsRejectedBody = #"{"error":{"message":"tools is not supported for this model","type":"invalid_request_error"}}"#

@Suite("ChatManagerProposeMemory", .serialized)
@MainActor
struct ChatManagerProposeMemoryTests {
    struct Run {
        let state: AppState
        let conversationID: UUID
        let provider: Provider
        let model: AIModel
        let message: ChatMessage
        let bodies: [[String: Any]]
    }

    /// Sends a new message from AppState.sendMessage and waits for the assistant message to finish and fallback candidate generation to complete.
    private func send(
        legs: [(Int, String)],
        provider custom: (Provider, AIModel)? = nil,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection(),
        prepare: ((Provider, AIModel, UUID) -> Void)? = nil,
        memoryItems: [MemoryItem] = [],
        useMemory: Bool = true,
        _ body: (Run) async throws -> Void
    ) async throws {
        await MetadataClient.shared.resetForTesting()
        ScriptedModelURLProtocol.reset(legs)
        let uid = "propose-memory-\(UUID().uuidString)"
        let state = AppState(
            seedDemoData: false,
            sessionUID: uid,
            providerSession: ScriptedModelURLProtocol.session(),
            toolCallMemory: try makeToolLoopMemoryStore()
        )
        let (provider, model) = custom ?? makeToolLoopRelayProvider(transport: .openaiChatCompletions)
        state.providers = [provider]
        var conversation = TestFactories.makeConversation(
            hasCustomTitle: true, providerID: provider.id, modelID: model.id, messages: []
        )
        conversation.useMemory = useMemory
        state.upsertConversationProjection(conversation)
        prepare?(provider, model, conversation.id)
        if !memoryItems.isEmpty { try await ContextPipelineTests.seedMemory(state, memoryItems) }
        defer {
            RelayWebFragmentStore.shared.deleteConnection(provider.id)
            RelayWebProbeStore.shared.clearConnection(provider.id.uuidString)
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }
        _ = await state.sendMessage(proposeUserText, in: conversation.id, capabilitySelection: capabilitySelection)
        var assistant: ChatMessage?
        for _ in 0..<200 {
            assistant = state.conversation(for: conversation.id)?.messages.last(where: { $0.role == .assistant })
            if let assistant, assistant.state != .generating { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await state.memoryCandidateGeneration?.value
        let message = try #require(assistant)
        try await body(Run(
            state: state, conversationID: conversation.id, provider: provider, model: model,
            message: message, bodies: ScriptedModelURLProtocol.snapshot().map(\.body)
        ))
    }

    private static func pending(_ state: AppState) async throws -> [MemoryCandidate] {
        let repository = try #require(state.memoryCandidateRepository())
        return try await repository.pending(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    private static func toolNames(_ body: [String: Any]) -> [String] {
        (body["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    }

    private static func messages(_ body: [String: Any]) -> [[String: Any]] {
        body["messages"] as? [[String: Any]] ?? []
    }

    /// Tool names of Anthropic Messages (tools[].name).
    private static func anthropicToolNames(_ body: [String: Any]) -> [String] {
        (body["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// Function names of Gemini generateContent (tools[].functionDeclarations[].name).
    private static func geminiFunctionNames(_ body: [String: Any]) -> [String] {
        (body["tools"] as? [[String: Any]] ?? []).flatMap { tool in
            (tool["functionDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
    }

    @Test("A new send attaches tools when it can carry them")
    func attachesToolWhenConnectionCanCarryTools() async throws {
        try await send(legs: [(200, proposeLeg(text: "Sure."))]) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            #expect(run.message.text == "Sure.")
            let first = try #require(run.bodies.first)
            #expect(Self.toolNames(first).last == MemoryPropose.toolName)
            #expect(!Self.toolNames(first).contains(MemorySearch.toolName), "search_memory is not attached without L3 items")
            #expect(first["tool_choice"] as? String == "auto")
            #expect(run.bodies.count == 1)
        }
    }

    // MARK: search_memory (memory-search.v1 rules 4-6, legRules 1-3)

    private static func lastUserText(_ body: [String: Any]) -> String {
        ContextPipelineTests.wireMessages(body).last { $0.role == "user" }?.text ?? ""
    }

    @Test("With L3 items, search_memory comes after propose_memory")
    func searchAttachedAfterPropose() async throws {
        try await send(legs: [(200, hostLeg(text: "Sure."))], memoryItems: [teslaItem]) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            let first = try #require(run.bodies.first)
            #expect(Array(Self.toolNames(first).suffix(2)) == [MemoryPropose.toolName, MemorySearch.toolName])
            #expect(first["tool_choice"] as? String == "auto")
            #expect(run.bodies.count == 1)
            #expect(run.message.memoryItemIds.contains(teslaItem.id) == false, "An item not fetched by search does not count as used")
        }
    }

    /// Waits for the last assistant message of this conversation to finish and returns all request bodies the production path has sent so far.
    private static func settle(_ run: Run, expectedRequests: Int) async throws -> (ChatMessage, [[String: Any]]) {
        var assistant: ChatMessage?
        for _ in 0..<200 {
            assistant = run.state.conversation(for: run.conversationID)?.messages.last(where: { $0.role == .assistant })
            if let assistant, assistant.state != .generating,
               !run.state.chatManager.isBusyStreaming(in: run.conversationID),
               ScriptedModelURLProtocol.snapshot().count >= expectedRequests { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return (try #require(assistant), ScriptedModelURLProtocol.snapshot().map(\.body))
    }

    @Test("Regenerate also attaches search_memory (without propose_memory)")
    func regenerateAttachesSearch() async throws {
        try await send(
            legs: [(200, hostLeg(text: "Sure.")), (200, hostLeg(text: "Again."))],
            memoryItems: [teslaItem]
        ) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            await run.state.regenerateMessage(messageID: run.message.id, in: run.conversationID)
            let (message, bodies) = try await Self.settle(run, expectedRequests: 2)
            #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
            #expect(message.text == "Again.")
            #expect(bodies.count == 2)
            let regenerated = try #require(bodies.last)
            #expect(Self.toolNames(regenerated).last == MemorySearch.toolName)
            #expect(!Self.toolNames(regenerated).contains(MemoryPropose.toolName), "propose is only attached on a new send")
            #expect(regenerated["tool_choice"] as? String == "auto")
        }
    }

    @Test("Retrying a failed answer also attaches search_memory")
    func retryAttachesSearch() async throws {
        try await send(
            legs: [
                (401, #"{"error":{"message":"invalid api key","type":"invalid_request_error"}}"#),
                (200, hostLeg(text: "Recovered.")),
            ],
            memoryItems: [teslaItem]
        ) { run in
            #expect(run.message.state == .failed, "Precondition: the first send failed")
            await run.state.retryMessage(messageID: run.message.id, in: run.conversationID)
            let (message, bodies) = try await Self.settle(run, expectedRequests: 2)
            #expect(message.state == .delivered, "\(message.errorDetail ?? "")")
            #expect(message.text == "Recovered.")
            let retried = try #require(bodies.last)
            #expect(bodies.count == 2)
            #expect(Self.toolNames(retried).last == MemorySearch.toolName)
            #expect(!Self.toolNames(retried).contains(MemoryPropose.toolName), "propose is only attached on a new send")
        }
    }

    @Test("search_memory is not attached when memory is off")
    func searchNotAttachedWhenMemoryOff() async throws {
        try await send(legs: [(200, hostLeg(text: "Sure."))], memoryItems: [teslaItem], useMemory: false) { run in
            #expect(run.bodies.allSatisfy { !Self.toolNames($0).contains(MemorySearch.toolName) })
        }
    }

    @Test("A connection in the degraded set does not attach search_memory")
    func searchNotAttachedWhenDegraded() async throws {
        try await send(
            legs: [(200, hostLeg(text: "Sure."))],
            prepare: { provider, model, _ in
                ProposeMemoryRuntime.shared.markDegraded(connectionID: provider.id, modelID: model.id)
            },
            memoryItems: [teslaItem]
        ) { run in
            #expect(run.bodies.allSatisfy { !Self.toolNames($0).contains(MemorySearch.toolName) })
            #expect(run.bodies.allSatisfy { !Self.toolNames($0).contains(MemoryPropose.toolName) })
        }
    }

    @Test("A tail leg carrying both propose and search results puts the ids returned by search into memoryIds")
    func tailLegCarriesProposeAndSearchResults() async throws {
        try await send(
            legs: [
                (200, hostLeg(calls: [
                    (MemoryPropose.toolName, "call_p1", proposeArguments("\u{504F}\u{597D}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}")),
                    (MemorySearch.toolName, "call_s1", searchArguments),
                ], usage: (10, 2))),
                (200, hostLeg(text: "Noted.", usage: (14, 3))),
            ],
            memoryItems: [teslaItem]
        ) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            #expect(run.bodies.count == 2)
            #expect(run.message.text == "Noted.")
            #expect(run.message.unhandledToolCalls == nil)
            #expect(run.message.inputTokens == 24)
            #expect(run.message.outputTokens == 5)
            let wire = Self.messages(try #require(run.bodies.last))
            let results = wire.filter { $0["role"] as? String == "tool" }
            #expect(results.map { $0["tool_call_id"] as? String } == ["call_p1", "call_s1"])
            #expect(results.first?["content"] as? String == MemoryPropose.toolResult)
            let searchResult = results.last?["content"] as? String ?? ""
            #expect(searchResult.hasPrefix("<oriveo-recall>\n<note>\(MemorySearch.note)</note>\n"))
            #expect(searchResult.contains(teslaEntry))
            #expect(run.message.memoryItemIds.contains(teslaItem.id))
            let candidates = try await Self.pending(run.state)
            #expect(candidates.map(\.content) == ["\u{504F}\u{597D}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}"])
        }
    }

    @Test("A search in the tail leg is not executed and adds no further leg")
    func tailLegSearchNotRun() async throws {
        try await send(
            legs: [
                (200, hostLeg(calls: [(MemorySearch.toolName, "call_s1", #"{"query":"quantum"}"#)])),
                (200, hostLeg(text: "Done.", calls: [(MemorySearch.toolName, "call_s2", searchArguments)])),
                (200, hostLeg(text: "Should not be requested.")),
            ],
            memoryItems: [teslaItem]
        ) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            #expect(run.bodies.count == 2)
            #expect(run.message.text == "Done.")
            #expect(run.message.unhandledToolCalls == nil)
            let results = Self.messages(run.bodies[1]).filter { $0["role"] as? String == "tool" }
            #expect(results.map { $0["content"] as? String } == [MemorySearch.emptyResult])
            #expect(run.message.memoryItemIds.contains(teslaItem.id) == false, "The tail leg's search did not run, so the item was never given to the model")
        }
    }

    @Test("Thinking with an empty first-leg body: the resend carries no tools, and the search item joins the [D] recall")
    func thinkingEmptyResendCarriesSearchHitsInRecall() async throws {
        try await send(
            legs: [
                (200, hostLeg(reasoning: "Need their purchase.", calls: [(MemorySearch.toolName, "call_s1", searchArguments)], usage: (10, 2))),
                (200, hostLeg(text: "You bought a Tesla.", usage: (11, 4))),
            ],
            memoryItems: [teslaItem]
        ) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            #expect(run.bodies.count == 2)
            #expect(run.message.text == "You bought a Tesla.")
            #expect(!Self.lastUserText(run.bodies[0]).contains(teslaEntry), "Precondition: the first leg's [D] did not recall it")
            let resend = try #require(run.bodies.last)
            #expect(Self.toolNames(resend).isEmpty)
            #expect(resend["tool_choice"] == nil)
            let dynamic = Self.lastUserText(resend)
            #expect(dynamic.contains("<oriveo-recall>"))
            #expect(dynamic.contains(teslaEntry))
            #expect(run.message.inputTokens == 21)
            #expect(run.message.outputTokens == 6)
            #expect(run.message.memoryItemIds.contains(teslaItem.id))
            #expect(!ProposeMemoryRuntime.shared.isDegraded(connectionID: run.provider.id, modelID: run.model.id))
        }
    }

    @Test("Thinking with the first leg ending in body text: the search result is unused and not counted in memoryIds")
    func thinkingWithFirstTextIgnoresSearch() async throws {
        try await send(
            legs: [
                (200, hostLeg(reasoning: "Maybe search.", text: "Here is my answer.",
                              calls: [(MemorySearch.toolName, "call_s1", searchArguments)])),
                (200, hostLeg(text: "Should not be requested.")),
            ],
            memoryItems: [teslaItem]
        ) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            #expect(run.bodies.count == 1)
            #expect(run.message.text == "Here is my answer.")
            #expect(run.message.unhandledToolCalls == nil)
            #expect(run.message.memoryItemIds.contains(teslaItem.id) == false)
        }
    }

    @Test("One extra leg is added when only propose is called")
    func proposeOnlyTriggersTailLeg() async throws {
        try await send(legs: [
            (200, proposeLeg(text: "Let me note that.", callID: "call_p1", usage: (10, 2))),
            (200, proposeLeg(text: "Noted.", usage: (14, 3))),
        ]) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            #expect(run.bodies.count == 2)
            // First-leg body + blank line + tail-leg body.
            #expect(run.message.text == "Let me note that.\n\nNoted.")
            #expect(run.message.unhandledToolCalls == nil, "A propose call does not enter the \"no executor\" card")
            #expect(run.message.inputTokens == 24)
            #expect(run.message.outputTokens == 5)
            #expect(run.message.stopReason == .stop, "stopReason comes from the tail leg")

            let tail = try #require(run.bodies.last)
            // The OpenAI Chat tail leg keeps the existing closing-leg shape: no tools / tool_choice (other protocols keep tools with tool_choice none).
            #expect(tail["tools"] == nil)
            #expect(tail["tool_choice"] == nil)
            let wire = Self.messages(tail)
            let assistant = try #require(wire.dropLast().last)
            #expect(assistant["role"] as? String == "assistant")
            let calls = assistant["tool_calls"] as? [[String: Any]] ?? []
            #expect(calls.map { $0["id"] as? String } == ["call_p1"])
            let result = try #require(wire.last)
            #expect(result["role"] as? String == "tool")
            #expect(result["tool_call_id"] as? String == "call_p1")
            #expect(result["content"] as? String == MemoryPropose.toolResult)

            let candidates = try await Self.pending(run.state)
            #expect(candidates.map(\.content) == ["\u{504F}\u{597D}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}"])
            let userID = run.state.conversation(for: run.conversationID)?.messages.last(where: { $0.role == .user })?.id
            #expect(candidates.first?.source.messageIds == [userID?.uuidString ?? ""])
            let bar = try #require(run.state.memorySuggestions.pending(in: run.conversationID))
            #expect(bar.messageID == run.message.id)
            #expect(bar.candidate == candidates.first)
        }
    }

    @Test("A tail leg calling propose again adds no further leg")
    func tailLegProposeDoesNotChain() async throws {
        try await send(legs: [
            (200, proposeLeg(callID: "call_p1")),
            (200, proposeLeg(text: "Noted.", callID: "call_p2", proposition: "\u{5E38}\u{7528} Swift \u{5199}\u{4EE3}\u{7801}")),
            (200, proposeLeg(text: "Should not be requested.")),
        ]) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            #expect(run.bodies.count == 2)
            #expect(run.message.text == "Noted.")
            #expect(run.message.unhandledToolCalls == nil)
            let candidates = try await Self.pending(run.state)
            #expect(Set(candidates.map(\.content)) == ["\u{504F}\u{597D}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}", "\u{5E38}\u{7528} Swift \u{5199}\u{4EE3}\u{7801}"])
            #expect(run.state.memorySuggestions.pending(in: run.conversationID)?.candidate?.content == "\u{504F}\u{597D}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}")
        }
    }

    @Test("A rejected first-leg tools resends without tools and degrades")
    func firstLegToolsRejectedResendsAndDegrades() async throws {
        try await send(legs: [(400, toolsRejectedBody), (200, proposeLeg(text: "Plain."))]) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            #expect(run.message.text == "Plain.")
            #expect(run.bodies.count == 2)
            #expect(Self.toolNames(run.bodies[0]).contains(MemoryPropose.toolName))
            #expect(run.bodies[1]["tools"] == nil, "The resend carries no tools")
            #expect(ProposeMemoryRuntime.shared.isDegraded(connectionID: run.provider.id, modelID: run.model.id))
            // This turn runs the fallback: the v1 path generates candidates and attaches them under the assistant message.
            let candidates = try await Self.pending(run.state)
            #expect(candidates.count == 1)
            #expect(run.state.memorySuggestions.pending(in: run.conversationID)?.messageID == run.message.id)
        }
    }

    @Test("With thinking and an empty first-leg body, resend once through the normal send without tools")
    func thinkingWithEmptyFirstTextResendsWithoutTools() async throws {
        try await send(
            legs: [
                (200, proposeLeg(reasoning: "The user wants brevity.", callID: "call_p1", usage: (10, 2))),
                (200, proposeLeg(text: "Answer.", usage: (11, 4))),
            ],
            prepare: { provider, model, conversationID in
                RelayWebSwitch.write(true, provider: provider, model: model, conversationID: conversationID)
            }
        ) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            #expect(run.bodies.count == 2)
            #expect(run.message.text == "Answer.")
            let first = try #require(run.bodies.first)
            let resend = try #require(run.bodies.last)
            #expect(Self.toolNames(first).contains(MemoryPropose.toolName))
            #expect(Self.toolNames(resend).isEmpty, "The resend carries no tools")
            #expect(resend["tool_choice"] == nil)
            #expect(Self.messages(resend).allSatisfy { $0["role"] as? String != "tool" && $0["tool_calls"] == nil })
            // Normal send pipeline: the web-search recipe is carried over from the first leg, and the request body has the same shape as the first leg apart from tools.
            #expect(first["web_search_options"] != nil, "Precondition: the first leg carries the web-search snippet")
            #expect(resend["web_search_options"] != nil, "The resend keeps the web-search recipe")
            #expect(Set(resend.keys) == Set(first.keys).subtracting(["tools", "tool_choice"]))
            // The first leg is already billed, so usage is summed over both legs.
            #expect(run.message.inputTokens == 21)
            #expect(run.message.outputTokens == 6)
            #expect(!ProposeMemoryRuntime.shared.isDegraded(connectionID: run.provider.id, modelID: run.model.id))
            let candidates = try await Self.pending(run.state)
            #expect(candidates.map(\.content) == ["\u{504F}\u{597D}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}"])
            #expect(run.state.memorySuggestions.pending(in: run.conversationID)?.messageID == run.message.id)
        }
    }

    @Test("Anthropic adds a leg even without thinking")
    func anthropicWithoutThinkingTriggersTailLeg() async throws {
        let toolInput = proposeArguments("\u{504F}\u{597D}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let first = anthropicProposeSSE([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_p1","type":"message","role":"assistant","model":"claude","content":[],"stop_reason":null,"usage":{"input_tokens":10,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me note that."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_p1","name":"propose_memory","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\#(toolInput)"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":2}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let tail = anthropicProposeSSE([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_p2","type":"message","role":"assistant","model":"claude","content":[],"stop_reason":null,"usage":{"input_tokens":14,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Noted."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":3}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        try await send(
            legs: [(200, first), (200, tail)],
            provider: makeToolLoopRelayProvider(transport: .anthropicMessages)
        ) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            #expect(run.bodies.count == 2, "Anthropic without thinking that only calls propose also gets an extra leg")
            #expect(run.message.text == "Let me note that.\n\nNoted.")
            #expect(run.message.unhandledToolCalls == nil)
            #expect(Self.anthropicToolNames(run.bodies[0]).last == MemoryPropose.toolName)
            let wire = Self.messages(run.bodies[1])
            let result = try #require(wire.last)
            let blocks = result["content"] as? [[String: Any]] ?? []
            #expect(blocks.first?["type"] as? String == "tool_result")
            #expect(blocks.first?["tool_use_id"] as? String == "toolu_p1")
            let candidates = try await Self.pending(run.state)
            #expect(candidates.map(\.content) == ["\u{504F}\u{597D}\u{7B80}\u{6D01}\u{7684}\u{56DE}\u{7B54}"])
            #expect(run.state.memorySuggestions.pending(in: run.conversationID)?.messageID == run.message.id)
        }
    }

    private static let geminiPlainLeg = [
        #"{"candidates":[{"content":{"parts":[{"text":"Sure."}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2,"totalTokenCount":12}}"#,
    ].map { "data: \($0)\n\n" }.joined()

    @Test("Gemini with web search on takes the fallback")
    func geminiWithWebSearchFallsBack() async throws {
        try await send(
            legs: [(200, Self.geminiPlainLeg)],
            provider: makeToolLoopRelayProvider(transport: .geminiGenerateContent),
            prepare: { provider, model, conversationID in
                RelayWebSwitch.write(true, provider: provider, model: model, conversationID: conversationID)
            }
        ) { run in
            #expect(!run.bodies.isEmpty)
            #expect(run.bodies.allSatisfy { !Self.geminiFunctionNames($0).contains(MemoryPropose.toolName) })
            // Fallback = the v1 path: an explicit "remember ..." generates a candidate directly.
            let candidates = try await Self.pending(run.state)
            #expect(candidates.count == 1)
            #expect(run.state.memorySuggestions.pending(in: run.conversationID)?.messageID == run.message.id)
        }
    }

    @Test("A Gemini relay whose web search is actually off is not misjudged as fallback")
    func geminiRelayWithWebActuallyOffKeepsTool() async throws {
        // The composer selection has web search on, but the relay's web-search switch is off: no search is sent, and propose can still be attached.
        try await send(
            legs: [(200, Self.geminiPlainLeg)],
            provider: makeToolLoopRelayProvider(transport: .geminiGenerateContent),
            capabilitySelection: ChatCapabilitySelection(reasoningMode: .automatic, webSearchEnabled: true)
        ) { run in
            #expect(run.message.state == .delivered, "\(run.message.errorDetail ?? "")")
            let first = try #require(run.bodies.first)
            #expect(Self.geminiFunctionNames(first).last == MemoryPropose.toolName)
            #expect(run.state.memorySuggestions.pending(in: run.conversationID) == nil, "Tool mode does not run the v1 fallback")
        }
    }
}

private func anthropicProposeSSE(_ frames: [(event: String, data: String)]) -> String {
    frames.map { "event: \($0.event)\ndata: \($0.data)\n\n" }.joined()
}
