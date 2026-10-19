import Foundation
import Testing
@testable import Oriveo

// Display rule of the capability bar "Tools" chip: shown only when the master switch is on and at least one server has been added (even if all are off),
// the same rule as the library chip; hidden when none has been added, and the discovery entry is in "Settings > MCP". Same-named cases exist on Android / Web.

private let serverId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000C7")!

@Suite("Tools chip visibility rule")
struct ToolsChipVisibilityTests {
    private func load(_ database: McpTestDatabase) throws -> McpToolPanelState {
        try McpToolPanelModel.load(
            conversationId: UUID(), store: database.store,
            credentialStore: McpCredentialStore(storage: InMemoryMcpCredentialStorage()), uid: "u1",
            runtimeConfig: .fallback, availability: .available
        )
    }

    private func addServer(_ database: McpTestDatabase) throws {
        try database.store.addServer(
            McpServerAddition(
                id: serverId, name: "Linear", url: "https://mcp.linear.app/mcp", authKind: .auto, localOnly: false,
                iconURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000), snapshots: [], permissions: [:],
                connectionState: McpConnectionState(
                    serverId: serverId, status: .connected, lastSuccessAt: nil, generation: .stateless
                )
            ),
            maxServers: 20
        )
    }

    @Test("No server added: hidden even with the master switch on")
    func hiddenWithoutServers() throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        let state = try load(database)
        #expect(ComposerToolsChipState.resolve(featureEnabled: true, panelState: state) == nil)
    }

    @Test("Panel state not read yet (initial empty state): hidden")
    func hiddenBeforeLoad() {
        #expect(ComposerToolsChipState.resolve(featureEnabled: true, panelState: .empty) == nil)
    }

    @Test("Servers added but all off for this conversation: shown, without a number")
    func shownWithServersAllOff() throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        try addServer(database)
        let state = try load(database)
        #expect(ComposerToolsChipState.resolve(featureEnabled: true, panelState: state)
            == ComposerToolsChipState(enabledServerCount: 0, isAvailable: true))
    }

    @Test("Master switch off: hidden even with servers")
    func hiddenWhenFeatureOff() throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        try addServer(database)
        let state = try load(database)
        #expect(ComposerToolsChipState.resolve(featureEnabled: false, panelState: state) == nil)
    }
}
