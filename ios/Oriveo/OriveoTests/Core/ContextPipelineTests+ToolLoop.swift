import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// The MCP tool loop gets a single system message produced by the assembler (purpose toolLoopLeg),
/// the host safety note is its last section, and the system of every leg in the loop is byte-identical. Assertions read the request bodies the production leg runner actually emits
/// (`sendMessage` -> `runMcpToolLoop` -> ScriptedModelURLProtocol).

private let toolLoopServerID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A2")!
private let toolLoopOutbound = "mcp_weather_get_weather"
private let toolLoopMemoryText = "The user prefers green tea."

private func toolLoopSchema() -> JSONValue {
    .object(JSONObject([
        ("type", .string("object")),
        ("properties", .object(JSONObject([
            ("city", .object(JSONObject([("type", .string("string"))]))),
        ]))),
        ("required", .array([.string("city")])),
    ]))
}

private func seedToolLoopServer(_ database: McpTestDatabase, conversation: UUID) throws {
    let snapshot = McpToolSnapshot(
        serverId: toolLoopServerID,
        toolName: "get_weather",
        title: "Get weather",
        description: "Weather lookup",
        inputSchema: toolLoopSchema(),
        annotations: .object(JSONObject([("readOnlyHint", .bool(true))])),
        contentHash: sha256Hex("tool-loop:get_weather"),
        readOnly: true,
        pendingReview: false,
        oversized: false
    )
    try database.store.addServer(
        McpServerAddition(
            id: toolLoopServerID, name: "Weather", url: "https://mcp.example.com/mcp", authKind: .auto,
            localOnly: false, iconURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshots: [snapshot], permissions: [:],
            connectionState: McpConnectionState(serverId: toolLoopServerID, status: .connected, generation: .stateless)
        ),
        maxServers: 20
    )
    try database.store.setServerEnabled(true, conversationId: conversation, serverId: toolLoopServerID)
}

private func toolLoopSSE(_ frames: [[String: Any]]) -> String {
    frames.map { frame in
        let data = (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }.joined() + "data: [DONE]\n\n"
}

private func toolLoopCallLeg() -> String {
    toolLoopSSE([
        ["choices": [["delta": ["tool_calls": [
            ["index": 0, "id": "call_tool_loop_1", "type": "function",
             "function": ["name": toolLoopOutbound, "arguments": #"{"city":"Melbourne"}"#]],
        ]]]]],
        ["choices": [["delta": [String: Any](), "finish_reason": "tool_calls"]]],
    ])
}

private func toolLoopTextLeg(_ text: String) -> String {
    toolLoopSSE([
        ["choices": [["delta": ["content": text]]]],
        ["choices": [["delta": [String: Any](), "finish_reason": "stop"]]],
    ])
}

/// The first-leg system when a test drives the loop directly: the same assembler as production (purpose toolLoopLeg), with the skill "Be brief." first and the safety note last.
/// With a nil skillPrompt the system is only the safety note (matching the system of the shared round-trip fixture provider-toolcall/roundtrip).
func toolLoopPlanSystem(safety: String, skillPrompt: String? = "Be brief.") -> String {
    let (_, model) = makeToolLoopRelayProvider(transport: .openaiChatCompletions)
    let plan = ContextAssembler.assemble(ContextAssembleInput(
        purpose: .toolLoopLeg,
        window: ChatRequestBuilder.contextWindowInput(providerKind: .relay, model: model),
        conversation: ContextConversation(id: "tool-loop", useMemory: false, skillPrompt: skillPrompt),
        toolSafety: safety,
        history: [],
        current: "Question"
    ))
    return plan.system ?? ""
}

/// The first-leg transport when a test drives the loop directly: the same toolLoopLeg plan projected by production, with system placed into the messages only by toolLoopMessages.
func toolLoopPlanTransport(safety: String, skillPrompt: String? = "Be brief.") -> TransportInput {
    let (_, model) = makeToolLoopRelayProvider(transport: .openaiChatCompletions)
    let plan = ContextAssembler.assemble(ContextAssembleInput(
        purpose: .toolLoopLeg,
        window: ChatRequestBuilder.contextWindowInput(providerKind: .relay, model: model),
        conversation: ContextConversation(id: "tool-loop", useMemory: false, skillPrompt: skillPrompt),
        toolSafety: safety,
        history: [],
        current: "Question"
    ))
    return PlannedChatRequest.projecting(plan, messages: [:], attachments: [:]).transportInput(ChatRequestOptions())
}

extension ContextPipelineTests {

    /// With the conversation switch on, the fixture's one global fact memory item goes into the `<oriveo-memory>` envelope.
    private static var toolLoopMemorySystem: String {
        let note = ContextAssembler.envelopeNotes["oriveo-memory"] ?? ""
        return "<oriveo-memory>\n<note>\(note)</note>\n<entry>\(toolLoopMemoryText)</entry>\n</oriveo-memory>"
    }

    /// The plan.system of toolLoopLeg: the conversation prefix followed by the host safety note.
    private static func toolLoopSystem(safety: String) -> String {
        toolLoopMemorySystem + "\n\n" + safety.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func toolLoopSystems(_ body: [String: Any]) -> [String] {
        (body["messages"] as? [[String: Any]] ?? []).compactMap { message in
            message["role"] as? String == "system" ? message["content"] as? String : nil
        }
    }

    private static func toolLoopWireText(_ body: [String: Any]) -> [(role: String, text: String)] {
        (body["messages"] as? [[String: Any]] ?? []).map { message in
            let text: String
            if let string = message["content"] as? String {
                text = string
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
            } else {
                text = ""
            }
            return (message["role"] as? String ?? "", text)
        }
    }

    /// Runs one tool loop starting from `sendMessage` and returns the model-leg request bodies (in the order sent).
    private func runToolLoop(
        modelLegs: [(Int, String)],
        withMcp: Bool,
        configure: (AppState) -> Void = { _ in }
    ) async throws -> (message: ChatMessage, bodies: [[String: Any]]) {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        if withMcp {
            try McpScriptedURLProtocol.enqueue([
                McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
                McpClientFixture.stub("protocol/stateless/tools-call.response.json"),
            ])
        }
        ScriptedModelURLProtocol.reset(modelLegs)
        let store = database.store
        let state = AppState(
            seedDemoData: true,
            providerSession: ScriptedModelURLProtocol.session(),
            toolCallMemory: try makeToolLoopMemoryStore(),
            mcpServerDirectory: McpServerDirectory(
                credentialStore: McpCredentialStore(storage: InMemoryMcpCredentialStorage()),
                openStore: { _ in store }
            )
        )
        try await Self.seedMemory(state, [
            Self.memoryItem("mem-tool-loop", .fact, toolLoopMemoryText, createdAt: "2026-01-01T00:00:00Z"),
        ])
        let (relay, model) = makeToolLoopRelayProvider(transport: .openaiChatCompletions)
        let conversationID = UUID()
        if withMcp {
            try seedToolLoopServer(database, conversation: conversationID)
        }
        state.providers = [relay]
        state.conversations = [TestFactories.makeConversation(
            id: conversationID, providerID: relay.id, modelID: model.id, messages: []
        )]
        state.chatManager.debugUseMcpClientFactoryForTesting { McpClient(endpoint: $0, session: McpScriptedURLProtocol.session()) }
        configure(state)

        let sent = await state.chatManager.sendMessage(
            "Plan and weather in Melbourne?", in: conversationID
        )
        #expect(sent != nil)
        var assistant: ChatMessage?
        for _ in 0..<160 {
            assistant = state.conversation(for: conversationID)?.messages.last(where: { $0.role == .assistant })
            if let assistant, assistant.state != .generating { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let message = try #require(assistant)
        return (message, ScriptedModelURLProtocol.snapshot().map(\.body))
    }

    @Test func tool_loop_single_system_with_safety() async throws {
        await MetadataClient.shared.resetForTesting()
        // The safety note contains only the MCP section, as the last section of plan.system.
        let mcpOnly = try await runToolLoop(
            modelLegs: [(200, toolLoopCallLeg()), (200, toolLoopTextLeg("Done."))],
            withMcp: true
        )
        #expect(mcpOnly.message.state == .delivered, "\(mcpOnly.message.state) \(mcpOnly.message.errorDetail ?? "")")
        let mcpFirst = try #require(mcpOnly.bodies.first)
        #expect(Self.toolLoopSystems(mcpFirst) == [Self.toolLoopSystem(safety: McpSafetyPrompt.text)])
        #expect(Self.toolLoopWireText(mcpFirst).first?.role == "system", "system comes first")
    }

    /// The system of the first MCP leg comes only from transport.toolLoopMessages:
    /// the first message is the plan.system of toolLoopLeg, and it is the only system message in the whole request.
    @Test func tool_loop_messages_come_from_transport() async throws {
        await MetadataClient.shared.resetForTesting()
        let run = try await runToolLoop(
            modelLegs: [(200, toolLoopCallLeg()), (200, toolLoopTextLeg("Done."))],
            withMcp: true
        )
        let first = try #require(run.bodies.first)
        let wire = Self.toolLoopWireText(first)
        #expect(wire.first?.role == "system", "system comes first")
        #expect(wire.first?.text == Self.toolLoopSystem(safety: McpSafetyPrompt.text), "the first system message == toolLoopLeg plan.system")
        #expect(wire.filter { $0.role == "system" }.count == 1, "there is only one system message")
    }

    @Test func tool_loop_legs_same_system() async throws {
        await MetadataClient.shared.resetForTesting()
        let run = try await runToolLoop(
            modelLegs: [(200, toolLoopCallLeg()), (200, toolLoopTextLeg("Both done."))],
            withMcp: true
        )
        #expect(run.message.text == "Both done.")
        #expect(run.bodies.count == 2, "tool leg + closing leg")
        let systems = run.bodies.map(Self.toolLoopSystems)
        #expect(systems.allSatisfy { $0.count == 1 }, "each leg has exactly one system message: \(systems.map(\.count))")
        let first = try #require(systems.first?.first)
        #expect(systems.allSatisfy { $0.first == first }, "the system of every leg is byte-identical")
        // Host notices (the hints after tool results) are still user / tool messages and stay out of system.
        let last = try #require(run.bodies.last)
        #expect(Self.toolLoopWireText(last).dropFirst().allSatisfy { $0.role != "system" })
    }
}
