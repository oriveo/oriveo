import Foundation
import GRDB
import Testing
import UIKit
@testable import Oriveo

// MARK: - Tool steps on a message
//
// Producer assertions all come from the production path: `sendMessage` -> `ChatManager.runMcpToolLoop` -> `McpToolExecutor.onStep`
// -> `recordMcpToolStep` -> `toolSteps` on the message, then through `RecordMappers` and the Codable envelope to see what is actually stored with the message.
// Lives on `McpToolBridgeTests` to share its `.serialized` trait: both use process-wide replay protocols.

private let stepServerID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
private let stepOutbound = "mcp_weather_get_weather"
private let allowedStepKeys: Set<String> = [
    "id", "scope", "serverId", "serverName", "toolName", "title", "argsSummary", "status", "errorCode", "step", "durationMs",
]

private func stepSchema() -> JSONValue {
    .object(JSONObject([
        ("type", .string("object")),
        ("properties", .object(JSONObject([
            ("city", .object(JSONObject([("type", .string("string"))]))),
            ("notes", .object(JSONObject([("type", .string("object"))]))),
        ]))),
        ("required", .array([.string("city")])),
    ]))
}

private func seedStepServer(_ database: McpTestDatabase, conversation: UUID, readOnly: Bool = true) throws {
    let snapshot = McpToolSnapshot(
        serverId: stepServerID,
        toolName: "get_weather",
        title: "Get weather",
        description: "Weather lookup",
        inputSchema: stepSchema(),
        annotations: .object(JSONObject([("readOnlyHint", .bool(readOnly))])),
        contentHash: sha256Hex("step:get_weather"),
        readOnly: readOnly,
        pendingReview: false,
        oversized: false
    )
    try database.store.addServer(
        McpServerAddition(
            id: stepServerID, name: "Weather", url: "https://mcp.example.com/mcp", authKind: .auto,
            localOnly: false, iconURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshots: [snapshot], permissions: [:],
            connectionState: McpConnectionState(serverId: stepServerID, status: .connected, generation: .stateless)
        ),
        maxServers: 20
    )
    try database.store.setServerEnabled(true, conversationId: conversation, serverId: stepServerID)
}

private func stepToolLeg(arguments: String) -> String {
    let frames: [[String: Any]] = [
        ["choices": [["delta": ["tool_calls": [
            ["index": 0, "id": "call_step_1", "type": "function", "function": ["name": stepOutbound, "arguments": arguments]],
        ]]]]],
        ["choices": [["delta": [String: Any](), "finish_reason": "tool_calls"]]],
    ]
    return frames.map { frame in
        let data = (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }.joined() + "data: [DONE]\n\n"
}

private func stepTextLeg(_ text: String) -> String {
    [
        #"{"choices":[{"delta":{"content":"\#(text)"}}]}"#,
        #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
    ].map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
}

private func toolErrorStub(text: String) throws -> McpScriptedURLProtocol.Stub {
    let escaped = JSONValue.encodeString(text)
    return try McpClientFixture.stub(json: try JSONValue(parsing: """
    {"status":200,"headers":{"Content-Type":"application/json"},"body":{"jsonrpc":"2.0","id":3,
     "result":{"resultType":"complete","content":[{"type":"text","text":\(escaped)}],"isError":true}}}
    """))
}

private func documentText(_ value: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        .map { String(decoding: $0, as: UTF8.self) } ?? ""
}

/// A gate that runs a check on the main thread when asked, then answers: used to observe production state at the moment of waiting for confirmation.
private final class InspectingGate: McpConfirmationGate, @unchecked Sendable {
    private let onAsk: @MainActor (McpConfirmationRequest) -> McpConfirmationChoice
    init(_ onAsk: @escaping @MainActor (McpConfirmationRequest) -> McpConfirmationChoice) { self.onAsk = onAsk }
    func requestConfirmation(_ request: McpConfirmationRequest) async throws -> McpConfirmationChoice {
        await onAsk(request)
    }
}

/// An auth-expired gate that runs a check on the main thread when asked, then answers.
private final class InspectingReauthGate: McpReauthorizationGate, @unchecked Sendable {
    private let onAsk: @MainActor (McpReauthorizationRequest) -> McpReauthorizationChoice
    init(_ onAsk: @escaping @MainActor (McpReauthorizationRequest) -> McpReauthorizationChoice) { self.onAsk = onAsk }
    func requestReauthorization(_ request: McpReauthorizationRequest) async throws -> McpReauthorizationChoice {
        await onAsk(request)
    }
}

private func unauthorizedStub() -> McpScriptedURLProtocol.Stub {
    McpScriptedURLProtocol.Stub(status: 401, headers: ["WWW-Authenticate": "Bearer"])
}

/// Runs the whole production path starting at `sendMessage` and returns the final assistant message.
@MainActor
private func sendThroughChatManager(
    database: McpTestDatabase,
    modelLegs: [(Int, String)],
    readOnly: Bool = true,
    directory: McpServerDirectory? = nil,
    configure: (AppState, UUID) -> Void = { _, _ in }
) async throws -> (message: ChatMessage, state: AppState, conversationID: UUID) {
    await MetadataClient.shared.resetForTesting()
    ScriptedModelURLProtocol.reset(modelLegs)
    let store = database.store
    let state = AppState(
        seedDemoData: true,
        providerSession: ScriptedModelURLProtocol.session(),
        toolCallMemory: try makeToolLoopMemoryStore(),
        mcpServerDirectory: directory ?? McpServerDirectory(
            credentialStore: McpCredentialStore(storage: InMemoryMcpCredentialStorage()),
            openStore: { _ in store }
        )
    )
    let (relay, model) = makeToolLoopRelayProvider(transport: .openaiChatCompletions)
    let conversationID = UUID()
    try seedStepServer(database, conversation: conversationID, readOnly: readOnly)
    state.providers = [relay]
    state.conversations = [TestFactories.makeConversation(id: conversationID, providerID: relay.id, modelID: model.id, messages: [])]
    state.chatManager.debugUseMcpClientFactoryForTesting { McpClient(endpoint: $0, session: McpScriptedURLProtocol.session()) }
    configure(state, conversationID)

    let sent = await state.chatManager.sendMessage("Weather in Melbourne?", in: conversationID)
    #expect(sent != nil)
    var assistant: ChatMessage?
    for _ in 0..<100 {
        assistant = state.conversation(for: conversationID)?.messages.last(where: { $0.role == .assistant })
        if let assistant, assistant.state != .generating { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    return (try #require(assistant), state, conversationID)
}

extension McpToolBridgeTests {

    @Test("toolSteps: the production path writes a step onto the message; what is stored with the message and what goes into a backup hold only the summary, while raw arguments and results stay in the payload table")
    @MainActor
    func toolStepsAreRecordedAndStoredWithoutPayload() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            McpClientFixture.stub("protocol/stateless/tools-call.response.json"),
        ])
        let arguments = #"{"city":"Melbourne","notes":{"secretKey":"raw-argument-only-on-device"}}"#

        let (message, _, _) = try await sendThroughChatManager(
            database: database,
            modelLegs: [(200, stepToolLeg(arguments: arguments)), (200, stepTextLeg("It is 72F."))]
        )

        #expect(message.state == .delivered)
        #expect(message.text == "It is 72F.")
        let steps = try #require(message.toolSteps)
        #expect(steps.count == 1)
        let step = try #require(steps.first)
        #expect(step.scope == "mcp")
        #expect(step.serverId == stepServerID.uuidString.lowercased())
        #expect(step.serverName == "Weather")
        #expect(step.toolName == "get_weather")
        #expect(step.title == "Get weather")
        #expect(step.argsSummary == "Melbourne")
        #expect(step.status == .done)
        #expect(step.errorCode == nil)
        #expect(step.step == 1)
        #expect(step.durationMs != nil)

        // On-device step payload: the raw arguments and the start of the result are both there.
        let payload = try #require(try database.store.fetchStepPayload(messageID: message.id, stepID: step.id))
        #expect(payload.arguments?.contains("raw-argument-only-on-device") == true)
        #expect(payload.resultPrefix?.contains("Partly cloudy") == true)

        // What is stored with the message: the database column and the Codable (backup) envelope.
        let column = try #require(RecordMappers.encodeToolSteps(message.toolSteps))
        let written = try #require(try JSONSerialization.jsonObject(with: Data(column.utf8)) as? [[String: Any]])
        #expect(written.count == 1)
        #expect(Set(written[0].keys).isSubset(of: allowedStepKeys), "extra keys: \(Set(written[0].keys).subtracting(allowedStepKeys))")
        #expect(written[0]["status"] as? String == "done")
        #expect(written[0]["argsSummary"] as? String == "Melbourne")
        let envelope = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        #expect(envelope.contains("\"toolSteps\""))
        for secret in ["raw-argument-only-on-device", "secretKey", "Partly cloudy", "72°F"] {
            #expect(!column.contains(secret), "the stored steps must not contain \(secret)")
            #expect(!envelope.contains(secret), "the backup envelope must not contain \(secret)")
        }

        // Round trip: both read back the same summary.
        #expect(RecordMappers.decodeToolSteps(column, messageState: message.state) == steps)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: Data(envelope.utf8)).toolSteps == steps)
    }

    @Test("toolSteps: a tool error gives status failed with the closed-set code tool_error; the server's error text goes only to the payload table, never to the message or to the model")
    @MainActor
    func failedStepKeepsServerTextOnDeviceOnly() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        let serverText = "Upstream said: quota exhausted for tenant acme-internal"
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            toolErrorStub(text: serverText),
        ])

        let (message, _, _) = try await sendThroughChatManager(
            database: database,
            modelLegs: [(200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#)), (200, stepTextLeg("Could not check."))]
        )

        #expect(message.state == .delivered, "one failing tool does not abort the whole answer")
        let step = try #require(message.toolSteps?.first)
        #expect(step.status == .failed)
        #expect(step.errorCode == "tool_error")
        let payload = try #require(try database.store.fetchStepPayload(messageID: message.id, stepID: step.id))
        #expect(payload.resultPrefix == serverText)
        #expect(payload.arguments?.contains("Melbourne") == true, "writing the result at the end must not wipe the arguments written at the start")

        let column = try #require(RecordMappers.encodeToolSteps(message.toolSteps))
        #expect(!column.contains("acme-internal"))
        #expect(column.contains("tool_error"))
        let modelSaw = ScriptedModelURLProtocol.snapshot().last.map { documentText($0.body) } ?? ""
        #expect(!modelSaw.contains("acme-internal"), "only the closed-set code is fed back to the model")
    }

    @Test("after a reload, a step still running on a message that is no longer generating becomes interrupted; a generating message is left as is")
    @MainActor
    func runningStepsLoadAsInterrupted() throws {
        let uid = "mcp-toolsteps-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: AppSessionStore.userDir(for: uid), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid)) }
        let pool = try DatabasePool(
            path: AppSessionStore.databasePath(for: uid).path, configuration: DatabaseSchema.makeConfiguration()
        )
        let files = AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
        try DatabaseSchema.makeMigrator(attachmentFileStore: files).migrate(pool)
        let store = ConversationStore(dbPool: pool, attachmentFileStore: files)

        func step(_ id: String, _ status: McpToolStep.Status, _ number: Int) -> McpToolStep {
            McpToolStep(
                id: id, serverId: stepServerID.uuidString.lowercased(), serverName: "Weather",
                toolName: "get_weather", title: "Get weather", argsSummary: "Melbourne", status: status, step: number
            )
        }
        let steps = [step("1:a", .done, 1), step("2:b", .running, 2)]
        var killed = TestFactories.makeMessage(role: .assistant, text: "partial", estimatedCost: 0)
        killed.state = .interrupted
        killed.toolSteps = steps
        var live = TestFactories.makeMessage(role: .assistant, text: "", estimatedCost: 0)
        live.state = .generating
        live.toolSteps = steps
        let conversation = TestFactories.makeConversation(
            title: "Tool steps",
            messages: [TestFactories.makeMessage(role: .user, text: "q", estimatedCost: 0), killed, live]
        )

        try store.upsertConversation(conversation)
        let stored = try #require(try store.fetchConversationThread(id: conversation.id))

        let restoredKilled = try #require(stored.messages.first { $0.id == killed.id }?.toolSteps)
        #expect(restoredKilled.map(\.status) == [.done, .interrupted])
        #expect(restoredKilled[1].errorCode == "interrupted")
        #expect(restoredKilled[0] == steps[0], "a finished step reads back unchanged")
        let restoredLive = try #require(stored.messages.first { $0.id == live.id }?.toolSteps)
        #expect(restoredLive == steps)

        // Clearing (the retry path) must reach the store as well.
        var cleared = conversation
        cleared.messages[1].toolSteps = nil
        try store.upsertConversation(cleared)
        let clearedStored = try #require(try store.fetchConversationThread(id: conversation.id))
        #expect(clearedStored.messages.first { $0.id == killed.id }?.toolSteps == nil)
    }

    @Test("reading a backup: a `running` step reads as interrupted; a list holding an unknown status degrades to no steps; an older envelope without toolSteps reads normally")
    @MainActor
    func backupStepsNeverStayRunning() throws {
        func decode(steps: [[String: Any]]?) throws -> ChatMessage {
            let base = TestFactories.makeMessage(role: .assistant, text: "answer", estimatedCost: 0)
            var envelope = try #require(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any]
            )
            envelope["toolSteps"] = steps
            return try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: envelope))
        }
        let running: [String: Any] = [
            "id": "1:a", "scope": "mcp", "serverId": "s1", "serverName": "Weather", "toolName": "get_weather",
            "title": "Get weather", "argsSummary": "Melbourne", "status": "running", "step": 1,
        ]
        let needsAuth: [String: Any] = [
            "id": "2:b", "scope": "mcp", "serverId": "s1", "serverName": "Weather", "toolName": "get_time",
            "title": "", "argsSummary": "", "status": "needsAuth", "errorCode": "needs_auth", "step": 2, "durationMs": 12,
        ]
        var unknown = needsAuth
        unknown["status"] = "teleported"

        let steps = try #require(try decode(steps: [running, needsAuth]).toolSteps)
        #expect(steps.map(\.id) == ["1:a", "2:b"])
        #expect(steps[0].status == .interrupted && steps[0].errorCode == "interrupted")
        #expect(steps[1].status == .needsAuth && steps[1].errorCode == "needs_auth" && steps[1].durationMs == 12)
        #expect(steps[1].displayTitle == "get_time", "falls back to the original tool name when the server gives no title")

        let malformed = try decode(steps: [running, unknown])
        #expect(malformed.toolSteps == nil, "a list that cannot be read costs the steps, not the message")
        #expect(malformed.text == "answer")
        #expect(try decode(steps: nil).toolSteps == nil)
    }

    @Test("late callback: once the send has settled, it may only move its own step from running to a terminal state and never adds a step")
    @MainActor
    func lateStepUpdatesOnlyCloseRunningSteps() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            McpClientFixture.stub("protocol/stateless/tools-call.response.json"),
        ])
        let (message, state, conversationID) = try await sendThroughChatManager(
            database: database,
            modelLegs: [(200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#)), (200, stepTextLeg("Done."))]
        )
        let existing = try #require(message.toolSteps?.first)
        let staleTask = UUID()
        var late = McpToolStepUpdate(
            id: "9:late", serverId: stepServerID, serverName: "Weather", toolName: "get_weather", title: "Get weather",
            argsSummary: "", status: .done, step: 9
        )
        await state.chatManager.recordMcpToolStep(
            late, conversationID: conversationID, messageID: message.id, sendTaskID: staleTask, uid: "u"
        )
        late.id = existing.id
        late.status = .failed
        await state.chatManager.recordMcpToolStep(
            late, conversationID: conversationID, messageID: message.id, sendTaskID: staleTask, uid: "u"
        )
        let after = state.conversation(for: conversationID)?.messages.first { $0.id == message.id }?.toolSteps
        #expect(after == [existing], "a step already in a terminal state is not rewritten by a late callback, and no step is added")
    }

    @Test("while waiting for confirmation the step is already running and the activity is mcp_tool; after a denial the step is denied, the activity is cleared and the server received no call")
    @MainActor
    func confirmationWaitShowsRunningStepAndActivity() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        var seenWhileWaiting: (status: McpToolStep.Status?, activity: StreamActivity?, changesData: Bool)?

        let (message, state, conversationID) = try await sendThroughChatManager(
            database: database,
            modelLegs: [(200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#)), (200, stepTextLeg("Okay, skipped."))],
            readOnly: false
        ) { state, conversationID in
            state.chatManager.mcpConfirmationGate = InspectingGate { request in
                let steps = state.conversation(for: conversationID)?.messages.last?.toolSteps
                seenWhileWaiting = (
                    steps?.first?.status,
                    state.chatManager.streamingActivity(in: conversationID)?.activity,
                    request.changesData
                )
                return .deny
            }
        }

        let waiting = try #require(seenWhileWaiting, "the gate was never asked")
        #expect(waiting.status == .running, "the step shows as running in the step block while waiting for confirmation")
        #expect(waiting.activity == .mcpTool, "the activity status line stays set while waiting for confirmation")
        #expect(waiting.changesData, "a tool that does not declare read-only is treated as one that modifies data")
        let step = try #require(message.toolSteps?.first)
        #expect(message.toolSteps?.count == 1)
        #expect(step.status == .denied && step.errorCode == "user_denied")
        #expect(step.durationMs == nil, "no execution means no duration")
        #expect(state.chatManager.streamingActivity(in: conversationID)?.activity == nil)
        #expect(McpScriptedURLProtocol.requests().isEmpty, "the server received no request after the denial")
        #expect(message.text == "Okay, skipped.")
        // The arguments of the denied step stay on the device (the step detail shows what was about to be submitted).
        #expect(try database.store.fetchStepPayload(messageID: message.id, stepID: step.id)?.arguments?.contains("Melbourne") == true)
    }

    @Test("the production default gate is the confirmation coordinator: the choice comes back through it, and tools/call is sent only after allowing")
    @MainActor
    func defaultGateIsTheCoordinator() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            McpClientFixture.stub("protocol/stateless/tools-call.response.json"),
        ])
        var answered = false
        let (message, state, _) = try await sendThroughChatManager(
            database: database,
            modelLegs: [(200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#)), (200, stepTextLeg("Done."))],
            readOnly: false
        ) { state, _ in
            // Plays the confirmation dialog: picks allow once as soon as a pending confirmation shows up in the coordinator.
            Task { @MainActor in
                for _ in 0..<200 {
                    if let pending = state.mcpConfirmationCoordinator.pending.first {
                        #expect(McpScriptedURLProtocol.requests(method: "tools/call").isEmpty, "no tools/call before allowing")
                        #expect(pending.request.serverName == "Weather" && pending.request.toolTitle == "Get weather")
                        answered = true
                        state.mcpConfirmationCoordinator.resolve(id: pending.id, choice: .once)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
        }
        #expect(answered, "the default gate did not hand the confirmation to the coordinator")
        #expect(message.toolSteps?.first?.status == .done)
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").count == 1)
        #expect(state.mcpConfirmationCoordinator.pending.isEmpty)
    }

    // MARK: Abnormal states

    @Test("auth expires midway -> paused; after skipping, auth_skipped is fed back and the answer continues; the server is recorded on this device as needing a new sign-in")
    @MainActor
    func reauthorizationPauseThenSkip() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"), unauthorizedStub(),
        ])
        var whilePaused: (presentation: McpToolStepsPresentation, connection: McpConnectionStatus?)?

        let (message, state, _) = try await sendThroughChatManager(
            database: database,
            modelLegs: [(200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#)), (200, stepTextLeg("I could not check."))]
        ) { state, conversationID in
            state.chatManager.mcpReauthorizationGate = InspectingReauthGate { request in
                let steps = state.conversation(for: conversationID)?.messages.last?.toolSteps ?? []
                #expect(request.stepId == steps.last?.id)
                #expect(request.serverName == "Weather")
                whilePaused = (
                    McpToolStepsPresentation.make(steps: steps, isGenerating: true),
                    try? database.store.fetchConnectionState(serverId: stepServerID)?.status
                )
                return .skip
            }
        }

        let paused = try #require(whilePaused, "the auth-expired gate was never asked")
        #expect(paused.presentation.header == .waitingForSignIn)
        #expect(paused.presentation.pausedForSignIn?.status == .needsAuth)
        #expect(paused.presentation.rows.last?.detail == .signInExpired(serverName: "Weather"))
        #expect(paused.connection == .needsAuth, "the tools panel offers re-authorization based on this")

        let step = try #require(message.toolSteps?.first)
        #expect(step.status == .needsAuth && step.errorCode == "auth_skipped")
        #expect(McpToolStepsPresentation.pausedStep(in: message.toolSteps ?? [], isGenerating: true) == nil, "no longer paused after skipping")
        #expect(message.state == .delivered && message.text == "I could not check.")
        #expect(ScriptedModelURLProtocol.snapshot().last.map { documentText($0.body) }?.contains("auth_skipped") == true)
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").count == 1, "skipping does not resend")
        #expect(state.mcpReauthorizationCoordinator.pending.isEmpty)
    }

    @Test("auth expires midway -> resumes from this step after signing in again: only this step is resent and earlier results are not redone")
    @MainActor
    func reauthorizationPauseThenResume() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"), unauthorizedStub(),
            // The old connection is void after signing in again: connect once more, then send this step.
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            McpClientFixture.stub("protocol/stateless/tools-call.response.json"),
        ])
        var asked = 0

        let (message, _, _) = try await sendThroughChatManager(
            database: database,
            modelLegs: [(200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#)), (200, stepTextLeg("It is 72F."))]
        ) { state, _ in
            state.chatManager.mcpReauthorizationGate = InspectingReauthGate { _ in
                asked += 1
                return .reauthorized
            }
        }

        #expect(asked == 1)
        #expect(message.toolSteps?.count == 1, "the same step resumes; no step is added")
        let step = try #require(message.toolSteps?.first)
        #expect(step.status == .done && step.errorCode == nil)
        #expect(message.text == "It is 72F.")
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").count == 2)
        #expect(ScriptedModelURLProtocol.snapshot().count == 2, "the model side did not run an extra leg")
    }

    @Test("step limit reached: the answer comes from a tool-free synthesis leg, the message carries the limit marker, and the step block shows a trailing line and collapses the earlier steps")
    @MainActor
    func stepLimitFallsBackToSynthesis() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(try McpClientFixture.stub("protocol/stateless/tools-list.response.json"))
        McpScriptedURLProtocol.setFallback(try McpClientFixture.stub("protocol/stateless/tools-call.response.json"))
        let maxSteps = McpToolBridge.limits(runtimeConfig: .fallback).maxSteps
        let toolLegs = (1...maxSteps).map { index in
            (200, stepToolLeg(arguments: #"{"city":"City \#(index)"}"#)
                .replacingOccurrences(of: "call_step_1", with: "call_step_\(index)"))
        }

        let (message, _, _) = try await sendThroughChatManager(
            database: database,
            modelLegs: toolLegs + [(200, stepTextLeg("Here is what I have so far."))]
        )

        #expect(message.state == .delivered)
        #expect(message.text == "Here is what I have so far.")
        let steps = try #require(message.toolSteps)
        #expect(steps.count == maxSteps)
        #expect(steps.map(\.status) == Array(repeating: .done, count: maxSteps))
        #expect(message.toolFallbackNotice == ToolFallbackNotice.mcpToolLimitReached.rawValue)
        let synthesis = try #require(ScriptedModelURLProtocol.snapshot().last)
        #expect(synthesis.body["tools"] == nil, "the synthesis leg carries no tools")
        #expect(documentText(synthesis.body).contains("tool call limit was reached"))

        let presentation = McpToolStepsPresentation.make(steps: steps, isGenerating: false, limitReached: true)
        #expect(presentation.limitReached)
        #expect(presentation.hiddenEarlierCount == maxSteps - McpToolStepsPresentation.tailCountWhenCollapsed)
        // The limit marker stays on this device: it is not part of the backup envelope.
        let envelope = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        #expect(!envelope.contains(ToolFallbackNotice.mcpToolLimitReached.rawValue))

        let view = UIKitToolStepsView()
        view.configure(steps: steps, isGenerating: false, limitReached: true)
        view.tapHeaderForTesting()
        var rendered = view.renderedStateForTesting
        #expect(rendered.showsLimitNote)
        #expect(rendered.rowTitles.count == McpToolStepsPresentation.tailCountWhenCollapsed)
        #expect(rendered.earlierButtonTitle == String(
            format: L10n.tr("Show earlier steps (%d)", table: .mcp),
            maxSteps - McpToolStepsPresentation.tailCountWhenCollapsed
        ))
        view.tapEarlierStepsForTesting()
        rendered = view.renderedStateForTesting
        #expect(rendered.rowTitles.count == maxSteps && rendered.earlierButtonTitle == nil)
    }

    @Test("user stop: the step in flight is recorded as interrupted, the whole loop winds down and no further request is sent")
    @MainActor
    func userStopInterruptsRunningStep() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        var slow = try McpClientFixture.stub("protocol/stateless/tools-call.response.json")
        slow.delay = 5
        try McpScriptedURLProtocol.enqueue([McpClientFixture.stub("protocol/stateless/tools-list.response.json"), slow])

        var stopper: Task<Void, Never>?
        let (message, state, conversationID) = try await sendThroughChatManager(
            database: database,
            modelLegs: [(200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#)), (200, stepTextLeg("unreachable leg"))]
        ) { state, conversationID in
            // Plays the user: presses stop once the tools/call has gone out.
            stopper = Task { @MainActor in
                for _ in 0..<300 {
                    if !McpScriptedURLProtocol.requests(method: "tools/call").isEmpty {
                        state.cancelGeneration(in: conversationID)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
        }
        await stopper?.value

        #expect(message.state != .generating)
        // The late terminal callback arrives after the send has settled; wait for it to land on the message.
        var step: McpToolStep?
        for _ in 0..<100 {
            step = state.conversation(for: conversationID)?.messages.first { $0.id == message.id }?.toolSteps?.first
            if step?.status == .interrupted { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(step?.status == .interrupted)
        #expect(step?.errorCode == "cancelled")
        #expect(ScriptedModelURLProtocol.snapshot().count == 1, "no further leg is sent after stopping")
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").count == 1)
    }
}

// MARK: - Re-validation, name round trip, removal during streaming and the per-partition authorizer

/// Replaces the stored definition of that tool (so the hash changes) and quarantines it: what re-reading the tool list at sign-in looks like when it finds a change.
private func quarantineStepTool(_ database: McpTestDatabase) throws {
    var snapshots = try database.store.fetchToolSnapshots(serverId: stepServerID)
    for index in snapshots.indices {
        snapshots[index].description = "Deletes every forecast"
        snapshots[index].contentHash = sha256Hex("step:get_weather:changed")
        snapshots[index].pendingReview = true
    }
    try database.store.replaceToolSnapshots(serverId: stepServerID, snapshots: snapshots)
}

extension McpToolBridgeTests {

    // MARK: Re-checking local state before execution

    @Test("paused on expired auth -> the tool definition changed at re-sign-in and is quarantined -> the resume sends no tools/call and feeds back tool_unavailable for this step")
    @MainActor
    func resumeAfterReauthorizationSkipsQuarantinedTool() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"), unauthorizedStub(),
            // Without the re-check the resume would reconnect and send this step.
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            McpClientFixture.stub("protocol/stateless/tools-call.response.json"),
        ])

        let (message, _, _) = try await sendThroughChatManager(
            database: database,
            modelLegs: [(200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#)), (200, stepTextLeg("I could not check."))]
        ) { state, _ in
            state.chatManager.mcpReauthorizationGate = InspectingReauthGate { _ in
                try? quarantineStepTool(database)
                return .reauthorized
            }
        }

        #expect(McpScriptedURLProtocol.requests(method: "tools/call").count == 1, "only the call made before auth expired; the resume did not send another")
        let step = try #require(message.toolSteps?.first)
        #expect(message.toolSteps?.count == 1)
        #expect(step.status == .failed && step.errorCode == "tool_unavailable")
        #expect(message.state == .delivered && message.text == "I could not check.")
        #expect(ScriptedModelURLProtocol.snapshot().last.map { documentText($0.body) }?.contains("tool_unavailable") == true)
    }

    @Test("a tool set to \"Don't use\" mid-turn -> later calls are not sent, even when changed while the confirmation dialog is open")
    @MainActor
    func toolTurnedOffMidRunIsNotCalled() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(try McpClientFixture.stub("protocol/stateless/tools-list.response.json"))
        McpScriptedURLProtocol.setFallback(try McpClientFixture.stub("protocol/stateless/tools-call.response.json"))
        var asked = 0

        let (message, _, _) = try await sendThroughChatManager(
            database: database,
            modelLegs: [
                (200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#)),
                (200, stepToolLeg(arguments: #"{"city":"Sydney"}"#).replacingOccurrences(of: "call_step_1", with: "call_step_2")),
                (200, stepTextLeg("Only Melbourne.")),
            ],
            readOnly: false
        ) { state, _ in
            state.chatManager.mcpConfirmationGate = InspectingGate { _ in
                asked += 1
                if asked == 2 {
                    // While the second confirmation dialog is open, the user turns this tool off in the management screen.
                    try? state.mcpServerDirectory.setToolPermission(
                        .off, serverId: stepServerID, toolName: "get_weather", uid: state.sessionPartitionUID
                    )
                }
                return .once
            }
        }

        #expect(asked == 2)
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").count == 1, "the call after turning it off was not sent")
        let steps = try #require(message.toolSteps)
        #expect(steps.map(\.status) == [.done, .failed])
        #expect(steps.last?.errorCode == "tool_unavailable")
        #expect(message.text == "Only Melbourne.")
    }

    @Test("a run-automatically tool changed to ask every time midway -> the resume passes the confirmation gate again and sends only after allowing")
    @MainActor
    func toolTightenedToAskMidRunAsksBeforeCalling() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"), unauthorizedStub(),
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            McpClientFixture.stub("protocol/stateless/tools-call.response.json"),
        ])
        var callsWhenAsked: Int?

        let (message, _, _) = try await sendThroughChatManager(
            database: database,
            modelLegs: [(200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#)), (200, stepTextLeg("It is 72F."))]
        ) { state, _ in
            state.chatManager.mcpReauthorizationGate = InspectingReauthGate { _ in
                try? state.mcpServerDirectory.setToolPermission(
                    .ask, serverId: stepServerID, toolName: "get_weather", uid: state.sessionPartitionUID
                )
                return .reauthorized
            }
            state.chatManager.mcpConfirmationGate = InspectingGate { _ in
                callsWhenAsked = McpScriptedURLProtocol.requests(method: "tools/call").count
                return .once
            }
        }

        #expect(callsWhenAsked == 1, "the resumed call was not sent before the user allowed it")
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").count == 2)
        #expect(message.toolSteps?.first?.status == .done)
    }

    // MARK: Tool names round-trip unchanged

    @Test("an outbound name containing fragments such as `_de` / `_ad` that look like escape sequences comes back as the exact name sent, runs normally and is fed back unchanged")
    @MainActor
    func outboundNamesSurviveTheRoundTrip() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        // The server is named Dead Drop -> slug deaddrop; the tools are delete_page and add_comment.
        let serverId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000DE")!
        let conversationID = UUID()
        let snapshots = ["delete_page", "add_comment"].map { name in
            McpToolSnapshot(
                serverId: serverId, toolName: name, title: name, description: "Tool \(name)", inputSchema: stepSchema(),
                annotations: .object(JSONObject([("readOnlyHint", .bool(true))])),
                contentHash: sha256Hex("roundtrip:\(name)"), readOnly: true, pendingReview: false, oversized: false
            )
        }
        let record = try database.store.addServer(
            McpServerAddition(
                id: serverId, name: "Dead Drop", url: "https://mcp.example.com/mcp", authKind: .auto,
                localOnly: false, iconURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                snapshots: snapshots, permissions: [:],
                connectionState: McpConnectionState(serverId: serverId, status: .connected, generation: .stateless)
            ),
            maxServers: 20
        )
        try database.store.setServerEnabled(true, conversationId: conversationID, serverId: serverId)
        let outbound = "mcp_\(record.slug)_delete_page"
        #expect(outbound == "mcp_deaddrop_delete_page")

        await MetadataClient.shared.resetForTesting()
        ScriptedModelURLProtocol.reset([
            (200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#).replacingOccurrences(of: stepOutbound, with: outbound)),
            (200, stepTextLeg("Deleted.")),
        ])
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            McpClientFixture.stub("protocol/stateless/tools-call.response.json"),
        ])
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
        let (relay, model) = makeToolLoopRelayProvider(transport: .openaiChatCompletions)
        state.providers = [relay]
        state.conversations = [TestFactories.makeConversation(id: conversationID, providerID: relay.id, modelID: model.id, messages: [])]
        state.chatManager.debugUseMcpClientFactoryForTesting { McpClient(endpoint: $0, session: McpScriptedURLProtocol.session()) }

        _ = await state.chatManager.sendMessage("Delete the page", in: conversationID)
        var assistant: ChatMessage?
        for _ in 0..<100 {
            assistant = state.conversation(for: conversationID)?.messages.last(where: { $0.role == .assistant })
            if let assistant, assistant.state != .generating { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let message = try #require(assistant)

        #expect(message.unhandledToolCalls == nil, "the name is in the name table and must not end up as unhandled")
        #expect(message.toolSteps?.first?.status == .done)
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").first?.jsonRPCName == "delete_page")
        #expect(message.text == "Deleted.")
        let second = try #require(ScriptedModelURLProtocol.snapshot().last)
        #expect(documentText(second.body).contains("\"\(outbound)\""), "the assistant tool_calls fed back to the model carry the original name")
    }

    // MARK: Removing a server while streaming

    @Test("removing a server while the answer is still running: that step sends no tools/call, its raw arguments already on the device are deleted with it and are never written back")
    @MainActor
    func removingServerMidRunDeletesTheRunningStepPayload() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        var payloadBeforeRemoval: String?
        var messageID: UUID?

        let (message, _, _) = try await sendThroughChatManager(
            database: database,
            modelLegs: [(200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#)), (200, stepTextLeg("Server is gone."))],
            readOnly: false
        ) { state, conversationID in
            state.chatManager.mcpConfirmationGate = InspectingGate { _ in
                let assistant = state.conversation(for: conversationID)?.messages.last
                messageID = assistant?.id
                if let assistant, let step = assistant.toolSteps?.first {
                    payloadBeforeRemoval = try? database.store.fetchStepPayload(messageID: assistant.id, stepID: step.id)?.arguments
                }
                try? state.mcpServerDirectory.remove(serverId: stepServerID, uid: state.sessionPartitionUID)
                return .once
            }
        }

        #expect(payloadBeforeRemoval?.contains("Melbourne") == true, "the raw arguments are already on the device while waiting for confirmation")
        #expect(messageID == message.id)
        let step = try #require(message.toolSteps?.first)
        #expect(step.status == .failed && step.errorCode == "tool_unavailable")
        #expect(McpScriptedURLProtocol.requests().isEmpty, "the server was removed, so no further request goes to it")
        #expect(try database.store.fetchStepPayload(messageID: message.id, stepID: step.id) == nil)
        #expect(try database.nonEmptyTables() == [:], "no row of this server remains on the device")
        #expect(message.toolSteps?.count == 1, "the step summary on the message is kept")
    }

    // MARK: One authorizer per partition

    @Test("the chat loop refreshes tokens through the directory's single authorizer for this partition: a concurrent refresh elsewhere hits the token endpoint once, and production code constructs the authorizer in one place only")
    @MainActor
    func chatLoopRefreshesThroughThePartitionAuthorizer() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        let clientDocument = try #require(URL(string: "https://app.example.com/oauth/mcp-client.json"))
        let credentials = McpCredentialStore(storage: InMemoryMcpCredentialStorage())
        let transport = FakeMcpAuthTransport()
        let metadata = try McpFixture.json("auth/authorization-server-metadata.cimd.json")
        transport.stub(
            status: 200, json: metadata["body"] ?? .object(JSONObject()),
            at: "https://auth.example.com/.well-known/oauth-authorization-server"
        )
        let refreshed = try McpFixture.json("auth/token.refresh.success.json")
        transport.stub(status: 200, json: refreshed["body"] ?? .object(JSONObject()), at: "https://auth.example.com/token")
        transport.postFormDelay = 0.15
        let store = database.store
        var built = 0
        let directory = McpServerDirectory(
            credentialStore: credentials,
            openStore: { _ in store },
            makeAuthorizer: { credentialStore in
                built += 1
                return McpAuthorizer(
                    transport: transport, browser: FakeMcpBrowserSession(), credentialStore: credentialStore,
                    clientMetadataDocumentURL: clientDocument
                )
            }
        )
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpClientFixture.stub("protocol/stateless/tools-list.response.json"),
            McpClientFixture.stub("protocol/stateless/tools-call.response.json"),
        ])
        var elsewhere: Task<String?, Never>?

        let (message, state, _) = try await sendThroughChatManager(
            database: database,
            modelLegs: [(200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#)), (200, stepTextLeg("It is 72F."))],
            readOnly: false,
            directory: directory
        ) { state, _ in
            let uid = state.sessionPartitionUID
            // The access token has expired and the refresh token is still there: the loop must refresh before using a token.
            try? credentials.save(
                McpCredentials(
                    accessToken: "expired", refreshToken: "mcp_rt_example", expiresAt: Date(timeIntervalSinceNow: -60),
                    issuer: "https://auth.example.com", clientID: clientDocument.absoluteString,
                    resource: "https://mcp.example.com/mcp"
                ),
                serverId: stepServerID, uid: uid
            )
            state.chatManager.mcpConfirmationGate = InspectingGate { _ in
                // The chat loop is about to fetch a token; at the same moment another caller (management screen, add flow) fetches this server's token through the directory's authorizer.
                let shared = state.mcpServerDirectory.authorizer(for: uid)
                elsewhere = Task { try? await shared.validAccessToken(serverId: stepServerID, uid: uid) }
                return .once
            }
        }
        #expect(await elsewhere?.value == "mcp_at_example_2")

        #expect(message.toolSteps?.first?.status == .done)
        #expect(built == 1, "one authorizer per partition")
        #expect(state.mcpServerDirectory.authorizer(for: state.sessionPartitionUID)
            === directory.authorizer(for: state.sessionPartitionUID))
        #expect(transport.formRequests.count == 1, "the chat loop and the management screen refreshed together and hit the token endpoint once")
        let call = try #require(McpScriptedURLProtocol.requests(method: "tools/call").first)
        #expect(call.header("Authorization") == "Bearer mcp_at_example_2", "the refreshed token is the one sent")
        let stored = try #require(credentials.load(serverId: stepServerID, uid: state.sessionPartitionUID))
        #expect(stored.refreshToken == "mcp_rt_example_2", "the rotated refresh token was not wiped by an invalid_grant from the other caller")

        // Serialization lives in the authorizer instance: a second instance built anywhere in production code would bring back two instances refreshing independently.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo", isDirectory: true)
        var constructors: [String] = []
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8),
                  text.contains("McpAuthorizer(") else { continue }
            constructors.append(file.lastPathComponent)
        }
        #expect(constructors == ["McpServerDirectory.swift"], "authorizer construction sites: \(constructors)")
    }

    // MARK: Names outside the name table

    @Test("the model proposes an mcp_ tool name outside the name table: nothing is executed and the name goes to the notice card")
    @MainActor
    func unknownMcpToolNameIsNotExecuted() async throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        McpScriptedURLProtocol.reset()
        let invented = "mcp_weather_delete_everything"

        let (message, _, _) = try await sendThroughChatManager(
            database: database,
            modelLegs: [
                (200, stepToolLeg(arguments: #"{"city":"Melbourne"}"#).replacingOccurrences(of: stepOutbound, with: invented)),
                (200, stepTextLeg("Done.")),
            ]
        )

        #expect(message.unhandledToolCalls?.map(\.name) == [invented], "the notice card shows the name the model gave")
        #expect((message.toolSteps ?? []).isEmpty, "a call that was never run leaves no step")
        #expect(McpScriptedURLProtocol.requests(method: "tools/call").isEmpty, "a name outside the name table is not executed")
    }
}
