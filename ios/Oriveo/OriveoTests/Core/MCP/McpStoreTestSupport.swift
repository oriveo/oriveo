import Foundation
import GRDB
@testable import Oriveo

/// A standalone temporary database for MCP storage tests: runs the production migrator and never touches the pool
/// held by `DatabaseManager`.
struct McpTestDatabase {
    let store: McpServerStore
    let pool: DatabasePool
    let directory: URL

    /// Every table that holds remote MCP data.
    static let dataTables = [
        "mcp_server",
        "mcp_connection_state",
        "mcp_tool_snapshot",
        "mcp_tool_permission",
        "mcp_conversation_switch",
        "mcp_step_payload",
    ]

    static func make(upTo target: String? = nil) throws -> McpTestDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(
            path: directory.appendingPathComponent(DatabaseSchema.fileName).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        let migrator = makeMigrator(directory: directory)
        if let target {
            try migrator.migrate(pool, upTo: target)
        } else {
            try migrator.migrate(pool)
        }
        return McpTestDatabase(store: McpServerStore(dbPool: pool), pool: pool, directory: directory)
    }

    static func makeMigrator(directory: URL) -> DatabaseMigrator {
        let files = AttachmentFileStore(rootDirectory: directory.appendingPathComponent("Files", isDirectory: true))
        return DatabaseSchema.makeMigrator(attachmentFileStore: files)
    }

    func migrateToLatest() throws {
        try Self.makeMigrator(directory: directory).migrate(pool)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Tables that still hold rows, with their row counts. Tests that require a failed add to leave no partial
    /// server behind expect an empty dictionary, so a failure message shows which table leaked and how many rows.
    func nonEmptyTables() throws -> [String: Int] {
        try pool.read { db in
            var result: [String: Int] = [:]
            for table in Self.dataTables {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                if count > 0 { result[table] = count }
            }
            return result
        }
    }

    /// Creates a conversation with `messageCount` messages (required columns only) and returns their ids.
    @discardableResult
    func insertConversation(messageCount: Int = 1) throws -> (conversation: UUID, messages: [UUID]) {
        let conversation = UUID()
        let messages = (0..<messageCount).map { _ in UUID() }
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation (id, providerID, providerKind, modelID, createdAt, updatedAt)
                    VALUES (?, 'provider-1', 'openAI', 'gpt-x', 1, 1)
                    """,
                arguments: [conversation.uuidString]
            )
            for message in messages {
                try db.execute(
                    sql: """
                        INSERT INTO message (id, conversationID, role, providerKind, providerName, modelName, state)
                        VALUES (?, ?, 'assistant', 'openAI', 'OpenAI', 'gpt-x', 'delivered')
                        """,
                    arguments: [message.uuidString, conversation.uuidString]
                )
            }
        }
        return (conversation, messages)
    }
}

/// Factories for server records and snapshots used in tests.
enum McpTestRecords {
    static func record(
        id: UUID = UUID(),
        slug: String,
        name: String = "Server",
        url: String? = nil,
        authKind: McpAuthKind = .auto,
        localOnly: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> McpServerRecord {
        McpServerRecord(
            id: id,
            name: name,
            slug: slug,
            url: url ?? "https://mcp.example.com/\(slug)",
            authKind: authKind,
            localOnly: localOnly,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    static func snapshot(
        serverId: UUID,
        toolName: String,
        readOnly: Bool = false,
        pendingReview: Bool = false
    ) -> McpToolSnapshot {
        McpToolSnapshot(
            serverId: serverId,
            toolName: toolName,
            title: toolName,
            description: "Tool \(toolName)",
            inputSchema: .object(JSONObject([
                ("properties", .object(JSONObject([("q", .object(JSONObject([("type", .string("string"))])))]))),
                ("type", .string("object")),
            ])),
            annotations: .object(JSONObject([("readOnlyHint", .bool(readOnly))])),
            contentHash: sha256Hex("\(serverId.uuidString):\(toolName)"),
            readOnly: readOnly,
            pendingReview: pendingReview
        )
    }

    static func addition(
        id: UUID = UUID(),
        name: String = "Linear",
        url: String = "https://mcp.linear.app/mcp",
        localOnly: Bool = false,
        tools: [String] = ["get_issue", "create_issue"]
    ) -> McpServerAddition {
        McpServerAddition(
            id: id,
            name: name,
            url: url,
            authKind: .auto,
            localOnly: localOnly,
            iconURL: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshots: tools.map { snapshot(serverId: id, toolName: $0, pendingReview: true) },
            permissions: Dictionary(uniqueKeysWithValues: tools.map { ($0, McpToolPermission.ask) }),
            connectionState: McpConnectionState(serverId: id, status: .connected, negotiatedVersion: "2026-07-28", generation: .stateless)
        )
    }
}
