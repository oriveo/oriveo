import Foundation
import GRDB
import Testing
@testable import Oriveo

// MARK: - Revoking conversation grants, root-hosted confirmation, and cleanup of per-step payloads

private let tools: [JSONValue] = [
    McpUiFixture.tool("search", description: "Search things.", readOnly: true, title: "Search"),
    McpUiFixture.tool("create", description: "Create a thing.", readOnly: false, title: "Create"),
]

private func definitions(_ tools: [JSONValue]) -> [McpToolDefinition] {
    tools.map { tool in
        McpToolDefinition(
            name: tool["name"]?.stringValue ?? "",
            title: tool["title"]?.stringValue,
            description: tool["description"]?.stringValue,
            inputSchema: tool["inputSchema"] ?? .object(JSONObject()),
            annotations: tool["annotations"] ?? .object(JSONObject())
        )
    }
}

@Suite("MCP conversation grants, root-hosted confirmation and step payload cleanup", .serialized)
@MainActor
struct McpGrantAndPayloadCleanupTests {
    private let grants = McpConversationGrants.shared
    private let conversation = UUID()

    private func grantAll(_ serverId: UUID) {
        grants.revokeAll()
        grants.grant(conversationId: conversation, serverId: serverId, toolName: "search")
        grants.grant(conversationId: conversation, serverId: serverId, toolName: "create")
    }

    private func granted(_ serverId: UUID, _ tool: String) -> Bool {
        grants.isGranted(conversationId: conversation, serverId: serverId, toolName: tool)
    }

    // MARK: Revoking "allow for this conversation"

    @Test("Changing one tool's permission revokes only that tool's \"allow for this conversation\" grant; other tools and other servers are untouched")
    func permissionChangeRevokesThatTool() throws {
        let rig = try McpUiRig(); defer { rig.cleanUp() }
        let id = try rig.seedServer(name: "Weather", tools: definitions(tools))
        let other = try rig.seedServer(name: "Other", url: "https://other.example.org/mcp", tools: definitions(tools))
        grantAll(id)
        grants.grant(conversationId: conversation, serverId: other, toolName: "create")

        let model = rig.detailModel(id)
        model.appear()
        model.setPermission(.ask, toolName: "create")
        #expect(!granted(id, "create"), "a tool that was just tightened must be confirmed again on its next call")
        #expect(granted(id, "search"))
        #expect(granted(other, "create"))
        grants.revokeAll()
    }

    @Test("A refresh that finds changed tools revokes the changed tools; confirming the changes revokes the whole server")
    func refreshAndConfirmRevoke() async throws {
        let rig = try McpUiRig(); defer { rig.cleanUp() }
        let id = try rig.seedServer(name: "Weather", tools: definitions(tools))
        let changed: [JSONValue] = [
            tools[0],
            McpUiFixture.tool("create", description: "Create or overwrite a thing.", readOnly: false, title: "Create"),
        ]
        McpScriptedURLProtocol.reset()
        try McpScriptedURLProtocol.enqueue([
            McpUiFixture.toolsList { _ in changed }, McpUiFixture.toolsList { _ in changed },
            McpUiFixture.toolsList { _ in changed }, McpUiFixture.toolsList { _ in changed },
        ])
        grantAll(id)

        let model = rig.detailModel(id)
        model.appear()
        model.reloadTools()
        await model.waitUntilIdle()
        #expect(!granted(id, "create"), "a tool whose definition changed: the earlier tap must not carry over")
        #expect(granted(id, "search"), "unchanged tools are untouched")

        model.confirmChanges()
        await model.waitUntilIdle()
        #expect(!granted(id, "search") && !granted(id, "create"))
        grants.revokeAll()
    }

    @Test("Removing a server revokes every grant for that server, from the detail page and through the store alike")
    func removalRevokes() throws {
        let rig = try McpUiRig(); defer { rig.cleanUp() }
        let viaPage = try rig.seedServer(name: "Weather", tools: definitions(tools))
        grantAll(viaPage)
        let model = rig.detailModel(viaPage)
        model.appear()
        model.askRemove()
        model.confirmRemove()
        #expect(!granted(viaPage, "search") && !granted(viaPage, "create"))

        let viaStore = try rig.seedServer(name: "Other", url: "https://other.example.org/mcp", tools: definitions(tools))
        grantAll(viaStore)
        try rig.store.deleteServer(id: viaStore)
        #expect(!granted(viaStore, "search") && !granted(viaStore, "create"))
        grants.revokeAll()
    }

    // MARK: The confirmation dialog is hosted at the app root

    @Test("The confirmation dialog's presentation host lives at the app root; with no UI to present it the confirmation keeps waiting and is not treated as a user decline")
    func confirmationIsHostedAtTheRoot() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Features", isDirectory: true)
        let appRoot = try String(contentsOf: root.appendingPathComponent("App/AppRootView.swift"), encoding: .utf8)
        let chat = try String(contentsOf: root.appendingPathComponent("Chat/ChatView.swift"), encoding: .utf8)
        #expect(appRoot.contains(".mcpConfirmationPresenter(appState: appState)"))
        #expect(!chat.contains(".mcpConfirmationPresenter("), "if it were attached to the chat page only, nothing would present it once the user leaves that page")

        let coordinator = McpConfirmationCoordinator()
        let request = McpConfirmationRequest(
            conversationId: conversation, serverId: UUID(), serverName: "Weather", serverHost: "mcp.example.com",
            toolName: "create", toolTitle: "Create", arguments: .object(JSONObject()), inputSchema: .object(JSONObject())
        )
        let waiting = Task { try await coordinator.requestConfirmation(request) }
        #expect(await McpUiWait.until { coordinator.pending.count == 1 })
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(coordinator.pending.count == 1 && !waiting.isCancelled, "keeps waiting while nobody sees the dialog; no decline is fed back")
        coordinator.resolve(id: try #require(coordinator.pending.first?.id), choice: .once)
        #expect(try await waiting.value == .once)
    }

    // MARK: Cascading deletion of per-step payloads

    @Test("Removing a server also deletes the raw arguments and results its steps left on this device; other servers' payloads and the summaries on messages are kept")
    func removingServerDeletesItsStepPayloads() throws {
        let rig = try McpUiRig(); defer { rig.cleanUp() }
        let id = try rig.seedServer(name: "Weather", tools: definitions(tools))
        let other = try rig.seedServer(name: "Other", url: "https://other.example.org/mcp", tools: definitions(tools))
        let message = try #require(try rig.database.insertConversation().messages.first)
        func step(_ number: Int, _ server: UUID) -> McpToolStep {
            McpToolStep(
                id: "\(number):call_\(number)", serverId: server.uuidString.lowercased(), serverName: "S",
                toolName: "create", title: "Create", argsSummary: "x", status: .done, errorCode: nil,
                step: number, durationMs: 10
            )
        }
        let steps = [step(1, id), step(2, other)]
        try rig.database.pool.write { db in
            try db.execute(
                sql: "UPDATE message SET toolSteps = ? WHERE id = ?",
                arguments: [RecordMappers.encodeToolSteps(steps), message.uuidString]
            )
        }
        try rig.store.saveStepPayload(messageID: message, stepID: steps[0].id, arguments: #"{"secret":"a"}"#, resultPrefix: "r1")
        try rig.store.saveStepPayload(messageID: message, stepID: steps[1].id, arguments: #"{"secret":"b"}"#, resultPrefix: "r2")

        try rig.directory.remove(serverId: id, uid: McpUiFixture.uid)
        #expect(try rig.store.fetchStepPayload(messageID: message, stepID: steps[0].id) == nil)
        #expect(try rig.store.fetchStepPayload(messageID: message, stepID: steps[1].id)?.resultPrefix == "r2")
        let kept: String? = try rig.database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT toolSteps FROM message WHERE id = ?", arguments: [message.uuidString])
        }
        #expect(RecordMappers.decodeToolSteps(kept, messageState: .delivered)?.count == 2, "tool records in existing conversations are kept")
    }

    @Test("Deleting a conversation / a message deletes the per-step payloads with it")
    func deletingConversationDeletesStepPayloads() throws {
        let rig = try McpUiRig(); defer { rig.cleanUp() }
        let created = try rig.database.insertConversation(messageCount: 2)
        for message in created.messages {
            try rig.store.saveStepPayload(messageID: message, stepID: "1:call_1", arguments: "{}", resultPrefix: "r")
        }
        try rig.database.pool.write { db in
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [created.messages[0].uuidString])
        }
        #expect(try rig.store.fetchStepPayload(messageID: created.messages[0], stepID: "1:call_1") == nil)
        #expect(try rig.store.fetchStepPayload(messageID: created.messages[1], stepID: "1:call_1") != nil)
        try rig.database.pool.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [created.conversation.uuidString])
        }
        #expect(try rig.store.fetchStepPayload(messageID: created.messages[1], stepID: "1:call_1") == nil)
    }

    // MARK: Pasted access token

    @Test("Pasting an access token clears the stale OAuth fields: the token read afterwards is the newly pasted one")
    func pastedTokenReplacesOAuthFields() async throws {
        let rig = try McpUiRig(); defer { rig.cleanUp() }
        let id = UUID()
        try rig.credentials.save(
            McpCredentials(
                accessToken: "at_old", refreshToken: "rt_old", expiresAt: Date().addingTimeInterval(3_600),
                issuer: "https://auth.example.com", clientID: "client_1", resource: "https://mcp.example.com/mcp"
            ),
            serverId: id, uid: McpUiFixture.uid
        )
        try await rig.authorizer.storePastedToken("pat_new", serverId: id, uid: McpUiFixture.uid)
        let stored = try #require(rig.credentials.load(serverId: id, uid: McpUiFixture.uid))
        #expect(stored == McpCredentials(pastedToken: "pat_new"))
        #expect(try await rig.authorizer.validAccessToken(serverId: id, uid: McpUiFixture.uid) == "pat_new")
    }
}
