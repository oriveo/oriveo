import Foundation
import GRDB
import Testing
@testable import Oriveo

/// The migration behind remote MCP, `v29_add_mcp`: it adds six tables, two columns on `message` and two cleanup
/// triggers, and leaves existing data untouched.
@Suite("MCP migration v29_add_mcp")
struct McpMigrationTests {
    private static let previousVersion = "v28_metadata_split_cache"

    private static let expectedColumns: [String: [String]] = [
        "mcp_server": [
            "id", "name", "slug", "url", "authKind", "localOnly", "iconURL", "createdAt", "updatedAt", "schemaVersion",
        ],
        "mcp_connection_state": ["serverId", "status", "lastSuccessAt", "negotiatedVersion", "generation", "sessionId"],
        "mcp_tool_snapshot": [
            "serverId", "toolName", "title", "description", "inputSchema", "annotations", "contentHash",
            "readOnly", "pendingReview", "oversized", "updatedAt",
        ],
        "mcp_tool_permission": ["serverId", "toolName", "permission"],
        "mcp_conversation_switch": ["conversationId", "serverId", "enabledAt"],
        "mcp_step_payload": ["messageID", "stepID", "serverId", "arguments", "resultPrefix", "createdAt"],
    ]

    private static let expectedIndexes: [String: Set<String>] = [
        "mcp_server": ["idx_mcp_server_updatedAt", "idx_mcp_server_slug"],
        "mcp_connection_state": [],
        "mcp_tool_snapshot": [],
        "mcp_tool_permission": [],
        "mcp_conversation_switch": [],
        "mcp_step_payload": [],
    ]

    private static let cleanupTriggers: Set<String> = [
        "mcp_cleanup_before_conversation_delete",
        "mcp_cleanup_after_message_delete",
    ]

    private func columnNames(_ db: Database, table: String) throws -> [String] {
        try db.columns(in: table).map(\.name)
    }

    private func indexNames(_ db: Database, table: String) throws -> Set<String> {
        Set(try String.fetchAll(
            db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND name NOT LIKE 'sqlite_%'",
            arguments: [table]
        ))
    }

    private func mcpTableNames(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'").filter { $0.hasPrefix("mcp_") })
    }

    private func triggerNames(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'"))
    }

    /// Everything the migration creates, as SQLite recorded it: the MCP tables, their indexes and the triggers,
    /// plus the column list of `message`.
    private func mcpSchema(_ db: Database) throws -> [String] {
        let objects = try Row.fetchAll(
            db, sql: "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
        ).compactMap { row -> String? in
            let name: String = row["name"]
            guard name.hasPrefix("mcp_") || name.hasPrefix("idx_mcp_") else { return nil }
            let type: String = row["type"]
            let sql: String = row["sql"]
            return "\(type) \(name): \(sql)"
        }
        return objects + ["message columns: " + (try columnNames(db, table: "message")).joined(separator: ",")]
    }

    @Test("Upgrading a v28 database keeps its conversations and messages and adds the six tables, the two message columns and the two cleanup triggers")
    func migrationFromV28PreservesData() throws {
        let database = try McpTestDatabase.make(upTo: Self.previousVersion)
        defer { database.cleanUp() }

        // At v28 nothing of MCP exists yet.
        try database.pool.write { db in
            #expect(try mcpTableNames(db).isEmpty)
            #expect(try triggerNames(db).isDisjoint(with: Self.cleanupTriggers))
            let messageColumns = try columnNames(db, table: "message")
            #expect(!messageColumns.contains("toolSteps"))
            #expect(!messageColumns.contains("toolFallbackNotice"))
            try db.execute(
                sql: """
                    INSERT INTO metadata_split_cache (key, payload, revision, contractVersion, etag, updatedAt)
                    VALUES ('catalog:openAI', '{}', 'sha256:r', 3, 'etag-1', 1)
                    """
            )
        }
        let (conversation, messages) = try database.insertConversation(messageCount: 2)

        try database.migrateToLatest()

        try database.pool.read { (db: Database) throws -> Void in
            #expect(try mcpTableNames(db) == Set(McpTestDatabase.dataTables))
            #expect(try triggerNames(db).isSuperset(of: Self.cleanupTriggers))
            let messageColumns = try columnNames(db, table: "message")
            #expect(messageColumns.contains("toolSteps"))
            #expect(messageColumns.contains("toolFallbackNotice"))

            // The v28 data is still there, and the existing messages have no tool steps and no notice.
            #expect(try String.fetchOne(db, sql: "SELECT etag FROM metadata_split_cache WHERE key = 'catalog:openAI'") == "etag-1")
            #expect(try String.fetchOne(
                db, sql: "SELECT modelID FROM conversation WHERE id = ?", arguments: [conversation.uuidString]
            ) == "gpt-x")
            let storedMessages = try Row.fetchAll(
                db,
                sql: "SELECT id, toolSteps, toolFallbackNotice FROM message WHERE conversationID = ?",
                arguments: [conversation.uuidString]
            )
            #expect(Set(storedMessages.map { $0["id"] as String }) == Set(messages.map(\.uuidString)))
            #expect(storedMessages.allSatisfy { ($0["toolSteps"] as String?) == nil })
            #expect(storedMessages.allSatisfy { ($0["toolFallbackNotice"] as String?) == nil })
        }

        // The new tables work through the production store: a written record reads back unchanged.
        let record = McpTestRecords.record(slug: "linear", name: "Linear")
        try database.store.insertServer(record)
        #expect(try database.store.fetchServer(id: record.id) == record)
    }

    @Test("Each MCP table has exactly the expected columns and indexes")
    func tablesHaveExactColumnsAndIndexes() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }

        #expect(Set(Self.expectedColumns.keys) == Set(McpTestDatabase.dataTables))
        try database.pool.read { (db: Database) throws -> Void in
            #expect(try mcpTableNames(db) == Set(McpTestDatabase.dataTables))
            for table in McpTestDatabase.dataTables {
                #expect(try columnNames(db, table: table) == Self.expectedColumns[table], "columns of \(table)")
                #expect(try indexNames(db, table: table) == Self.expectedIndexes[table], "indexes of \(table)")
            }
        }
    }

    @Test("The slug index is unique: a second row with the same slug is rejected")
    func slugUniqueIndexIsEnforced() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }

        try database.pool.write { db in
            let unique = try Int.fetchOne(
                db, sql: "SELECT \"unique\" FROM pragma_index_list('mcp_server') WHERE name = 'idx_mcp_server_slug'"
            )
            #expect(unique == 1)

            let insert = """
                INSERT INTO mcp_server (id, name, slug, url, authKind, localOnly, createdAt, updatedAt, schemaVersion)
                VALUES (?, 'Linear', 'linear', 'https://mcp.linear.app/mcp', 'auto', 0, 1, 1, 1)
                """
            try db.execute(sql: insert, arguments: ["srv-1"])
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: insert, arguments: ["srv-2"])
            }
        }
    }

    @Test("A lookup by the leading primary-key column uses the primary-key index instead of scanning the table")
    func primaryKeyPrefixLookupUsesIndex() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }

        try database.pool.read { (db: Database) throws -> Void in
            let detail = try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN SELECT * FROM mcp_tool_snapshot WHERE serverId = 'x'"
            ).map { ($0["detail"] as String?) ?? "" }.joined(separator: " ")
            #expect(detail.contains("USING INDEX sqlite_autoindex_mcp_tool_snapshot_1"), "\(detail)")
        }
    }

    @Test("On an upgraded database, deleting a message removes its step payloads and deleting a conversation removes its switches and the payloads of its messages")
    func cleanupTriggersWorkOnUpgradedDatabase() throws {
        let database = try McpTestDatabase.make(upTo: Self.previousVersion)
        defer { database.cleanUp() }
        let store = database.store

        // Conversations that existed before the upgrade.
        let (doomed, doomedMessages) = try database.insertConversation(messageCount: 2)
        let (kept, keptMessages) = try database.insertConversation(messageCount: 2)
        try database.migrateToLatest()

        let server = UUID()
        try store.setServerEnabled(true, conversationId: doomed, serverId: server)
        try store.setServerEnabled(true, conversationId: kept, serverId: server)
        for message in doomedMessages + keptMessages {
            try store.saveStepPayload(messageID: message, stepID: "s1", arguments: "{}", resultPrefix: "r")
        }

        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [keptMessages[0].uuidString])
        }
        #expect(try store.fetchStepPayload(messageID: keptMessages[0], stepID: "s1") == nil)
        #expect(try store.fetchStepPayload(messageID: keptMessages[1], stepID: "s1")?.resultPrefix == "r")
        #expect(try store.fetchEnabledServerIds(conversationId: kept) == [server], "deleting a message leaves the switches alone")

        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [doomed.uuidString])
        }
        #expect(try store.fetchEnabledServerIds(conversationId: doomed).isEmpty)
        for message in doomedMessages {
            #expect(try store.fetchStepPayload(messageID: message, stepID: "s1") == nil)
        }
        #expect(try store.fetchEnabledServerIds(conversationId: kept) == [server])
        #expect(try database.nonEmptyTables() == ["mcp_conversation_switch": 1, "mcp_step_payload": 1])
    }

    @Test("A fresh database and one upgraded from v28 end up with the same MCP schema")
    func freshAndUpgradedSchemasMatch() throws {
        let fresh = try McpTestDatabase.make()
        defer { fresh.cleanUp() }
        let upgraded = try McpTestDatabase.make(upTo: Self.previousVersion)
        defer { upgraded.cleanUp() }
        try upgraded.insertConversation(messageCount: 1)
        try upgraded.migrateToLatest()

        let freshSchema = try fresh.pool.read { db in try mcpSchema(db) }
        let upgradedSchema = try upgraded.pool.read { db in try mcpSchema(db) }
        // Six tables, two indexes, two triggers and the message column list.
        #expect(freshSchema.count == 11)
        #expect(freshSchema == upgradedSchema)
    }
}
