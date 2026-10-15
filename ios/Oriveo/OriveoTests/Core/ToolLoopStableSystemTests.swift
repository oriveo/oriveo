import Foundation
import Testing
@testable import Oriveo

/// Mid-loop tool loop notices (step limit etc.) never go into system. The system / instructions /
/// systemInstruction encoded for every leg must be byte-identical to the first leg's; the notice shows up
/// as plain user text after all of the leg's tool results.
@Suite("ToolCallLoop stable system")
struct ToolLoopStableSystemTests {
    private static let systemPrompt = "You are a stable system prompt."

    @Test("Anthropic: top-level system is byte-identical across legs; the notice shares a user turn with tool_result")
    func anthropicKeepsSystemStable() async throws {
        let adapter = AnthropicToolAdapter()
        let (requests, notice) = try await Self.runStepLimitedLoop(adapter: adapter)
        let conversations = try requests.map { try adapter.encodeConversation($0.messages) }
        try Self.expectStableSystem(conversations.map(\.system))

        for conversation in conversations {
            let messages = try #require(conversation.messages as? [[String: Any]])
            let roles = messages.compactMap { $0["role"] as? String }
            #expect(!zip(roles, roles.dropFirst()).contains { $0 == $1 }, "no adjacent turns with the same role")
        }
        let finalMessages = try #require(conversations.last?.messages as? [[String: Any]])
        let lastTurn = try #require(finalMessages.last)
        #expect(lastTurn["role"] as? String == "user")
        let blocks = try #require(lastTurn["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["tool_result", "text"])
        #expect(blocks.last?["text"] as? String == notice)
    }

    @Test("Gemini: systemInstruction is byte-identical across legs; the notice shares a user content with functionResponse")
    func geminiKeepsSystemStable() async throws {
        let adapter = GeminiToolAdapter()
        let (requests, notice) = try await Self.runStepLimitedLoop(adapter: adapter)
        let conversations = try requests.map { try adapter.encodeConversation($0.messages) }
        try Self.expectStableSystem(conversations.map(\.system))

        for conversation in conversations {
            let contents = try #require(conversation.messages as? [[String: Any]])
            let roles = contents.compactMap { $0["role"] as? String }
            #expect(!zip(roles, roles.dropFirst()).contains { $0 == $1 }, "no adjacent contents with the same role")
        }
        let finalContents = try #require(conversations.last?.messages as? [[String: Any]])
        let lastTurn = try #require(finalContents.last)
        #expect(lastTurn["role"] as? String == "user")
        let parts = try #require(lastTurn["parts"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts.first?["functionResponse"] != nil)
        #expect(parts.last?["text"] as? String == notice)
    }

    @Test("Responses: instructions are byte-identical across legs; the notice is a user item after function_call_output")
    func responsesKeepsInstructionsStable() async throws {
        let adapter = OpenAIResponsesToolAdapter()
        let (requests, notice) = try await Self.runStepLimitedLoop(adapter: adapter)
        let conversations = try requests.map { try adapter.encodeConversation($0.messages) }
        try Self.expectStableSystem(conversations.map(\.system))

        for conversation in conversations {
            let input = try #require(conversation.messages as? [[String: Any]])
            #expect(!input.contains { $0["role"] as? String == "system" }, "input contains no system items")
        }
        let input = try #require(conversations.last?.messages as? [[String: Any]])
        #expect(input.count >= 2)
        #expect(input[input.count - 2]["type"] as? String == "function_call_output")
        let last = try #require(input.last)
        #expect(last["role"] as? String == "user")
        let content = try #require(last["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "input_text")
        #expect(content.first?["text"] as? String == notice)
    }

    @Test("Chat: the system message is byte-identical across legs and only leads; the notice is a user message after the tool message")
    func chatKeepsSystemStable() async throws {
        let adapter = OpenAIChatToolAdapter()
        let (requests, notice) = try await Self.runStepLimitedLoop(adapter: adapter)
        let conversations = try requests.map { try adapter.encodeConversation($0.messages) }

        var leadingSystems: [String?] = []
        for conversation in conversations {
            #expect(conversation.system == nil)
            let messages = try #require(conversation.messages as? [[String: Any]])
            let systemIndices = messages.indices.filter { messages[$0]["role"] as? String == "system" }
            #expect(systemIndices == [0], "system only at the start")
            let data = try JSONSerialization.data(withJSONObject: messages[0], options: [.sortedKeys])
            leadingSystems.append(String(decoding: data, as: UTF8.self))
        }
        try Self.expectStableSystem(leadingSystems)

        let messages = try #require(conversations.last?.messages as? [[String: Any]])
        #expect(messages.count >= 2)
        #expect(messages[messages.count - 2]["role"] as? String == "tool")
        let last = try #require(messages.last)
        #expect(last["role"] as? String == "user")
        #expect(last["content"] as? String == notice)
    }

    // MARK: - Fixtures

    /// Every leg proposes one echo call; maxSteps = 2 -> the step limit triggers after the second leg runs,
    /// followed by one tool-less synthesis leg.
    private static func runStepLimitedLoop(
        adapter: any ToolProtocolAdapter
    ) async throws -> (requests: [ToolLoopLegRequest], notice: String) {
        let toolLeg: (String) -> [ToolLoopLegEvent] = { id in
            [
                .textDelta("Checking."),
                .toolCallDeltas([
                    ToolLoopToolCallDelta(index: 0, id: id, type: "function", name: "echo", arguments: "{}"),
                ]),
            ]
        }
        let runner = StableSystemScriptedRunner([
            toolLeg("call_1"),
            toolLeg("call_2"),
            [.textDelta("Final answer.")],
        ])
        let prompts = ToolCallLoop.Prompts()
        let loop = ToolCallLoop(
            registry: ToolRegistry(entries: [StableSystemEchoEntry()]),
            legRunner: runner,
            adapter: adapter,
            limits: ToolCallLoop.Limits(maxSteps: 2),
            prompts: prompts
        )
        let result = try await loop.run(messages: [
            ToolLoopMessage(role: "system", content: systemPrompt),
            ToolLoopMessage(role: "user", content: "Find it"),
        ])
        #expect(result.stepLimitReached)
        let requests = runner.requests()
        #expect(requests.count == 3)
        #expect(requests.last?.toolChoice == ToolLoopToolChoice.none)
        // Neutral history: no system message after the first one
        for request in requests {
            #expect(request.messages.dropFirst().allSatisfy { $0.role != "system" })
        }
        return (requests, prompts.stepLimitReached)
    }

    private static func expectStableSystem(_ systems: [String?]) throws {
        #expect(systems.count == 3)
        let first = try #require(systems.first ?? nil)
        #expect(first.contains(systemPrompt))
        for system in systems {
            #expect(system.map { Data($0.utf8) } == Data(first.utf8), "every leg's system is byte-identical to the first leg's")
        }
    }
}

private final class StableSystemScriptedRunner: ToolLoopLegRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var legs: [[ToolLoopLegEvent]]
    private var recorded: [ToolLoopLegRequest] = []

    init(_ legs: [[ToolLoopLegEvent]]) {
        self.legs = legs
    }

    func run(request: ToolLoopLegRequest) -> AsyncThrowingStream<ToolLoopLegEvent, Error> {
        let events = lock.withLock {
            recorded.append(request)
            return legs.isEmpty ? [] : legs.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func requests() -> [ToolLoopLegRequest] {
        lock.withLock { recorded }
    }
}

private struct StableSystemEchoEntry: ToolRegistryEntry {
    var name: String { "echo" }
    var scope: ToolScope { .mcp }
    var definition: ToolLoopToolDefinition? {
        ToolLoopToolDefinition(function: .init(name: "echo", description: "Echo", parameters: .object([:])))
    }

    func execute(_ call: ToolLoopToolCall, context: ToolExecutionContext) async throws -> ToolExecutionOutcome {
        ToolExecutionOutcome(content: #"{"ok":true}"#)
    }
}
