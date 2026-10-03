import Foundation
import GRDB

/// Local persistence for remote MCP servers: the server records with their limit, connection state, tool
/// snapshots, permissions, per-conversation switches and step payloads. Everything stays on this device.
/// Credentials do not go through here (see `McpCredentialStore`).
nonisolated final class McpServerStore: @unchecked Sendable {
    /// Step payload caps: raw arguments up to 16 KB, and the first 2 KB of the result.
    static let maxStepArgumentsBytes = 16 * 1024
    static let maxStepResultPrefixBytes = 2 * 1024

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Server records

    func fetchAllServers() throws -> [McpServerRecord] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM mcp_server ORDER BY createdAt ASC, id ASC")
            return rows.compactMap(Self.server(from:))
        }
    }

    func fetchServer(id: UUID) throws -> McpServerRecord? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM mcp_server WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            return Self.server(from: row)
        }
    }

    /// Number of servers that can be read back. The limit is counted against this: a row that cannot be read back
    /// (an unknown `authKind`, e.g. written by a newer version) is invisible to the user and cannot be removed, so
    /// counting it would stop the user from adding servers before the list is actually full.
    func serverCount() throws -> Int {
        try dbPool.read { db in try Self.readableServerCount(in: db) }
    }

    /// Inserts a server record (the caller supplies the slug). Throws `McpStoreError.limitReached` past the limit,
    /// `serverExists` when the primary key is taken and `slugConflict` when the slug is taken; a failure leaves no row.
    ///
    /// The add flow does not use this. It uses `addServer(_:maxServers:)`, which writes the snapshots, permissions
    /// and connection state in the same transaction.
    func insertServer(_ record: McpServerRecord, maxServers: Int = McpRuntimeConfig.fallback.maxServers) throws {
        try dbPool.write { db in
            try Self.requireCapacity(maxServers, in: db)
            try Self.requireAbsent(record.id, in: db)
            let slugTaken = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM mcp_server WHERE slug = ?)",
                arguments: [record.slug]
            ) ?? false
            guard !slugTaken else { throw McpStoreError.slugConflict(record.slug) }
            try Self.insertServerRow(record, in: db)
        }
    }

    /// Atomic write for the add flow: the server record, tool snapshots, default permissions and connection state
    /// are written in **one write transaction**. Any failing step rolls everything back, so a process killed halfway
    /// never leaves half a server behind.
    ///
    /// - The slug is generated from the name and de-duplicated inside the transaction: the uniqueness check and the
    ///   insert must share one write transaction.
    /// - An existing primary key fails outright and **leaves the existing row alone**: a caller-supplied `id` that
    ///   collides with a server already present must not delete it.
    @discardableResult
    func addServer(_ addition: McpServerAddition, maxServers: Int) throws -> McpServerRecord {
        try dbPool.write { db in
            try Self.requireCapacity(maxServers, in: db)
            try Self.requireAbsent(addition.id, in: db)
            let existingSlugs = Set(try String.fetchAll(db, sql: "SELECT slug FROM mcp_server"))
            let record = McpServerRecord(
                id: addition.id,
                name: addition.name,
                slug: McpSlug.unique(name: addition.name, existing: existingSlugs),
                url: addition.url,
                authKind: addition.authKind,
                localOnly: addition.localOnly,
                iconURL: addition.iconURL,
                createdAt: addition.createdAt,
                updatedAt: addition.createdAt
            )
            try Self.insertServerRow(record, in: db)
            for snapshot in addition.snapshots {
                try Self.insertSnapshot(snapshot, in: db)
            }
            for (toolName, permission) in addition.permissions {
                try Self.upsertPermission(permission, serverId: addition.id, toolName: toolName, in: db)
            }
            try Self.upsertConnectionState(addition.connectionState, in: db)
            return record
        }
    }

    /// Applies an edit to a server record (by id). The slug never changes after creation, so it is not updated.
    func updateServer(_ record: McpServerRecord) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE mcp_server
                    SET name = ?, url = ?, authKind = ?, localOnly = ?, iconURL = ?,
                        updatedAt = ?, schemaVersion = ?
                    WHERE id = ?
                    """,
                arguments: [
                    record.name,
                    Self.storedURL(for: record),
                    record.authKind.rawValue,
                    record.localOnly ? 1 : 0,
                    record.iconURL,
                    record.updatedAt.timeIntervalSince1970,
                    record.schemaVersion,
                    record.id.uuidString,
                ]
            )
        }
    }

    /// Deletes a server record and everything kept for it on this device: connection state, tool snapshots,
    /// permissions, conversation switches and step payloads. Its "allow for this conversation" grants are void
    /// as well. The caller clears the credentials through `McpCredentialStore`.
    func deleteServer(id: UUID) throws {
        try dbPool.write { db in
            try Self.deleteServerRows(id: id, in: db)
        }
        McpConversationGrants.shared.revoke(serverId: id)
    }

    // MARK: - Connection state

    func saveConnectionState(_ state: McpConnectionState) throws {
        try dbPool.write { db in
            try Self.upsertConnectionState(state, in: db)
        }
    }

    func fetchConnectionState(serverId: UUID) throws -> McpConnectionState? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM mcp_connection_state WHERE serverId = ?",
                arguments: [serverId.uuidString]
            ) else { return nil }
            guard let status = McpConnectionStatus(rawValue: row["status"]) else { return nil }
            return McpConnectionState(
                serverId: serverId,
                status: status,
                lastSuccessAt: (row["lastSuccessAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                negotiatedVersion: row["negotiatedVersion"],
                generation: (row["generation"] as String?).flatMap(McpProtocolGeneration.init(rawValue:)),
                sessionId: row["sessionId"]
            )
        }
    }

    // MARK: - Tool snapshots

    func fetchToolSnapshots(serverId: UUID) throws -> [McpToolSnapshot] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM mcp_tool_snapshot WHERE serverId = ? ORDER BY toolName ASC",
                arguments: [serverId.uuidString]
            )
            return rows.compactMap(Self.snapshot(from:))
        }
    }

    func replaceToolSnapshots(serverId: UUID, snapshots: [McpToolSnapshot]) throws {
        try dbPool.write { db in
            try Self.replaceSnapshots(serverId: serverId, snapshots: snapshots, in: db)
        }
    }

    /// Persists one catalog result (`McpToolCatalog.confirm` or a refetch) as a whole: the snapshots are replaced
    /// wholesale and the permissions listed in `permissions` are overwritten, in one transaction. Confirming a
    /// change may lower permissions (they only ever go down, never up), and lifting the quarantine must take effect
    /// together with the lowered permission: there must be no in-between state where the tool is released but
    /// still set to run automatically.
    ///
    /// There is no separate entry point for lifting the quarantine: the flag can only be written along with
    /// snapshots whose hash and title `McpToolCatalog.confirm` has verified.
    func saveToolCatalog(
        serverId: UUID,
        snapshots: [McpToolSnapshot],
        permissions: [String: McpToolPermission]
    ) throws {
        try dbPool.write { db in
            try Self.replaceSnapshots(serverId: serverId, snapshots: snapshots, in: db)
            for (toolName, permission) in permissions {
                try Self.upsertPermission(permission, serverId: serverId, toolName: toolName, in: db)
            }
        }
    }

    /// Persists the result of re-reading the tools as a whole: the snapshots are replaced wholesale and the
    /// permission table is **replaced by** `permissions`. Permission rows for tools the server no longer offers
    /// are dropped, and no permission is written ahead of time for new tools (no row means newly added; the
    /// default is chosen only on confirmation). One transaction.
    func replaceToolCatalog(
        serverId: UUID,
        snapshots: [McpToolSnapshot],
        permissions: [String: McpToolPermission]
    ) throws {
        try dbPool.write { db in
            try Self.replaceSnapshots(serverId: serverId, snapshots: snapshots, in: db)
            try db.execute(sql: "DELETE FROM mcp_tool_permission WHERE serverId = ?", arguments: [serverId.uuidString])
            for (toolName, permission) in permissions {
                try Self.upsertPermission(permission, serverId: serverId, toolName: toolName, in: db)
            }
        }
    }

    // MARK: - Tool permissions

    func fetchToolPermissions(serverId: UUID) throws -> [String: McpToolPermission] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT toolName, permission FROM mcp_tool_permission WHERE serverId = ?",
                arguments: [serverId.uuidString]
            )
            var result: [String: McpToolPermission] = [:]
            for row in rows {
                guard let permission = McpToolPermission(rawValue: row["permission"]) else { continue }
                result[row["toolName"]] = permission
            }
            return result
        }
    }

    func setToolPermission(_ permission: McpToolPermission, serverId: UUID, toolName: String) throws {
        try dbPool.write { db in
            try Self.upsertPermission(permission, serverId: serverId, toolName: toolName, in: db)
        }
    }

    // MARK: - Conversation switches
    //
    // `conversationId` holds the conversation id's `uuidString`, spelled exactly like `conversation.id`:
    // a trigger cascades the cleanup when a conversation is deleted (see `DatabaseSchema`).

    func fetchEnabledServerIds(conversationId: UUID) throws -> [UUID] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT serverId FROM mcp_conversation_switch WHERE conversationId = ? ORDER BY enabledAt ASC",
                arguments: [conversationId.uuidString]
            )
            return rows.compactMap { UUID(uuidString: $0["serverId"]) }
        }
    }

    /// A new conversation has no conversation id until its first message is sent, so its switches are kept under
    /// the draft id and moved over as a whole once the conversation is created.
    func moveConversationSwitches(from draftId: UUID, to conversationId: UUID) throws {
        guard draftId != conversationId else { return }
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE OR REPLACE mcp_conversation_switch SET conversationId = ? WHERE conversationId = ?",
                arguments: [conversationId.uuidString, draftId.uuidString]
            )
        }
    }

    func setServerEnabled(_ enabled: Bool, conversationId: UUID, serverId: UUID) throws {
        try dbPool.write { db in
            if enabled {
                try db.execute(
                    sql: """
                        INSERT INTO mcp_conversation_switch (conversationId, serverId, enabledAt)
                        VALUES (?, ?, ?)
                        ON CONFLICT(conversationId, serverId) DO NOTHING
                        """,
                    arguments: [conversationId.uuidString, serverId.uuidString, Date().timeIntervalSince1970]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM mcp_conversation_switch WHERE conversationId = ? AND serverId = ?",
                    arguments: [conversationId.uuidString, serverId.uuidString]
                )
            }
        }
    }

    /// "Disable this server for now": turns its switch off in every conversation. The record, credentials and tools
    /// are kept and quarantined tools stay quarantined; it can be turned back on from the tool panel of any
    /// conversation.
    func disableServerInAllConversations(serverId: UUID) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM mcp_conversation_switch WHERE serverId = ?",
                arguments: [serverId.uuidString]
            )
        }
    }

    // MARK: - Step payloads
    //
    // `messageID` holds the message id's `uuidString`, spelled exactly like `message.id`: a trigger cleans up when
    // a message is deleted (including the cascade from deleting a conversation). Arguments and result are written
    // separately (arguments at the start, result at the end); a column passed as nil in the later write keeps its
    // value.

    ///
    /// `serverId` is the server that ran the step. When given it is stored on the row, so removing the server
    /// deletes by it. **Nothing is written when the server is no longer on this device**: if the server is removed
    /// while a step is still running, its late result must not bring back the payload that was just deleted.
    func saveStepPayload(
        messageID: UUID,
        stepID: String,
        serverId: UUID? = nil,
        arguments: String?,
        resultPrefix: String?
    ) throws {
        try dbPool.write { db in
            if let serverId {
                let exists = try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM mcp_server WHERE id = ?)", arguments: [serverId.uuidString]
                ) ?? false
                guard exists else { return }
            }
            try db.execute(
                sql: """
                    INSERT INTO mcp_step_payload (messageID, stepID, serverId, arguments, resultPrefix, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(messageID, stepID) DO UPDATE SET
                        serverId = COALESCE(excluded.serverId, serverId),
                        arguments = COALESCE(excluded.arguments, arguments),
                        resultPrefix = COALESCE(excluded.resultPrefix, resultPrefix)
                    """,
                arguments: [
                    messageID.uuidString,
                    stepID,
                    serverId?.uuidString,
                    Self.capped(arguments, bytes: Self.maxStepArgumentsBytes),
                    Self.capped(resultPrefix, bytes: Self.maxStepResultPrefixBytes),
                    Date().timeIntervalSince1970,
                ]
            )
        }
    }

    func fetchStepPayload(messageID: UUID, stepID: String) throws -> (arguments: String?, resultPrefix: String?)? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT arguments, resultPrefix FROM mcp_step_payload WHERE messageID = ? AND stepID = ?",
                arguments: [messageID.uuidString, stepID]
            ) else { return nil }
            return (row["arguments"], row["resultPrefix"])
        }
    }

    // MARK: - Shared writes inside a transaction

    /// Known auth kinds. Rows that cannot be read back do not count toward the limit (see `serverCount()`).
    private static let knownAuthKinds = McpAuthKind.allCases.map(\.rawValue)

    private static func readableServerCount(in db: Database) throws -> Int {
        let placeholders = knownAuthKinds.map { _ in "?" }.joined(separator: ",")
        return try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM mcp_server WHERE authKind IN (\(placeholders))",
            arguments: StatementArguments(knownAuthKinds)
        ) ?? 0
    }

    private static func requireCapacity(_ maxServers: Int, in db: Database) throws {
        guard try readableServerCount(in: db) < maxServers else {
            throw McpStoreError.limitReached(max: maxServers)
        }
    }

    private static func requireAbsent(_ id: UUID, in db: Database) throws {
        let exists = try Bool.fetchOne(
            db, sql: "SELECT EXISTS(SELECT 1 FROM mcp_server WHERE id = ?)", arguments: [id.uuidString]
        ) ?? false
        guard !exists else { throw McpStoreError.serverExists(id) }
    }

    private static func insertServerRow(
        _ record: McpServerRecord,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO mcp_server
                (id, name, slug, url, authKind, localOnly, iconURL, createdAt, updatedAt, schemaVersion)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                record.id.uuidString,
                record.name,
                record.slug,
                storedURL(for: record),
                record.authKind.rawValue,
                record.localOnly ? 1 : 0,
                record.iconURL,
                record.createdAt.timeIntervalSince1970,
                record.updatedAt.timeIntervalSince1970,
                record.schemaVersion,
            ]
        )
    }

    /// The address written to the database: a `localOnly` record only ever stores its display address, and the
    /// caller saves the full address in the credential store first. Enforcing this at the single write path means
    /// a caller that passes a full address by mistake still cannot put a secret into a database that gets backed up.
    private static func storedURL(for record: McpServerRecord) -> String {
        record.localOnly ? McpLocalOnly.displayURL(record.url) : record.url
    }

    private static func deleteServerRows(id: UUID, in db: Database) throws {
        let key = id.uuidString
        try db.execute(sql: "DELETE FROM mcp_server WHERE id = ?", arguments: [key])
        try db.execute(sql: "DELETE FROM mcp_connection_state WHERE serverId = ?", arguments: [key])
        try db.execute(sql: "DELETE FROM mcp_tool_snapshot WHERE serverId = ?", arguments: [key])
        try db.execute(sql: "DELETE FROM mcp_tool_permission WHERE serverId = ?", arguments: [key])
        try db.execute(sql: "DELETE FROM mcp_conversation_switch WHERE serverId = ?", arguments: [key])
        try deleteStepPayloads(serverId: id, in: db)
    }

    /// The raw arguments and results kept on this device for steps this server ran are deleted along with the
    /// server. The step summaries on the messages stay, so existing conversations keep their tool records. Rows are
    /// deleted by the server column on the payload row; a row saved without one is found through the step
    /// summaries of the messages instead.
    private static func deleteStepPayloads(serverId: UUID, in db: Database) throws {
        try db.execute(sql: "DELETE FROM mcp_step_payload WHERE serverId = ?", arguments: [serverId.uuidString])
        let key = serverId.uuidString.lowercased()
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, toolSteps FROM message WHERE toolSteps IS NOT NULL AND lower(toolSteps) LIKE ?",
            arguments: ["%\(key)%"]
        )
        for row in rows {
            let messageID: String = row["id"]
            guard let text: String = row["toolSteps"],
                  let steps = try? JSONDecoder().decode([McpToolStep].self, from: Data(text.utf8)) else { continue }
            for step in steps where step.serverId.lowercased() == key {
                try db.execute(
                    sql: "DELETE FROM mcp_step_payload WHERE messageID = ? AND stepID = ?",
                    arguments: [messageID, step.id]
                )
            }
        }
    }

    private static func upsertConnectionState(_ state: McpConnectionState, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO mcp_connection_state
                (serverId, status, lastSuccessAt, negotiatedVersion, generation, sessionId)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(serverId) DO UPDATE SET
                    status = excluded.status,
                    lastSuccessAt = excluded.lastSuccessAt,
                    negotiatedVersion = excluded.negotiatedVersion,
                    generation = excluded.generation,
                    sessionId = excluded.sessionId
                """,
            arguments: [
                state.serverId.uuidString,
                state.status.rawValue,
                state.lastSuccessAt?.timeIntervalSince1970,
                state.negotiatedVersion,
                state.generation?.rawValue,
                state.sessionId,
            ]
        )
    }

    private static func upsertPermission(
        _ permission: McpToolPermission,
        serverId: UUID,
        toolName: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO mcp_tool_permission (serverId, toolName, permission)
                VALUES (?, ?, ?)
                ON CONFLICT(serverId, toolName) DO UPDATE SET permission = excluded.permission
                """,
            arguments: [serverId.uuidString, toolName, permission.rawValue]
        )
    }

    private static func replaceSnapshots(serverId: UUID, snapshots: [McpToolSnapshot], in db: Database) throws {
        try db.execute(sql: "DELETE FROM mcp_tool_snapshot WHERE serverId = ?", arguments: [serverId.uuidString])
        for snapshot in snapshots {
            try insertSnapshot(snapshot, in: db)
        }
    }

    private static func insertSnapshot(_ snapshot: McpToolSnapshot, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO mcp_tool_snapshot
                (serverId, toolName, title, description, inputSchema, annotations, contentHash,
                 readOnly, pendingReview, oversized, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                snapshot.serverId.uuidString,
                snapshot.toolName,
                snapshot.title,
                snapshot.description,
                // Order-preserving: the argument summary takes the first 3 `properties` in their original order.
                // Canonical JSON (keys ascending) is only for hashing; storing it would lose that order.
                snapshot.inputSchema.orderedJSONString,
                snapshot.annotations.orderedJSONString,
                snapshot.contentHash,
                snapshot.readOnly ? 1 : 0,
                snapshot.pendingReview ? 1 : 0,
                snapshot.oversized ? 1 : 0,
                snapshot.updatedAt.timeIntervalSince1970,
            ]
        )
    }

    // MARK: - Row mapping

    private static func server(from row: Row) -> McpServerRecord? {
        guard let id = UUID(uuidString: row["id"]),
              let authKind = McpAuthKind(rawValue: row["authKind"]) else { return nil }
        return McpServerRecord(
            id: id,
            name: row["name"],
            slug: row["slug"],
            url: row["url"],
            authKind: authKind,
            localOnly: (row["localOnly"] as Int) != 0,
            iconURL: row["iconURL"],
            createdAt: Date(timeIntervalSince1970: row["createdAt"]),
            updatedAt: Date(timeIntervalSince1970: row["updatedAt"]),
            schemaVersion: row["schemaVersion"]
        )
    }

    private static func snapshot(from row: Row) -> McpToolSnapshot? {
        guard let serverId = UUID(uuidString: row["serverId"]),
              let inputSchema = try? JSONValue(parsing: row["inputSchema"]),
              let annotations = try? JSONValue(parsing: row["annotations"]) else { return nil }
        return McpToolSnapshot(
            serverId: serverId,
            toolName: row["toolName"],
            title: row["title"],
            description: row["description"],
            inputSchema: inputSchema,
            annotations: annotations,
            contentHash: row["contentHash"],
            readOnly: (row["readOnly"] as Int) != 0,
            pendingReview: (row["pendingReview"] as Int) != 0,
            oversized: (row["oversized"] as Int) != 0,
            updatedAt: Date(timeIntervalSince1970: row["updatedAt"])
        )
    }

    /// Truncates to the byte cap in UTF-8 without splitting a multi-byte character.
    private static func capped(_ text: String?, bytes: Int) -> String? {
        guard let text else { return nil }
        guard text.utf8.count > bytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > bytes { break }
            result.append(character)
            used += size
        }
        return result
    }
}

nonisolated enum McpStoreError: Error, Equatable {
    case limitReached(max: Int)
    case slugConflict(String)
    /// The primary key already exists. The existing row is unaffected.
    case serverExists(UUID)
}

/// Everything one add writes to the database (`McpServerStore.addServer`). The slug is not here: it is generated
/// inside the write transaction.
nonisolated struct McpServerAddition: Sendable {
    var id: UUID
    var name: String
    var url: String
    var authKind: McpAuthKind
    var localOnly: Bool
    var iconURL: String?
    var createdAt: Date
    var snapshots: [McpToolSnapshot]
    var permissions: [String: McpToolPermission]
    var connectionState: McpConnectionState
}

/// Slug generation (shared fixture `identifiers.json`): `[a-z0-9]{1,16}`, unique among all servers on this
/// device.
///
/// The slug is the tool name prefix, and both the web client's validation regex and upstream providers accept
/// only `[a-z0-9]`, so it **never contains `-`**.
nonisolated enum McpSlug {
    static let maxLength = 16
    static let fallback = "server"

    /// Walks the Unicode scalars one by one: `A-Z` become their lowercase counterparts, `a-z` and `0-9` are kept
    /// as is, everything else is dropped. The result is truncated to 16 characters and falls back to `server` when
    /// empty.
    ///
    /// `lowercased()` is deliberately not used: it performs Unicode case folding (`İ` → `i̇`, the Kelvin sign → `k`),
    /// and the folding tables differ between iOS, Android and web. Those characters must simply be dropped.
    static func make(from name: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A:
                result.append(Unicode.Scalar(scalar.value + 0x20)!)
            case 0x61...0x7A, 0x30...0x39:
                result.append(scalar)
            default:
                continue
            }
            if result.count == maxLength { break }
        }
        return result.isEmpty ? fallback : String(result)
    }

    /// `candidate = make(name)`. If it is not in `existing`, use it. Otherwise count `n` up from 2, take the first
    /// `16 - (number of decimal digits in n)` characters of `candidate` and append `n` (a bare numeric suffix, no
    /// separator); the first one that does not collide is the result.
    static func unique(name: String, existing: Set<String>) -> String {
        let candidate = make(from: name)
        if !existing.contains(candidate) { return candidate }
        var index = 2
        while true {
            let suffix = String(index)
            let next = String(candidate.prefix(max(0, maxLength - suffix.count))) + suffix
            if !existing.contains(next) { return next }
            index += 1
        }
    }

    /// Whether the slug matches `^[a-z0-9]{1,16}$`.
    static func isValid(_ slug: String) -> Bool {
        let scalars = slug.unicodeScalars
        guard (1...maxLength).contains(scalars.count) else { return false }
        return scalars.allSatisfy { (0x61...0x7A).contains($0.value) || (0x30...0x39).contains($0.value) }
    }
}
